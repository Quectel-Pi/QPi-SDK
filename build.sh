#!/usr/bin/env bash
#
# Quectel PI H1 (QCS6490) simple-h1 SDK 构建入口
# 命令集与 QPi-SDK (M2/RK3576) 的 build.sh 兼容 —— 同一套命令在两个 SDK 通用
#
# 用法:
#   source build.sh
#   newapp <应用名> [模板]     # 从模板创建应用 (默认模板 hello)
#   buildapp <应用目录>        # 编译应用 (自动识别 Makefile/CMake)
#   buildcheck                # 环境检查
#   buildkernel               # 编译内核 (Image + dtb + modules)
#   buildboot                 # 打包启动镜像 (efi.bin + dtb.bin)
#   buildoverlays             # 设备树 overlays (simple-h1: 预置 dtbo, 见说明)
#   buildrootfs               # 应用 overlay/ 打包 system.img
#   buildall                  # 完整打包 (内核 + efi.bin + dtb.bin + system.img)
#   buildmenuconfig           # 内核 menuconfig
#   builddefconfig            # 恢复基准配置
#   buildsavedefconfig        # 保存当前配置为基准
#   buildclean                # 清理构建产物
#
# 命令帮助: buildhelp
# 直接执行: ./build.sh <命令>  (与 source 后调用等价)

_qpi_build_is_sourced() {
    [ "${BASH_SOURCE[0]}" != "$0" ]
}

QPI_SDK_TOPDIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
export QPI_SDK_TOPDIR
export TOPDIR="$QPI_SDK_TOPDIR"

# ---------------------------------------------------------------------------
# simple-h1 原生环境 (工具链 PATH / CROSS_COMPILE / ARCH / 目录变量)
# ---------------------------------------------------------------------------
# shellcheck source=scripts/env.sh
source "${QPI_SDK_TOPDIR}/scripts/env.sh" >/dev/null

# ---------------------------------------------------------------------------
# 应用交叉编译环境变量 (与 M2 build.sh 导出语义一致)
#   工具链优先级 (M2 同款):
#     1. QPI_CROSS_COMPILE 显式指定
#     2. qcom-rootfs-toolchain (qemu wrapper, 跑 sysroot 内 gcc-14) ← 默认
#     3. 宿主 aarch64-linux-gnu- (兜底)
#   注意: simple-h1 的 aarch64-qcom-linux-gcc 是内核工具链 (无 libc sysroot),
#   不能链接用户态程序, 不用于 buildapp。
# ---------------------------------------------------------------------------
export ARCH="arm64"
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-qcom-linux-}"

ROOTFS_TOOLCHAIN="${QPI_SDK_TOPDIR}/toolchains/qcom-rootfs-toolchain"
if [ -n "${QPI_CROSS_COMPILE:-}" ]; then
    export TOOLCHAIN=""
    export CROSS_COMPILE="${QPI_CROSS_COMPILE}"
    export CC="${CROSS_COMPILE}gcc"
    export CXX="${CROSS_COMPILE}g++"
    export AR="${CROSS_COMPILE}ar"
    export LD="${CROSS_COMPILE}ld"
elif [ -x "${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-gcc" ] && [ -d "${QPI_SDK_TOPDIR}/prebuilds/sysroot" ]; then
    export TOOLCHAIN="${ROOTFS_TOOLCHAIN}"
    export SYSROOT="${QPI_SDK_TOPDIR}/prebuilds/sysroot"
    export CROSS_COMPILE="aarch64-linux-gnu-"
    export CC="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-gcc"
    export CXX="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-g++"
    export CPP="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-cpp"
    export AR="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-ar"
    export AS="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-as"
    export LD="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-ld"
    export NM="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-nm"
    export OBJCOPY="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-objcopy"
    export OBJDUMP="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-objdump"
    export RANLIB="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-ranlib"
    export READELF="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-readelf"
    export STRIP="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-strip"
    export CFLAGS="--sysroot=${SYSROOT} -I${SYSROOT}/usr/include -I${SYSROOT}/usr/include/aarch64-linux-gnu"
    export CXXFLAGS="${CFLAGS}"
    export CPPFLAGS="${CFLAGS}"
    export LDFLAGS="--sysroot=${SYSROOT} -L${SYSROOT}/usr/lib/aarch64-linux-gnu -L${SYSROOT}/lib/aarch64-linux-gnu"
    export CMAKE_TOOLCHAIN_FILE="${QPI_SDK_TOPDIR}/tools/cmake/aarch64-qcom-rootfs-toolchain.cmake"
elif command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    export TOOLCHAIN=""
    export CROSS_COMPILE="aarch64-linux-gnu-"
    export CC="${CROSS_COMPILE}gcc"
    export CXX="${CROSS_COMPILE}g++"
    export AR="${CROSS_COMPILE}ar"
    export LD="${CROSS_COMPILE}ld"
