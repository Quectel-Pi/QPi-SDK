#!/usr/bin/env bash
#
# Quectel M2 SDK 构建入口（source 后直接使用）
#
# 用法:
#   source build.sh
#   newapp <应用名> [模板]     # 从模板创建应用
#   buildapp <应用目录>        # 交叉编译应用
#   buildkernel / buildall     # 编译内核 / 完整固件
#   buildrootfs                # 应用 overlay 到 rootfs
#
# 命令帮助: buildhelp

_qpi_build_is_sourced() {
    [ "${BASH_SOURCE[0]}" != "$0" ]
}

QPI_SDK_TOPDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export QPI_SDK_TOPDIR
export TOPDIR="$QPI_SDK_TOPDIR"

# ---------------------------------------------------------------------------
# 应用交叉编译环境变量
# ---------------------------------------------------------------------------
export SYSROOT="$QPI_SDK_TOPDIR/prebuilds/sysroot"
export CMAKE_TOOLCHAIN_FILE="$QPI_SDK_TOPDIR/tools/cmake/aarch64-m2-debian-toolchain.cmake"
export ARCH="arm64"

# --- M2 Debian 应用工具链自动检测 ---
# M2 Debian defconfig 使用 RK_DEBIAN_TRIXIE=y, rootfs.img 为 Debian trixie
# (glibc 2.41). SDK 自带 Linaro aarch64-none-linux-gnu binutils 2.36 无法链接
# trixie glibc 的 .relr.dyn 段; 官方源码树内的 13.2 是 aarch64-none-elf,
# 只能用于 bare-metal, 不能编译 Linux 用户态程序。
#
# 因此应用 SDK 默认使用 rootfs 内自带的 Debian GCC 14/binutils 2.44, 通过
# qemu wrapper 在 x86 主机上运行; 内核编译仍由 tools/build-kernel.sh 使用
# 官方 Linaro 10.3 工具链。
# 优先级:
#   1. 用户显式指定的 QPI_CROSS_COMPILE
#   2. SDK 内置 rootfs 工具链 wrapper: aarch64-linux-gnu-
#   3. 宿主 aarch64-linux-gnu- (兜底)
#   4. SDK 自带 aarch64-none-linux-gnu- (仅适合旧 sysroot/内核, 不推荐编 app)
ROOTFS_TOOLCHAIN="$QPI_SDK_TOPDIR/toolchains/m2-debian-rootfs-toolchain"
SDK_TOOLCHAIN="$QPI_SDK_TOPDIR/toolchains/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu"
if [ -n "${QPI_CROSS_COMPILE:-}" ]; then
    export TOOLCHAIN=""
    export CROSS_COMPILE="$QPI_CROSS_COMPILE"
elif [ -x "$ROOTFS_TOOLCHAIN/bin/aarch64-linux-gnu-gcc" ]; then
    export TOOLCHAIN="$ROOTFS_TOOLCHAIN"
    export CROSS_COMPILE="aarch64-linux-gnu-"
elif command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    export TOOLCHAIN=""
    export CROSS_COMPILE="aarch64-linux-gnu-"
elif [ -x "$SDK_TOOLCHAIN/bin/aarch64-none-linux-gnu-gcc" ]; then
    export TOOLCHAIN="$SDK_TOOLCHAIN"
    export CROSS_COMPILE="aarch64-none-linux-gnu-"
else
    echo "[build.sh] 警告: 未找到可用 aarch64 交叉编译器"
    export TOOLCHAIN=""
    export CROSS_COMPILE="aarch64-none-linux-gnu-"
fi
export QPI_TOOLCHAIN="$TOOLCHAIN"

if [ -n "$TOOLCHAIN" ] && [ -d "$TOOLCHAIN/bin" ]; then
    case ":$PATH:" in
        *":$TOOLCHAIN/bin:"*) ;;
        *) export PATH="$TOOLCHAIN/bin:$PATH" ;;
    esac
fi

export CC="${CROSS_COMPILE}gcc"
export CXX="${CROSS_COMPILE}g++"
export CPP="${CROSS_COMPILE}cpp"
export AR="${CROSS_COMPILE}ar"
export AS="${CROSS_COMPILE}as"
export LD="${CROSS_COMPILE}ld"
export NM="${CROSS_COMPILE}nm"
export OBJCOPY="${CROSS_COMPILE}objcopy"
export OBJDUMP="${CROSS_COMPILE}objdump"
export RANLIB="${CROSS_COMPILE}ranlib"
export READELF="${CROSS_COMPILE}readelf"
export STRIP="${CROSS_COMPILE}strip"

export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/aarch64-linux-gnu/pkgconfig:$SYSROOT/usr/share/pkgconfig:$SYSROOT/usr/lib/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export CFLAGS="--sysroot=$SYSROOT -I$SYSROOT/usr/include -I$SYSROOT/usr/include/aarch64-linux-gnu"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="$CFLAGS"
export LDFLAGS="--sysroot=$SYSROOT -B$SYSROOT/usr/lib/aarch64-linux-gnu -L$SYSROOT/usr/lib/aarch64-linux-gnu -L$SYSROOT/lib/aarch64-linux-gnu"

