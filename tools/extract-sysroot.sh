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

# --- 前置检查 ---------------------------------------------------------------
command -v btrfs >/dev/null 2>&1 || { log_err "缺少 btrfs-progs (btrfs)"; exit 1; }
[ -f "${IMG}" ] || { log_err "镜像不存在: ${IMG}"; exit 1; }

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
btrfs restore -i -S -x "${IMG}" "${OUT}" 2>&1 | grep -v "Operation not permitted\|setting extended attribute" | head -3 || true
log_ok "提取完成"

# --- 2/3: 修复权限 (restore 不带 -m 时丢失可执行位) --------------------------
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
    log_ok "sysroot 提取完成: ${OUT}"
    echo "  文件数: $(find "${OUT}" -type f | wc -l)  目录: $(find "${OUT}" -type d | wc -l)  符号链接: $(find "${OUT}" -type l | wc -l)"
    echo "  用法: source build.sh 后 buildapp 自动用 qemu wrapper 工具链交叉编译"
else
    log_err "sysroot 提取完成但验证未全过 (见上)"
    exit 1
fi