else
    echo "[build.sh] 警告: 未找到可用的 aarch64 应用交叉编译器"
    echo "          (可运行 tools/extract-sysroot.sh 提取 sysroot, 启用 qemu wrapper 工具链)"
    export TOOLCHAIN=""
    export CROSS_COMPILE="aarch64-qcom-linux-"
fi
export QPI_TOOLCHAIN="${TOOLCHAIN}"

if [ -n "${TOOLCHAIN}" ] && [ -d "${TOOLCHAIN}/bin" ]; then
    case ":${PATH}:" in
        *":${TOOLCHAIN}/bin:"*) ;;
        *) export PATH="${TOOLCHAIN}/bin:${PATH}" ;;
    esac
fi

QPI_TEMPLATES_DIR="${QPI_SDK_TOPDIR}/docs/templates"
QPI_APPS_DIR="${QPI_SDK_TOPDIR}/apps"

_qpi_available_templates() {
    find "${QPI_TEMPLATES_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null
}

# ---------------------------------------------------------------------------
# 应用开发 (与 M2 语义一致; 应用创建到 apps/ 目录)
# ---------------------------------------------------------------------------

# 从模板创建新应用: newapp <名称> [模板名]
newapp() {
    local name="${1:-}"
    local template="${2:-hello}"

    if [ -z "$name" ]; then
        echo "用法: newapp <应用名> [模板名]"
        echo "可用模板: $(_qpi_available_templates)"
        return 1
    fi
    case "$name" in
        *[!a-zA-Z0-9_]*) echo "ERROR: 应用名仅限字母/数字/下划线"; return 1 ;;
    esac

    local tpl_dir="${QPI_TEMPLATES_DIR}/${template}"
    local dst_dir="${QPI_APPS_DIR}/${name}"
    if [ ! -d "${tpl_dir}" ]; then
        echo "ERROR: 模板不存在: ${template}"
        echo "可用模板: $(_qpi_available_templates)"
        return 1
    fi
    if [ -d "${dst_dir}" ]; then
        echo "ERROR: 已存在: ${dst_dir}"
        return 1
    fi

    mkdir -p "${dst_dir}"
    cp "${tpl_dir}/main.c" "${tpl_dir}/Makefile" "${dst_dir}/" 2>/dev/null

    # 替换模板占位符 (与 M2 模板约定一致)
    sed -i "s/{{PROJECT_NAME}}/${name}/g" "${dst_dir}/main.c" "${dst_dir}/Makefile"
    sed -i "s/{{MESSAGE}}/Hello from ${name}/g" "${dst_dir}/main.c"

    echo "已创建应用: ${dst_dir}"
    echo "编译: buildapp ${dst_dir}"
    echo "安装到 overlay: ./scripts/install-app.sh apps/${name}  (然后 buildrootfs 打包)"
}

