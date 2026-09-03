#!/usr/bin/env bash
# ============================================================================
# Quectel PI H1 (QCS6490) 文件系统打包脚本 —— 目录级可复现模型
# 命令接口与 QPi-SDK (M2) 的 tools/build-rootfs.sh 兼容
# ============================================================================
# 模型 (可复现, 不挂载修改任何镜像):
#
#   prebuilds/base_rootfs/   ← 基准目录 (从原始 system.img 提取一次, 只读)
#        │  rsync (每次构建)
#        ▼
#   build/rootfs-staging/    ← 工作目录: base + overlay + 删除清单 + hooks
#        │  mkfs.btrfs --rootdir (fakeroot 保属主)
#        ▼
#   build/output/system.img  ← 最终镜像 (全新生成, 内容 = base+overlay 决定)
#
# 免 root 说明:
#   - staging 合成 (rsync/删除/hooks) 全部免 root
#   - 打包用 fakeroot + mkfs.btrfs --rootdir, 免 root (fakeroot 伪装属主)
#   - base_rootfs 提取可用 btrfs restore 免 root (属主归一化) 或
#     sudo mount+rsync 保真 (推荐一次性提取)
#
# 用法:
#   ./tools/build-rootfs.sh check                  # 环境检查
#   ./tools/build-rootfs.sh extract [镜像] [目录]  # 建立 base 目录 (镜像→目录)
#   ./tools/build-rootfs.sh apply [镜像]           # 合成 staging (base+overlay)
#   ./tools/build-rootfs.sh repack [目录] [镜像]   # staging 目录 → system.img
#   ./tools/build-rootfs.sh build                  # = apply + repack (完整打包)
#   ./tools/build-rootfs.sh remove <路径>          # 登记删除 (overlay-remove.list)
#   ./tools/build-rootfs.sh clean                  # 清理 staging/挂载残留
#
# 环境变量:
#   OVERLAY_DIR        overlay 目录 (默认 SDK 根/overlay)
#   BASE_ROOTFS        基准目录 (默认 prebuilds/base_rootfs)
#   SYSTEM_IMG_SIZE    镜像字节数 (默认 = 原始 system.img 大小)
#   SYSTEM_IMG_UUID    镜像 UUID (默认 = 原始 system.img 的 UUID, 保证可复现)
# ============================================================================
set -uo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="$(cd "${TOOLS_DIR}/.." && pwd)"
OVERLAY_DIR="${OVERLAY_DIR:-${SDK_ROOT}/overlay}"
REMOVE_LIST="${OVERLAY_DIR}/overlay-remove.list"
SRC_IMG="${SDK_ROOT}/prebuilds/system.img"
BASE_ROOTFS="${BASE_ROOTFS:-${SDK_ROOT}/prebuilds/base_rootfs}"
STAGING="${SDK_ROOT}/build/rootfs-staging"
OUT_IMG="${SDK_ROOT}/build/output/system.img"
SUDO="${SUDO:-sudo}"

# 原始镜像属性 (默认值, 保证与分区/烧录兼容)
SRC_SIZE="$(stat -c%s "${SRC_IMG}" 2>/dev/null || echo 13611565056)"
SRC_UUID="$(btrfs inspect-internal dump-super "${SRC_IMG}" 2>/dev/null | awk '/^fsid/{print $2; exit}')"
IMG_SIZE="${SYSTEM_IMG_SIZE:-${SRC_SIZE}}"
IMG_UUID="${SYSTEM_IMG_UUID:-${SRC_UUID:-185a1255-cc28-419f-b6f0-a0374671ac6d}}"

