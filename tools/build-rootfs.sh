#!/usr/bin/env bash
# ============================================================================
# Quectel M2 应用层 Overlay 打包脚本
# ============================================================================
# 功能: 通过 overlay 机制, 把客户自定义应用/脚本/服务追加到文件系统镜像
#   - 解压/挂载文件系统镜像
#   - 从 overlay/ 目录追加文件 (overlay 目录结构 == rootfs 路径)
#   - 删除指定文件
#   - 重新打包文件系统镜像
#
# 用法:
#   ./build-rootfs.sh check                  # 环境检查
#   ./build-rootfs.sh apply [镜像]           # 应用 overlay → 输出新镜像
#   ./build-rootfs.sh remove <路径> [镜像]   # 从镜像删除文件
#   ./build-rootfs.sh extract <镜像> <目录>  # 解压镜像到目录 (挂载或 debugfs)
#   ./build-rootfs.sh repack <目录> <镜像>   # 从目录重新打包镜像
#   ./build-rootfs.sh clean                  # 清理工作目录
#
# 参数:
#   镜像   文件系统镜像路径 (默认 prebuilds/base_image/rootfs.img)
#   overlay 目录 (默认 ../overlay)
#
# 产物:
#   build/rootfs-overlay.img    应用了 overlay 的新文件系统镜像
# ============================================================================
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/.." && pwd)"
OVERLAY_DIR="${OVERLAY_DIR:-$ROOT_DIR/overlay}"
WORK_DIR="$ROOT_DIR/build"
DEFAULT_IMG="$ROOT_DIR/prebuilds/base_image/rootfs.img"
OUT_IMG="$WORK_DIR/rootfs-overlay.img"

# ----------------------------------------------------------------------------
# 颜色输出
# ----------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# ----------------------------------------------------------------------------
# 环境检查
# ----------------------------------------------------------------------------
check_env() {
    local ok=1
    [ -d "$OVERLAY_DIR" ] || { log_err "缺少 overlay 目录: $OVERLAY_DIR"; ok=0; }
    [ -f "$DEFAULT_IMG" ] || { log_warn "默认镜像不存在: $DEFAULT_IMG (可用参数指定)"; }
    command -v debugfs >/dev/null 2>&1 || { log_warn "未找到 debugfs, 将尝试挂载方式"; }
    command -v sudo >/dev/null 2>&1 || { log_warn "未找到 sudo, 挂载方式不可用 (debugfs 可替代)"; }

    [ "$ok" = "1" ] || { log_err "环境检查未通过"; return 1; }
    log_ok "环境检查通过"
    log_info "  overlay 目录: $OVERLAY_DIR"
    log_info "  默认镜像: $DEFAULT_IMG"
    return 0
}

# ----------------------------------------------------------------------------
# 检测镜像类型
# ----------------------------------------------------------------------------
img_type() {
    local img="$1"
    file -b "$img" | grep -q "ext4" && echo "ext4" && return
    file -b "$img" | grep -q "squashfs" && echo "squashfs" && return
    echo "unknown"
}

# ----------------------------------------------------------------------------
# 应用 overlay: 把 overlay/ 内容写入镜像 (debugfs, 无需 root)
#   overlay/ 目录结构 == rootfs 根路径
# ----------------------------------------------------------------------------
apply_overlay() {
    local img="${1:-$DEFAULT_IMG}"
    [ -f "$img" ] || { log_err "镜像不存在: $img"; return 1; }
    [ -d "$OVERLAY_DIR" ] || { log_err "overlay 目录不存在: $OVERLAY_DIR"; return 1; }
    command -v debugfs >/dev/null 2>&1 || { log_err "需要 debugfs (e2fsprogs)"; return 1; }

    local type
    type="$(img_type "$img")"
    [ "$type" = "ext4" ] || { log_err "仅支持 ext4 镜像 (当前: $type)"; return 1; }

    mkdir -p "$WORK_DIR"
    # 工作副本 (不污染源镜像)
    cp --reflink=auto -f "$img" "$OUT_IMG" 2>/dev/null || cp -f "$img" "$OUT_IMG"

    log_info "应用 overlay: $OVERLAY_DIR → $OUT_IMG"
    local total=0 written=0
    while IFS= read -r f; do
        total=$((total+1))
        local rel target subdir cur=""
        rel="${f#"$OVERLAY_DIR"/}"
        case "$rel" in
            README.md|*.dts|*.dtbo)
                total=$((total-1))
                log_info "跳过非 rootfs 文件: $rel"
                continue
                ;;
        esac
        target="/$rel"
        subdir="$(dirname "$target")"

        # 逐级创建目录
        IFS='/' read -r -a parts <<< "$subdir"
        for p in "${parts[@]}"; do
            [ -z "$p" ] && continue
            cur="$cur/$p"
            debugfs -w -R "mkdir $cur" "$OUT_IMG" < /dev/null > /dev/null 2>&1 || true
        done

        if debugfs -w -R "write $f $target" "$OUT_IMG" < /dev/null > /dev/null 2>&1; then
            # 保留可执行权限
            [ -x "$f" ] && debugfs -w -R "sif $target mode 0100755" "$OUT_IMG" < /dev/null > /dev/null 2>&1 || true
            written=$((written+1))
        else
            log_warn "写入失败: $f -> $target"
        fi
    done < <(find "$OVERLAY_DIR" -type f)

    # 校验文件系统
    local rc=0
    e2fsck -f -y "$OUT_IMG" > /dev/null 2>&1 || rc=$?
    [ "$rc" -lt 4 ] || { log_err "e2fsck 发现未修复错误 ($rc)"; return 1; }

    log_ok "overlay 应用完成: $written/$total 个文件写入 $OUT_IMG"
    log_ok "产物: $OUT_IMG ($(du -h "$OUT_IMG" | cut -f1))"
    return 0
}