# 编译应用: buildapp <目录> (自动识别 Makefile/CMake, 与 M2 一致)
buildapp() {
    local dir="${1:-.}"
    local app_dir
    app_dir="$(cd "$dir" 2>/dev/null && pwd)" || { echo "ERROR: 目录不存在: $dir"; return 1; }

    if [ -f "${app_dir}/CMakeLists.txt" ]; then
        (cd "${app_dir}" && cmake -S . -B build && cmake --build build) || return 1
    elif [ -f "${app_dir}/Makefile" ]; then
        (cd "${app_dir}" && make) || return 1
    else
        echo "ERROR: 未找到 CMakeLists.txt 或 Makefile: ${app_dir}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 内核 / 固件 (映射到 scripts/ 原生实现)
# ---------------------------------------------------------------------------

buildcheck() {
    "${QPI_SDK_TOPDIR}/tools/build-kernel.sh" check
}

buildkernel() {
    "${QPI_SDK_TOPDIR}/scripts/build-kernel.sh" "$@"
}

buildboot() {
    "${QPI_SDK_TOPDIR}/scripts/pack-efi.sh" && \
    "${QPI_SDK_TOPDIR}/scripts/pack-dtb.sh"
}

buildoverlays() {
    "${QPI_SDK_TOPDIR}/tools/build-kernel.sh" overlays
}

buildrootfs() {
    # 目录级可复现打包: base + overlay → staging → mkfs 全新生成 system.img
    # (免挂载修改, 免 root; 见 tools/build-rootfs.sh 头部说明)
    "${QPI_SDK_TOPDIR}/tools/build-rootfs.sh" build
}

buildall() {
    # 全量: 内核(可跳过) + efi.bin/dtb.bin + system.img (目录级可复现打包)
    # 应用层改动: SKIP_KERNEL=1 buildall
    if [ "${SKIP_KERNEL:-0}" != "1" ]; then
        "${QPI_SDK_TOPDIR}/scripts/build-kernel.sh" || return 1
    else
        echo "[build.sh] SKIP_KERNEL=1, 跳过内核编译"
    fi
    "${QPI_SDK_TOPDIR}/scripts/pack-efi.sh" || return 1
    "${QPI_SDK_TOPDIR}/scripts/pack-dtb.sh" || return 1
    "${QPI_SDK_TOPDIR}/tools/build-rootfs.sh" build || return 1
    echo "[build.sh] buildall 完成: build/output/{efi.bin, dtb.bin, system.img}"
}

# ---------------------------------------------------------------------------
# 内核配置
# ---------------------------------------------------------------------------

buildmenuconfig() {
    cd "${KERNEL_SRC}" && make O="${KERNEL_OUT}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" menuconfig
    echo "menuconfig 配置已保存到 ${KERNEL_OUT}/.config"
    echo "下次 buildkernel/buildall 会保留此配置 (增量编译)"
}

builddefconfig() {
    # 恢复基准配置 (scripts/kernel-config, 与官方 6.6.116-qli-1.7-ver.1.1 一致)
    echo "恢复基准配置: scripts/kernel-config -> ${KERNEL_OUT}/.config"
    cp "${QPI_SDK_TOPDIR}/scripts/kernel-config" "${KERNEL_OUT}/.config"
    (cd "${KERNEL_SRC}" && make O="${KERNEL_OUT}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig)
    echo "基准配置已恢复"
}

buildsavedefconfig() {
    # 将当前 .config 精简保存为基准 (备份原文件)
    (cd "${KERNEL_SRC}" && make O="${KERNEL_OUT}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" savedefconfig) || return 1
    cp "${KERNEL_OUT}/defconfig" "${QPI_SDK_TOPDIR}/scripts/kernel-config" \
        && echo "已保存基准配置: scripts/kernel-config (旧配置备份: scripts/kernel-config.bak)" \
        && cp "${QPI_SDK_TOPDIR}/scripts/kernel-config" "${QPI_SDK_TOPDIR}/scripts/kernel-config.bak"
}

# ---------------------------------------------------------------------------
# 其他
# ---------------------------------------------------------------------------

buildclean() {
    echo "清理构建产物 (build/)..."
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"
    echo "清理完成 (下次 buildall 会重新生成)"
}

buildhelp() {
    echo ""
    echo "============================================================"
    echo "  Quectel PI H1 (QCS6490) simple-h1 SDK Build System"
    echo "  命令集与 QPi-SDK (M2) 兼容"
    echo "============================================================"
    echo "  用法: source build.sh 后直接输入以下命令"
    echo ""
    echo "  ── 应用开发 (App) ──"
    echo "    newapp <名称> [模板]   从模板创建应用 (默认模板 hello)"
    echo "    buildapp <目录>        编译应用 (自动识别 Makefile/CMake)"
    echo ""
    echo "  ── 内核 / 固件 ──"
    echo "    buildcheck             环境检查"
    echo "    buildkernel            编译内核 (Image + dtb + modules)"
    echo "    buildboot              打包启动镜像 (efi.bin + dtb.bin)"
    echo "    buildoverlays          设备树 overlays (预置 dtbo 说明)"
    echo "    buildrootfs            应用 overlay/ 打包 system.img"
    echo "    buildall               完整打包 (内核+efi.bin+dtb.bin+system.img)"
    echo "                           (仅应用层改动: SKIP_KERNEL=1 buildall)"
    echo ""
    echo "  ── 内核配置 ──"
    echo "    buildmenuconfig        内核 menuconfig"
    echo "    builddefconfig         恢复基准配置"
    echo "    buildsavedefconfig     保存当前配置为基准 (kernel-config)"
    echo ""
    echo "  ── 其他 ──"
    echo "    buildclean             清理构建产物 (build/)"
    echo "============================================================"
    echo ""
}

# ---------------------------------------------------------------------------
# 入口: source 时打印帮助; 直接执行时按参数分发
# ---------------------------------------------------------------------------
if _qpi_build_is_sourced; then
    buildhelp
else
    cmd="${1:-help}"
    shift || true
    case "$cmd" in
        newapp|new) newapp "$@" ;;
        app|buildapp) buildapp "$@" ;;
        check|buildcheck) buildcheck "$@" ;;
        kernel|buildkernel) buildkernel "$@" ;;
        boot|buildboot) buildboot "$@" ;;
        overlays|buildoverlays) buildoverlays "$@" ;;
        rootfs|buildrootfs) buildrootfs "$@" ;;
        all|buildall) buildall "$@" ;;
        menuconfig|buildmenuconfig) buildmenuconfig "$@" ;;
        defconfig|builddefconfig) builddefconfig "$@" ;;
        savedefconfig|buildsavedefconfig) buildsavedefconfig "$@" ;;
        clean|buildclean) buildclean "$@" ;;
        help|--help|-h) buildhelp ;;
        *) echo "ERROR: unknown command: $cmd"; buildhelp; exit 1 ;;
    esac
fi
