#!/usr/bin/env bash
# ============================================================================
# extract-sysroot.sh - 从 system.img (BTRFS) 提取交叉编译 sysroot (免 root)
# ============================================================================
# 背景: 与 QPi-SDK (M2) 的 prebuilds/sysroot 同款布局。
#   - M2:  ext4 rootfs.img, 用 7z + debugfs 提取 (免 root)
#   - H1:  BTRFS system.img, 用 btrfs restore 提取 (免 root, 符号链接原生保留,
#          无需 7z+debugfs 重建; 比 M2 更简单)
#   镜像内含完整开发环境 (gcc-14 + binutils + libc6-dev), 供 qemu wrapper
#   工具链 (toolchains/qcom-rootfs-toolchain/) 交叉编译应用。
#
# 用法:
#   ./tools/extract-sysroot.sh                       # system.img -> prebuilds/sysroot
#   ./tools/extract-sysroot.sh <system.img> <输出目录>
#   FORCE=1 ./tools/extract-sysroot.sh               # 输出已存在时自动备份
#
# 依赖: btrfs-progs (btrfs)   — 免 root
# ============================================================================
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="$(cd "${TOOLS_DIR}/.." && pwd)"
IMG="${1:-${SDK_ROOT}/prebuilds/system.img}"
OUT="${2:-${SDK_ROOT}/prebuilds/sysroot}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# --- 进度上报 (与 fetch-prebuilds.sh 同一约定, 由 VS Code 插件消费) ----------
# 标记行不会显示在插件终端里 (被转成进度事件); 手工运行脚本时会看到, 属正常现象。
# label 是当前阶段的展示文案 —— SDK 最了解自己的阶段, 插件不维护阶段名称,
# 各 SDK (M1/M2/H1/L1...) 可以自定义。
emit_progress() { # <已处理字节> <估算总字节> <整体百分比> <阶段文案>
    local done="${1:-0}" total="${2:-0}" pct="${3:-0}" label="${4:-}"
    case "${done}"  in ''|*[!0-9]*) done=0 ;; esac
    case "${total}" in ''|*[!0-9]*) total=0 ;; esac
    case "${pct}"   in ''|*[!0-9]*) pct=0 ;; esac
    [ "${pct}" -gt 100 ] && pct=100
    printf '[QPI-PROGRESS] total=%s done=%s pct=%s label=%s\n' \
        "${total}" "${done}" "${pct}" "${label}"
}

# 目录当前字节数 (du 会递归 stat: 实测 20 万文件约 0.13s, 每秒一次开销可忽略)
_dir_bytes() {
    local b
    b="$(du -sb "$1" 2>/dev/null | cut -f1)" || true
    case "${b}" in ''|*[!0-9]*) b=0 ;; esac
    echo "${b}"
}

# 镜像内实际占用字节 = 提取进度的估算分母 (btrfs restore 自己不报任何进度)
_img_used_bytes() {
    btrfs inspect-internal dump-super "$1" 2>/dev/null \
        | awk '$1=="bytes_used"{print $2; exit}'
}

# 阶段1 占总进度的 0..STAGE1_MAX。估算值可能偏差 (镜像压缩/共享 extent 会让
# bytes_used 小于实际文件大小), 所以封顶而不是直接给到 100 —— 后面还有
# 权限修复与验证两个阶段。
STAGE1_MAX=80
emit_stage1_progress() {
    local done pct=0
    done="$(_dir_bytes "${OUT}")"
    if [ "${EST_BYTES:-0}" -gt 0 ]; then
        pct=$(( done * STAGE1_MAX / EST_BYTES ))
        [ "${pct}" -gt "${STAGE1_MAX}" ] && pct="${STAGE1_MAX}"
    fi
    emit_progress "${done}" "${EST_BYTES:-0}" "${pct}" "正在提取 sysroot"
}

# --- 前置检查 ---------------------------------------------------------------
command -v btrfs >/dev/null 2>&1 || { log_err "缺少 btrfs-progs (btrfs)"; exit 1; }
if [ ! -f "${IMG}" ]; then
    log_err "镜像不存在: ${IMG}"
    log_err "  获取固件底包: ./tools/fetch-prebuilds.sh fetch   (= source build.sh && buildfetch fetch)"
    exit 1
fi

need_mb=$(du -m "${IMG}" | cut -f1)
avail_mb=$(df -Pm "$(dirname "${OUT}")" | awk 'NR==2{print $4}')
log_info "system.img: $(du -h "${IMG}" | cut -f1) (提取后约 ${need_mb}MB), 可用 ${avail_mb}MB"
if [ "${avail_mb}" -lt $((need_mb * 2)) ]; then
    log_err "磁盘空间不足: 需要约 $((need_mb * 2))MB, 可用 ${avail_mb}MB"
    exit 1
fi