# ----------------------------------------------------------------------------
# 从镜像删除文件
# ----------------------------------------------------------------------------
remove_from_img() {
    local target_path="$1"
    local img="${2:-$DEFAULT_IMG}"
    [ -f "$img" ] || { log_err "镜像不存在: $img"; return 1; }
    command -v debugfs >/dev/null 2>&1 || { log_err "需要 debugfs"; return 1; }

    mkdir -p "$WORK_DIR"
    cp --reflink=auto -f "$img" "$OUT_IMG" 2>/dev/null || cp -f "$img" "$OUT_IMG"

    log_info "从镜像删除: $target_path"
    if debugfs -w -R "rm $target_path" "$OUT_IMG" < /dev/null > /dev/null 2>&1; then
        log_ok "已删除: $target_path"
    else
        log_warn "删除失败 (可能不存在): $target_path"
    fi

    local rc=0
    e2fsck -f -y "$OUT_IMG" > /dev/null 2>&1 || rc=$?
    [ "$rc" -lt 4 ] || { log_err "e2fsck 发现未修复错误 ($rc)"; return 1; }
    log_ok "产物: $OUT_IMG"
    return 0
}

# ----------------------------------------------------------------------------
# 解压镜像到目录 (debugfs dump-all 或挂载)
# ----------------------------------------------------------------------------
extract_img() {
    local img="${1:-$DEFAULT_IMG}"
    local dst="${2:-$WORK_DIR/extracted}"
    [ -f "$img" ] || { log_err "镜像不存在: $img"; return 1; }

    mkdir -p "$dst"
    log_info "解压镜像到: $dst"

    # 方式 1: debugfs dump 所有文件 (无需 root, 但可能较慢)
    # 方式 2: 挂载 (需要 root)
    if mountpoint -q "$dst" 2>/dev/null; then
        log_ok "已在挂载状态: $dst"
        return 0
    fi

    # 尝试 mount (需要 root)
    if [ "$(id -u)" = "0" ]; then
        mount -o loop "$img" "$dst" && { log_ok "已挂载: $img → $dst"; return 0; }
    fi

    # 用 debugfs dump 全部文件
    log_info "使用 debugfs 解压 (无需 root)..."
    debugfs -R "rdump / $dst" "$img" < /dev/null > /dev/null 2>&1 || { log_err "解压失败"; return 1; }
    log_ok "解压完成: $dst"
    return 0
}

# ----------------------------------------------------------------------------
# 从目录重新打包镜像 (ext4)
# ----------------------------------------------------------------------------
repack_img() {
    local src="${1:-$WORK_DIR/extracted}"
    local img="${2:-$OUT_IMG}"
    [ -d "$src" ] || { log_err "目录不存在: $src"; return 1; }

    mkdir -p "$WORK_DIR"
    log_info "重新打包: $src → $img"

    # 估算大小 (源镜像大小或计算)
    local size_mb
    size_mb="$(du -sm "$src" | cut -f1)"
    # 预留 10% 空间 + 64MB 元数据
    local total_mb=$((size_mb + size_mb / 10 + 64))

    truncate -s "${total_mb}M" "$img"
    printf 'y\n' | mkfs.ext4 -q -F -d "$src" "$img" 2>/dev/null || { log_err "打包失败 (mkfs.ext4)"; return 1; }

    local rc=0
    e2fsck -f -y "$img" > /dev/null 2>&1 || rc=$?
    [ "$rc" -lt 4 ] || { log_err "e2fsck 发现未修复错误 ($rc)"; return 1; }

    log_ok "打包完成: $img ($(du -h "$img" | cut -f1))"
    return 0
}

# ----------------------------------------------------------------------------
# 清理
# ----------------------------------------------------------------------------
cmd_clean() {
    log_info "清理工作目录..."
    rm -rf "$WORK_DIR"
    log_ok "清理完成"
}

# ----------------------------------------------------------------------------
# 主入口
# ----------------------------------------------------------------------------
main() {
    local cmd="${1:-help}"
    case "$cmd" in
        check)
            check_env
            ;;
        apply)
            apply_overlay "${2:-}"
            ;;
        remove)
            [ -n "${2:-}" ] || { log_err "用法: $0 remove <路径> [镜像]"; exit 1; }
            remove_from_img "$2" "${3:-}"
            ;;
        extract)
            extract_img "${2:-}" "${3:-}"
            ;;
        repack)
            repack_img "${2:-}" "${3:-}"
            ;;
        clean)
            cmd_clean
            ;;
        help|*)
            echo "用法: $0 <命令>"
            echo "  check                     环境检查"
            echo "  apply [镜像]              应用 overlay → 输出 build/rootfs-overlay.img"
            echo "  remove <路径> [镜像]      从镜像删除文件"
            echo "  extract <镜像> <目录>     解压镜像到目录"
            echo "  repack <目录> <镜像>      从目录重新打包镜像"
            echo "  clean                     清理工作目录"
            echo
            echo "环境变量: OVERLAY_DIR (默认 ../overlay)"
            ;;
    esac
}

main "$@"