QPI_TEMPLATES_DIR="$QPI_SDK_TOPDIR/docs/templates"
QPI_EXAMPLES_DIR="$QPI_SDK_TOPDIR/docs/examples"

_qpi_available_templates() {
    find "$QPI_TEMPLATES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null
}

# ---------------------------------------------------------------------------
# 应用开发
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

    local tpl_dir="$QPI_TEMPLATES_DIR/$template"
    local dst_dir="$QPI_EXAMPLES_DIR/$name"
    if [ ! -d "$tpl_dir" ]; then
        echo "ERROR: 模板不存在: $template"
        echo "可用模板: $(_qpi_available_templates)"
        return 1
    fi
    if [ -d "$dst_dir" ]; then
        echo "ERROR: 已存在: $dst_dir"
        return 1
    fi

    mkdir -p "$dst_dir"
    cp "$tpl_dir/main.c" "$tpl_dir/Makefile" "$dst_dir/" 2>/dev/null

    # 替换模板占位符
    sed -i "s/{{PROJECT_NAME}}/$name/g" "$dst_dir/main.c" "$dst_dir/Makefile"
    sed -i "s/{{MESSAGE}}/Hello from $name/g" "$dst_dir/main.c"

    echo "已创建应用: $dst_dir"
    echo "编译: buildapp $dst_dir"
}

# 交叉编译应用: buildapp <目录> (自动识别 Makefile/CMake)
buildapp() {
    local dir="${1:-.}"
    local app_dir
    app_dir="$(cd "$dir" 2>/dev/null && pwd)" || { echo "ERROR: 目录不存在: $dir"; return 1; }

    if [ -f "$app_dir/CMakeLists.txt" ]; then
        (cd "$app_dir" && cmake -S . -B build -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN_FILE" && cmake --build build) || return 1
    elif [ -f "$app_dir/Makefile" ]; then
        (cd "$app_dir" && make) || return 1
    else
        echo "ERROR: 未找到 CMakeLists.txt 或 Makefile: $app_dir"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 内核 / 固件
# ---------------------------------------------------------------------------

buildcheck() {
    "$QPI_SDK_TOPDIR/tools/build-kernel.sh" check && \
    "$QPI_SDK_TOPDIR/tools/build-rootfs.sh" check
}

buildkernel() {
    "$QPI_SDK_TOPDIR/tools/build-kernel.sh" kernel
}

buildboot() {
    "$QPI_SDK_TOPDIR/tools/build-kernel.sh" boot
}

buildoverlays() {
    "$QPI_SDK_TOPDIR/tools/build-kernel.sh" overlays
}

buildrootfs() {
    "$QPI_SDK_TOPDIR/tools/build-rootfs.sh" apply "$@"
}

buildall() {
    "$QPI_SDK_TOPDIR/tools/build-kernel.sh" all
}

# ---------------------------------------------------------------------------
# 内核配置
# ---------------------------------------------------------------------------

buildmenuconfig() {
    "$QPI_SDK_TOPDIR/tools/build-kernel.sh" menuconfig
}

builddefconfig() {
    make -f "$QPI_SDK_TOPDIR/tools/kernel-Makefile" defconfig
}

buildsavedefconfig() {
    make -f "$QPI_SDK_TOPDIR/tools/kernel-Makefile" savedefconfig
}

# ---------------------------------------------------------------------------
# 其他
# ---------------------------------------------------------------------------

buildclean() {
    "$QPI_SDK_TOPDIR/tools/build-rootfs.sh" clean
    "$QPI_SDK_TOPDIR/tools/build-kernel.sh" clean
}

buildhelp() {
    echo ""
    echo "============================================================"
    echo "  Quectel M2 SDK Build System"
    echo "============================================================"
    echo "  用法: source build.sh 后直接输入以下命令"
    echo ""
    echo "  ── 应用开发 (App) ──"
    echo "    newapp <名称> [模板]   从模板创建应用 (默认模板 hello)"
    echo "    buildapp <目录>        交叉编译应用 (自动识别 Makefile/CMake)"
    echo ""
    echo "  ── 内核 / 固件 ──"
    echo "    buildcheck             环境检查"
    echo "    buildkernel            编译内核"
    echo "    buildboot              生成 FIT boot.img"
    echo "    buildoverlays          编译设备树 overlays"
    echo "    buildrootfs            应用 overlay/ 到 rootfs 工作副本"
    echo "    buildall               完整打包 update.img"
    echo ""
    echo "  ── 内核配置 ──"
    echo "    buildmenuconfig        内核 menuconfig"
    echo "    builddefconfig         恢复默认配置"
    echo "    buildsavedefconfig     保存精简 defconfig"
    echo ""
    echo "  ── 其他 ──"
    echo "    buildclean             清理构建产物"
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