# --- 输出目录处理 -----------------------------------------------------------
if [ -d "${OUT}" ] && [ -n "$(ls -A "${OUT}" 2>/dev/null)" ]; then
    if [ "${FORCE:-0}" = "1" ]; then
        BAK="${OUT}.bak.$(date +%Y%m%d%H%M%S)"
        mv "${OUT}" "${BAK}"
        log_warn "旧 sysroot 已备份到: ${BAK}"
    else
        log_err "输出目录已存在且非空: ${OUT} (删除/备份, 或 FORCE=1)"
        exit 1
    fi
fi
mkdir -p "${OUT}"

# --- 1/3: btrfs restore 提取 (免 root) --------------------------------------
#  -S 保留符号链接  -x 保留 xattr (普通用户下 security.* 会失败, 忽略)
#  不带 -m (metadata/owner 需 root; 交叉编译不依赖属主)
log_info "[1/3] btrfs restore 提取 (免 root): ${IMG} → ${OUT} ..."
# btrfs restore 没有任何进度输出, 且这一步要写数 GB / 十几万文件, 耗时通常远
# 超下载。因此改成【后台执行 + 每秒轮询已提取字节数】上报进度:
# 否则整段提取期间一行输出都没有, 终端像卡死, 插件 SSE 也会因长时间无数据
# 被 undici bodyTimeout 掐断。
EST_BYTES="$(_img_used_bytes "${IMG}")"
case "${EST_BYTES}" in ''|*[!0-9]*) EST_BYTES=0 ;; esac
if [ "${EST_BYTES}" -gt 0 ]; then
    log_info "镜像内占用约 $(awk -v b="${EST_BYTES}" 'BEGIN{printf "%.1f", b/1048576}')MB (用作进度估算; 实际提取量会有偏差)"
else
    log_warn "无法读取镜像占用字节, 进度只显示已提取量"
fi
RESTORE_LOG="$(mktemp)"
btrfs restore -i -S -x "${IMG}" "${OUT}" > "${RESTORE_LOG}" 2>&1 &
RESTORE_PID=$!
while kill -0 "${RESTORE_PID}" 2>/dev/null; do
    emit_stage1_progress
    sleep 1
done
# 与原实现一致: btrfs 的失败不在这里中止 (交给 [3/3] 验证裁决), 只回显异常行
wait "${RESTORE_PID}" || true
emit_stage1_progress
grep -v "Operation not permitted\|setting extended attribute" "${RESTORE_LOG}" 2>/dev/null | head -3 || true
rm -f "${RESTORE_LOG}"
log_ok "提取完成"

# --- 2/3: 修复权限 (restore 不带 -m 时丢失可执行位) --------------------------
emit_progress 0 0 80 "正在修复权限"
log_info "[2/3] 修复权限 (bin/sbin/libexec 可执行, 与 M2 一致) ..."
find "${OUT}" -type d -exec chmod 755 {} + 2>/dev/null || true
find "${OUT}" -type f -exec chmod 644 {} + 2>/dev/null || true
for d in bin sbin usr/bin usr/sbin usr/libexec usr/lib/gcc; do
    [ -d "${OUT}/${d}" ] && find "${OUT}/${d}" -type f -exec chmod 755 {} + 2>/dev/null || true
done
# 清空 /dev (设备节点无用)
rm -rf "${OUT}/dev"; mkdir -p "${OUT}/dev"
log_ok "权限修复完成"

# --- 3/3: 验证 --------------------------------------------------------------
emit_progress 0 0 92 "正在验证 sysroot"
log_info "[3/3] 验证 ..."
ok=1
vchk() { if eval "$2"; then log_ok "  ✓ $1"; else log_err "  ✗ $1"; ok=0; fi }
vchk "符号链接保留 (>10000)" "[ $(find "${OUT}" -type l | wc -l) -gt 10000 ]"
vchk "libc.so 是链接脚本" "grep -q 'GROUP\|INPUT' '${OUT}/usr/lib/aarch64-linux-gnu/libc.so'"
vchk "libc.so.6 存在" "[ -e '${OUT}/lib/aarch64-linux-gnu/libc.so.6' ]"
vchk "stdio.h 存在" "[ -f '${OUT}/usr/include/stdio.h' ]"
vchk "gcc-14 存在" "[ -x '${OUT}/usr/bin/gcc-14' ]"
vchk "crt1.o 存在" "[ -f '${OUT}/usr/lib/aarch64-linux-gnu/crt1.o' ]"
vchk "dev/ 为空" "[ -z \"\$(ls -A '${OUT}/dev')\" ]"

echo ""
if [ "${ok}" = "1" ]; then
    emit_progress 0 0 100 "sysroot 就绪"
    log_ok "sysroot 提取完成: ${OUT}"
    echo "  文件数: $(find "${OUT}" -type f | wc -l)  目录: $(find "${OUT}" -type d | wc -l)  符号链接: $(find "${OUT}" -type l | wc -l)"
    echo "  用法: source build.sh 后 buildapp 自动用 qemu wrapper 工具链交叉编译"
else
    log_err "sysroot 提取完成但验证未全过 (见上)"
    exit 1
fi