# 颜色输出 (与 M2 风格一致)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# ---------------------------------------------------------------------------
# 环境检查
# ---------------------------------------------------------------------------
check_env() {
    local ok=1
    [ -d "${OVERLAY_DIR}" ] || { log_err "缺少 overlay 目录: ${OVERLAY_DIR}"; ok=0; }
    command -v rsync >/dev/null 2>&1 || { log_err "未找到 rsync"; ok=0; }
    command -v btrfs >/dev/null 2>&1 || { log_err "未找到 btrfs-progs"; ok=0; }
    command -v fakeroot >/dev/null 2>&1 || { log_warn "未找到 fakeroot (repack 属主将不保真)"; }
    if [ ! -d "${BASE_ROOTFS}" ]; then
        log_warn "基准目录不存在: ${BASE_ROOTFS}"
        log_warn "  运行 ./tools/build-rootfs.sh extract 从原始镜像建立"
        if [ -d "${SDK_ROOT}/prebuilds/sysroot" ]; then
            log_info "  (检测到 prebuilds/sysroot, 将自动作为 base 源)"
        fi
    fi
    [ "${ok}" = "1" ] || { log_err "环境检查未通过"; return 1; }
    log_ok "环境检查通过"
    log_info "  overlay:     ${OVERLAY_DIR}"
    log_info "  base:        ${BASE_ROOTFS}"
    log_info "  staging:     ${STAGING}"
    log_info "  镜像大小:    $(( IMG_SIZE / 1024 / 1024 / 1024 )) GiB ($(( IMG_SIZE / 1024 / 1024 )) MiB)"
    log_info "  镜像 UUID:   ${IMG_UUID}"
    return 0
}

