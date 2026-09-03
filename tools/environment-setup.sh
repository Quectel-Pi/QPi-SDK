#!/bin/bash

# Quectel M2 交叉编译环境
# 目录结构: tools/ ../prebuilds/sysroot ../toolchains ../kernel
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/.." && pwd)"

export SYSROOT="$ROOT_DIR/prebuilds/sysroot"

# --- M2 Debian 应用工具链自动检测 (与 build.sh 一致) ---
# M2 Debian defconfig 使用 RK_DEBIAN_TRIXIE=y, rootfs.img 为 Debian trixie
# (glibc 2.41). 默认使用 rootfs 内 Debian GCC 14/binutils 2.44 的 qemu wrapper;
# 内核编译仍由 tools/build-kernel.sh 使用官方 Linaro 10.3 工具链。
ROOTFS_TOOLCHAIN="$ROOT_DIR/toolchains/m2-debian-rootfs-toolchain"
SDK_TOOLCHAIN="$ROOT_DIR/toolchains/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu"
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
    echo "[environment-setup.sh] 警告: 未找到可用 aarch64 交叉编译器"
    export TOOLCHAIN=""
    export CROSS_COMPILE="aarch64-none-linux-gnu-"
fi

if [ -n "$TOOLCHAIN" ] && [ -d "$TOOLCHAIN/bin" ]; then
    export PATH="$TOOLCHAIN/bin:$PATH"
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
export CPPFLAGS="--sysroot=$SYSROOT -I$SYSROOT/usr/include -I$SYSROOT/usr/include/aarch64-linux-gnu"
export LDFLAGS="--sysroot=$SYSROOT -B$SYSROOT/usr/lib/aarch64-linux-gnu -L$SYSROOT/usr/lib/aarch64-linux-gnu -L$SYSROOT/lib/aarch64-linux-gnu"

export CMAKE_TOOLCHAIN_FILE="$TOOLS_DIR/cmake/aarch64-m2-debian-toolchain.cmake"

alias m2-gcc='aarch64-none-linux-gnu-gcc --sysroot=$SYSROOT'
alias m2-g++='aarch64-none-linux-gnu-g++ --sysroot=$SYSROOT'

echo "M2 Debian App SDK environment ready"
echo "  TOOLS_DIR=$TOOLS_DIR"
echo "  SYSROOT=$SYSROOT"
echo "  TOOLCHAIN=$TOOLCHAIN"
echo "  CC=$CC"
echo "  CMAKE_TOOLCHAIN_FILE=$CMAKE_TOOLCHAIN_FILE"
