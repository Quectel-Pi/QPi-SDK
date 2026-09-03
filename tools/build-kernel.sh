#!/usr/bin/env bash
# ============================================================================
# Quectel PI H1 (QCS6490) simple-h1 内核/启动镜像打包脚本
# 命令接口与 QPi-SDK (M2) 的 tools/build-kernel.sh 兼容
# ============================================================================
# 用法:
#   ./tools/build-kernel.sh check          # 环境检查
#   ./tools/build-kernel.sh kernel         # 仅编译内核 (Image + dtb + modules)
#   ./tools/build-kernel.sh boot           # 打包启动镜像 (efi.bin + dtb.bin)
#   ./tools/build-kernel.sh overlays       # 设备树 overlays (simple-h1: 预置说明)
#   ./tools/build-kernel.sh all            # 完整: 内核 + efi.bin + dtb.bin + system.img
#   ./tools/build-kernel.sh menuconfig     # 内核 menuconfig
#   ./tools/build-kernel.sh defconfig      # 恢复基准配置
#   ./tools/build-kernel.sh savedefconfig  # 保存当前配置为基准
#   ./tools/build-kernel.sh clean          # 清理构建产物
#
# 环境变量:
#   SKIP_KERNEL=1   # all 模式下跳过内核编译 (仅应用层改动时)
#   JOBS            # 并行编译数 (默认 nproc)
# ============================================================================
set -uo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="$(cd "${TOOLS_DIR}/.." && pwd)"

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
    local tc_gcc
    tc_gcc="$(command -v aarch64-qcom-linux-gcc 2>/dev/null)"

    [ -d "${SDK_ROOT}/kernel" ] || { log_err "缺少内核源码: ${SDK_ROOT}/kernel"; ok=0; }
    [ -f "${SDK_ROOT}/prebuilds/efi.bin" ] || { log_warn "缺少原始 efi.bin (打包 boot 需要)"; }
    [ -f "${SDK_ROOT}/prebuilds/dtb.bin" ] || { log_warn "缺少原始 dtb.bin"; }
    [ -f "${SDK_ROOT}/prebuilds/system.img" ] || { log_warn "缺少原始 system.img (buildrootfs 需要)"; }
    [ -n "${tc_gcc}" ] || { log_err "未找到交叉编译器 aarch64-qcom-linux-gcc (source scripts/env.sh 或 build.sh)"; ok=0; }
    command -v rsync >/dev/null 2>&1 || { log_warn "未找到 rsync (buildrootfs 需要)"; }
    command -v fdtoverlay >/dev/null 2>&1 || { log_warn "未找到 fdtoverlay (dtbo 合并需要, 安装 dtc 包)"; }
    command -v sudo >/dev/null 2>&1 || { log_warn "未找到 sudo (镜像打包需要 root)"; }

    [ "${ok}" = "1" ] || { log_err "环境检查未通过"; return 1; }
    log_ok "环境检查通过"
    log_info "  内核源码:  ${SDK_ROOT}/kernel"
    log_info "  工具链:    ${tc_gcc:-未找到}"
    return 0
}

# ---------------------------------------------------------------------------
# 子命令 (转发到 scripts/ 原生实现)
# ---------------------------------------------------------------------------
cmd_kernel()   { "${SDK_ROOT}/scripts/build-kernel.sh" "$@"; }
cmd_boot()     { "${SDK_ROOT}/scripts/pack-efi.sh" && "${SDK_ROOT}/scripts/pack-dtb.sh"; }
cmd_all()      { "${SDK_ROOT}/scripts/build-all.sh" "$@"; }
cmd_clean()    { rm -rf "${SDK_ROOT}/build"; mkdir -p "${SDK_ROOT}/build"; log_ok "清理完成 (build/)"; }

cmd_overlays() {
    local dtbo_dir="${SDK_ROOT}/tools/uki/dtbo"
    if [ -d "${dtbo_dir}" ] && ls "${dtbo_dir}"/*.dtbo >/dev/null 2>&1; then
        log_info "设备树 overlays 已预置 (${dtbo_dir}):"
        ls -1 "${dtbo_dir}"/*.dtbo 2>/dev/null | while read -r f; do log_info "  $(basename "${f}")"; done
        log_ok "overlays 将在 buildboot/buildall 时经 fdtoverlay 合并进 efi.bin/dtb.bin"
        log_info "simple-h1 使用预编译 .dtbo (无 .dts 源码, 不执行编译)"
    else
        log_warn "未找到预置 dtbo: ${dtbo_dir}"
        return 1
    fi
    return 0
}

cmd_menuconfig() {
    # shellcheck source=scripts/env.sh
    source "${SDK_ROOT}/scripts/env.sh" >/dev/null
    cd "${KERNEL_SRC}" || return 1
    make O="${KERNEL_OUT}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" menuconfig
    log_ok "menuconfig 配置已保存到 ${KERNEL_OUT}/.config (下次编译保留)"
}

cmd_defconfig() {
    # shellcheck source=scripts/env.sh
    source "${SDK_ROOT}/scripts/env.sh" >/dev/null
    cp "${SDK_ROOT}/scripts/kernel-config" "${KERNEL_OUT}/.config"
    (cd "${KERNEL_SRC}" && make O="${KERNEL_OUT}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig)
    log_ok "基准配置已恢复 (scripts/kernel-config)"
}

cmd_savedefconfig() {
    # shellcheck source=scripts/env.sh
    source "${SDK_ROOT}/scripts/env.sh" >/dev/null
    (cd "${KERNEL_SRC}" && make O="${KERNEL_OUT}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" savedefconfig) || return 1
    cp "${KERNEL_OUT}/defconfig" "${SDK_ROOT}/scripts/kernel-config"
    log_ok "已保存基准配置: scripts/kernel-config"
    log_info "备份: scripts/kernel-config.bak"
    cp "${SDK_ROOT}/scripts/kernel-config" "${SDK_ROOT}/scripts/kernel-config.bak"
}

usage() {
    echo "用法: $0 <命令>"
    echo "  check           环境检查"
    echo "  kernel          编译内核 (Image + dtb + modules)"
    echo "  boot            打包启动镜像 (efi.bin + dtb.bin)"
    echo "  overlays        设备树 overlays (预置 dtbo 说明)"
    echo "  all             完整打包 (内核+efi.bin+dtb.bin+system.img)"
    echo "  menuconfig      内核 menuconfig"
    echo "  defconfig       恢复基准配置"
    echo "  savedefconfig   保存当前配置为基准"
    echo "  clean           清理构建产物 (build/)"
    echo ""
    echo "环境变量: SKIP_KERNEL=1 (all 跳过内核编译), JOBS"
}

main() {
    local mode="${1:-all}"
    case "$mode" in
        check)          check_env ;;
        kernel)         cmd_kernel "${@:2}" ;;
        boot)           cmd_boot ;;
        overlays)       cmd_overlays ;;
        all)            cmd_all "${@:2}" ;;
        menuconfig)     cmd_menuconfig ;;
        defconfig)      cmd_defconfig ;;
        savedefconfig)  cmd_savedefconfig ;;
        clean)          cmd_clean ;;
        *)              log_err "未知命令: $mode"; usage; exit 1 ;;
    esac
}

main "$@"