# 选择 base 源目录 (base_rootfs 优先, 否则 sysroot, 否则报错)
base_source() {
    if [ -d "${BASE_ROOTFS}" ]; then
        echo "${BASE_ROOTFS}"
    elif [ -d "${SDK_ROOT}/prebuilds/sysroot" ]; then
        echo "${SDK_ROOT}/prebuilds/sysroot"
    else
        log_err "无可用基准目录: ${BASE_ROOTFS} 或 prebuilds/sysroot"
        log_err "先运行: ./tools/build-rootfs.sh extract"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# extract: 从镜像建立 base 目录 (镜像 → 目录)
#   优先 sudo mount + rsync (保真属主); 无 sudo 时 btrfs restore (属主归一)
# ---------------------------------------------------------------------------
cmd_extract() {
    local img="${1:-${SRC_IMG}}"
    local dst="${2:-${BASE_ROOTFS}}"
    [ -f "${img}" ] || { log_err "镜像不存在: ${img}"; return 1; }
    if [ -d "${dst}" ] && [ -n "$(ls -A "${dst}" 2>/dev/null)" ]; then
        log_err "目标目录已存在且非空: ${dst} (先删除或指定其他目录)"
        return 1
    fi
    mkdir -p "${dst}"

    # 方式 1: sudo mount + rsync (保真, 推荐一次性)
    if ${SUDO} -n true 2>/dev/null; then
        local mnt
        mnt="$(mktemp -d)"
        log_info "sudo 可用: mount + rsync 提取 (保真属主/权限) ..."
        ${SUDO} mount -o loop,ro "${img}" "${mnt}" || { log_err "挂载失败"; rmdir "${mnt}"; return 1; }
        ${SUDO} rsync -aHAX --numeric-ids "${mnt}/" "${dst}/"
        ${SUDO} umount "${mnt}"
        rmdir "${mnt}"
        log_ok "提取完成 (保真): ${dst}"
    else
        # 方式 2: btrfs restore 免 root (属主归一为当前用户, 权限需修复)
        log_warn "无 sudo 凭证, 用 btrfs restore 免 root 提取 (属主归一, 稍后需 chown 修正)"
        log_warn "提示: 先 sudo -v 可走保真提取"
        btrfs restore -i -S -x "${img}" "${dst}" 2>&1 | grep -v "Operation not permitted\|setting extended" | head -3 || true
        log_info "修复权限 ..."
        find "${dst}" -type d -exec chmod 755 {} + 2>/dev/null || true
        find "${dst}" -type f -exec chmod 644 {} + 2>/dev/null || true
        for d in bin sbin usr/bin usr/sbin usr/libexec; do
            [ -d "${dst}/${d}" ] && find "${dst}/${d}" -type f -exec chmod 755 {} + 2>/dev/null || true
        done
        rm -rf "${dst}/dev"; mkdir -p "${dst}/dev"
        log_ok "提取完成 (免 root): ${dst}"
    fi
    echo ""
    log_ok "base 目录就绪: ${dst}"
    log_info "定制文件 → 放 overlay/ ; 然后 ./tools/build-rootfs.sh build 打包"
    return 0
}

# ---------------------------------------------------------------------------
# 合成 staging: rsync base → staging, 应用 overlay/删除清单/hooks (免 root)
# ---------------------------------------------------------------------------
apply_overlay() {
    local src
    src="$(base_source)" || return 1
    [ -d "${OVERLAY_DIR}" ] || { log_err "overlay 目录不存在: ${OVERLAY_DIR}"; return 1; }

    log_info "合成 staging: ${src} → ${STAGING}"
    rm -rf "${STAGING}"
    mkdir -p "${STAGING}"

    # 1. base → staging (reflink 优先, 快且省空间)
    cp -a --reflink=auto "${src}/." "${STAGING}/" 2>/dev/null \
        || rsync -aHAX --numeric-ids "${src}/" "${STAGING}/"

    # 2. overlay → staging (追加/覆盖)
    log_info "应用 overlay: ${OVERLAY_DIR}"
    rsync -aHAX --numeric-ids \
        --exclude='overlay-remove.list' \
        "${OVERLAY_DIR}/" "${STAGING}/"

    # 3. 额外 overlay
    if [ -n "${EXTRA_OVERLAY:-}" ] && [ -d "${EXTRA_OVERLAY}" ]; then
        log_info "应用额外 overlay: ${EXTRA_OVERLAY}"
        rsync -aHAX --numeric-ids "${EXTRA_OVERLAY}/" "${STAGING}/"
    fi

    # 4. 删除清单
    if [ -f "${REMOVE_LIST}" ]; then
        log_info "处理删除清单: ${REMOVE_LIST}"
        while IFS= read -r line; do
            case "${line}" in
                ""|\#*) continue ;;
            esac
            p="${line%%#*}"
            p="$(echo "${p}" | xargs)"
            [ -n "${p}" ] || continue
            case "${p}" in
                /*) rel="${p#/}" ;;
                *) rel="${p}" ;;
            esac
            if [ -e "${STAGING}/${rel}" ] || [ -L "${STAGING}/${rel}" ]; then
                echo "    rm -rf /${rel}"
                rm -rf "${STAGING}/${rel}"
            fi
        done < "${REMOVE_LIST}"
    fi

    # 5. hooks (目录级执行, 免 root; IMG_MNT=staging 兼容原 hook 接口)
    HOOKS_DIR="${HOOKS_DIR:-${SDK_ROOT}/hooks}"
    if [ -d "${HOOKS_DIR}" ]; then
        log_info "执行 pre-pack hooks: ${HOOKS_DIR}"
        for hook in "${HOOKS_DIR}"/*.sh; do
            [ -f "${hook}" ] || continue
            echo "    >>> 执行 hook: $(basename "${hook}")"
            IMG_MNT="${STAGING}" \
            OUT_IMG="${OUT_IMG}" \
            SRC_IMG="${SRC_IMG}" \
            OVERLAY_DIR="${OVERLAY_DIR}" \
            BUILD_DIR="${SDK_ROOT}/build" \
            SDK_ROOT="${SDK_ROOT}" \
            KERNEL_RELEASE="${KERNEL_RELEASE:-}" \
            bash "${hook}"
        done
    fi

    log_ok "staging 合成完成: ${STAGING}"
    echo "  文件数: $(find "${STAGING}" -type f | wc -l)  大小: $(du -sh "${STAGING}" | cut -f1)"
    return 0
}

# ---------------------------------------------------------------------------
# repack: staging 目录 → BTRFS 镜像 (fakeroot 保属主, mkfs.btrfs --rootdir)
#   注意: mkfs.btrfs 生成新文件系统; 大小默认与原镜像一致, UUID 可复现固定
# ---------------------------------------------------------------------------
repack_img() {
    local src="${1:-${STAGING}}"
    local img="${2:-${OUT_IMG}}"
    [ -d "${src}" ] || { log_err "目录不存在: ${src} (先 apply)"; return 1; }
    command -v fakeroot >/dev/null 2>&1 || { log_warn "未找到 fakeroot, 属主将不保真 (uid 变当前用户)"; }
    command -v btrfs >/dev/null 2>&1 || { log_err "缺少 btrfs-progs (mkfs.btrfs)"; return 1; }

    local size_mb=$(( IMG_SIZE / 1024 / 1024 ))
    log_info "打包: ${src} → ${img}"
    log_info "  大小: ${size_mb} MiB   UUID: ${IMG_UUID}"

    mkdir -p "$(dirname "${img}")"
    rm -f "${img}"

    # 1. 稀疏文件预留大小 (与原镜像一致, 保证不超 GPT 分区)
    truncate -s "${IMG_SIZE}" "${img}"

    # 2. fakeroot 保属主 + mkfs.btrfs --rootdir (固定大小 -b, 防自动扩展超分区)
    #    (chown 在 fakeroot 内是伪操作, 让 mkfs 读到 root 属主)
    #    注意: fakeroot sh -c 内不能用单引号嵌套 (会被转义破坏 -b 参数)
    if ! fakeroot sh -c "chown -R 0:0 ${src} 2>/dev/null || true; mkfs.btrfs -f -b ${IMG_SIZE} -U ${IMG_UUID} --rootdir ${src} ${img} >/dev/null 2>&1"; then
        log_err "mkfs.btrfs 打包失败"
        log_err "  (若提示需要权限: 请在你的终端执行下面命令, 或 sudo -v 后重试)"
        echo "    fakeroot sh -c \"chown -R 0:0 ${src} && mkfs.btrfs -f -b ${IMG_SIZE} -U ${IMG_UUID} --rootdir ${src} ${img}\""
        return 1
    fi

    log_ok "打包完成: ${img} ($(stat -c%s "${img}") bytes)"
    log_ok "实际占用: $(du -h "${img}" | cut -f1)"
    return 0
}

# ---------------------------------------------------------------------------
# build: apply + repack (完整打包)
# ---------------------------------------------------------------------------
cmd_build() {
    apply_overlay || return 1
    repack_img || return 1
    log_ok "system.img 打包完成: ${OUT_IMG}"
    log_info "烧录: ./scripts/flash.sh (或参考 build/output/ 内 rawprogram xml)"
    return 0
}

# ---------------------------------------------------------------------------
# remove: 登记删除路径到 overlay-remove.list (声明式, 下次打包生效)
# ---------------------------------------------------------------------------
cmd_remove() {
    local target="${1:-}"
    [ -n "${target}" ] || { log_err "用法: $0 remove <路径>"; return 1; }
    mkdir -p "${OVERLAY_DIR}"

    local rel
    case "${target}" in
        /*) rel="${target#/}" ;;
        *)  rel="${target}" ;;
    esac

    if [ -f "${REMOVE_LIST}" ] && grep -qxF "${rel}" "${REMOVE_LIST}" 2>/dev/null; then
        log_warn "已在删除清单中: /${rel}"
    else
        echo "${rel}" >> "${REMOVE_LIST}"
        log_ok "已登记删除: /${rel} → ${REMOVE_LIST}"
    fi
    log_info "下次打包生效: ./tools/build-rootfs.sh build"
}

# ---------------------------------------------------------------------------
# clean: 清理 staging 与挂载残留
# ---------------------------------------------------------------------------
cmd_clean() {
    local mnt
    for mnt in "${SDK_ROOT}/build/system-mnt" "${SDK_ROOT}/build/efi-mnt" "${SDK_ROOT}/build/dtb-mnt"; do
        if mountpoint -q "${mnt}" 2>/dev/null; then
            log_info "卸载残留挂载: ${mnt}"
            ${SUDO} umount "${mnt}" 2>/dev/null || log_warn "卸载失败: ${mnt}"
        fi
        [ -d "${mnt}" ] && rmdir "${mnt}" 2>/dev/null
    done
    rm -rf "${STAGING}"
    log_ok "清理完成"
}

usage() {
    echo "用法: $0 <命令>"
    echo "  check                     环境检查"
    echo "  extract [镜像] [目录]     建立 base 目录 (默认 prebuilds/base_rootfs)"
    echo "  apply                     合成 staging (base + overlay + hooks)"
    echo "  repack [目录] [镜像]      staging → system.img (mkfs.btrfs, fakeroot)"
    echo "  build                     完整打包 (= apply + repack)"
    echo "  remove <路径>             登记删除 (overlay-remove.list)"
    echo "  clean                     清理 staging/挂载残留"
    echo ""
    echo "模型: base目录 + overlay → staging → mkfs 全新生成 system.img (可复现, 不挂载修改)"
    echo "环境变量: OVERLAY_DIR, BASE_ROOTFS, SYSTEM_IMG_SIZE, SYSTEM_IMG_UUID, EXTRA_OVERLAY"
}

main() {
    local cmd="${1:-help}"
    case "${cmd}" in
        check)   check_env ;;
        extract) cmd_extract "${2:-}" "${3:-}" ;;
        apply)   apply_overlay ;;
        repack)  repack_img "${2:-}" "${3:-}" ;;
        build)   cmd_build ;;
        remove)  cmd_remove "${2:-}" ;;
        clean)   cmd_clean ;;
        help|*)  usage ;;
    esac
}

main "$@"
