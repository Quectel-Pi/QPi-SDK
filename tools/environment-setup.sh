#!/usr/bin/env bash
# ============================================================================
# Quectel PI H1 (QCS6490) simple-h1 交叉编译环境
# 与 QPi-SDK (M2) 的 tools/environment-setup.sh 位置/用法兼容:
#   source tools/environment-setup.sh
# 等价于: source scripts/env.sh + 应用工具链 (与 build.sh 一致)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# simple-h1 原生环境 (内核工具链 PATH / ARCH / KERNEL_* / 目录变量)
# shellcheck source=scripts/env.sh
source "${SDK_ROOT}/scripts/env.sh"

# --- 应用工具链 (与 build.sh 同款优先级) ---
ROOTFS_TOOLCHAIN="${SDK_ROOT}/toolchains/qcom-rootfs-toolchain"
export ARCH="arm64"

if [ -n "${QPI_CROSS_COMPILE:-}" ]; then
    export TOOLCHAIN=""
    export CROSS_COMPILE="${QPI_CROSS_COMPILE}"
    export CC="${CROSS_COMPILE}gcc"
    export CXX="${CROSS_COMPILE}g++"
    export AR="${CROSS_COMPILE}ar"
    export LD="${CROSS_COMPILE}ld"
elif [ -x "${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-gcc" ] && [ -d "${SDK_ROOT}/prebuilds/sysroot" ]; then
    export TOOLCHAIN="${ROOTFS_TOOLCHAIN}"
    export SYSROOT="${SDK_ROOT}/prebuilds/sysroot"
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
    export LDFLAGS="--sysroot=${SYSROOT} -L${SYSROOT}/usr/lib/aarch64-linux-gnu -L${SYSROOT}/lib/aarch64-linux-gnu"
    export CMAKE_TOOLCHAIN_FILE="${SDK_ROOT}/tools/cmake/aarch64-qcom-rootfs-toolchain.cmake"
    export PATH="${ROOTFS_TOOLCHAIN}/bin:${PATH}"
elif command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    export TOOLCHAIN=""
    export CROSS_COMPILE="aarch64-linux-gnu-"
    export CC="${CROSS_COMPILE}gcc"
    export CXX="${CROSS_COMPILE}g++"
    export AR="${CROSS_COMPILE}ar"
    export LD="${CROSS_COMPILE}ld"
else
    echo "[environment-setup.sh] 警告: 未找到 aarch64 应用交叉编译器 (可运行 tools/extract-sysroot.sh)"
    export TOOLCHAIN=""
    export CROSS_COMPILE="aarch64-qcom-linux-"
fi
export QPI_TOOLCHAIN="${TOOLCHAIN}"
