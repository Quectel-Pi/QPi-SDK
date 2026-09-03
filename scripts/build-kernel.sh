#!/bin/bash
# ============================================================
# simple-h1 内核编译脚本
# 功能: 使用独立交叉工具链编译内核 (Image + dtb + modules)
# 用法: ./scripts/build-kernel.sh [clean]
#   clean 参数: 清理后重新编译
# ============================================================
set -e
cd "$(dirname "$0")/.."
source scripts/env.sh

JOBS=${JOBS:-$(nproc)}

echo "=========================================="
echo "[simple-h1] 内核编译开始"
echo "  源码:     ${KERNEL_SRC}"
echo "  输出:     ${KERNEL_OUT}"
echo "  工具链:   ${CROSS_COMPILE} ($(command -v ${CROSS_COMPILE}gcc))"
echo "  版本:     ${KERNEL_RELEASE}"
echo "  并行度:   ${JOBS}"
echo "=========================================="

# 工具链自检
if ! command -v ${CROSS_COMPILE}gcc &>/dev/null; then
    echo "[ERROR] 交叉编译器不可用: ${CROSS_COMPILE}gcc"
    echo "        请先执行: source scripts/env.sh"
    exit 1
fi
${CROSS_COMPILE}gcc --version | head -1

# 版本后缀由 scripts/kernel-config 的 CONFIG_LOCALVERSION 控制,
# 显式清除环境变量 LOCALVERSION, 防止父环境残留导致双重叠加
unset LOCALVERSION

cd "${KERNEL_SRC}"

# clean 模式
if [ "$1" = "clean" ]; then
    echo "[simple-h1] 清理旧构建..."
    rm -rf "${KERNEL_OUT}"
    mkdir -p "${KERNEL_OUT}"
fi

# 首次构建: 准备 .config
if [ ! -f "${KERNEL_OUT}/.config" ]; then
    echo "[simple-h1] 初始化 .config (基准配置已内置)"
    cp "${SDK_ROOT}/scripts/kernel-config" "${KERNEL_OUT}/.config"
fi

# 如果源码树里带了 build-kernel-out 的旧 config, 用我们维护的基准配置覆盖
# (基准配置与官方固件 6.6.116-qli-1.7-ver.1.1 一致)

# 同步配置 (处理新选项)
echo "[simple-h1] olddefconfig..."
make -j"${JOBS}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" O="${KERNEL_OUT}" olddefconfig

# 编译 Image + dtb
echo "[simple-h1] 编译 Image + dtb..."
# DTC_FLAGS="-@" 生成 __symbols__ 节点, 供 fdtoverlay 合并 dtbo 使用 (与官方一致)
make -j"${JOBS}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" O="${KERNEL_OUT}" \
    DTC_FLAGS="-@" Image dtbs

# 编译 modules
echo "[simple-h1] 编译 modules..."
make -j"${JOBS}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" O="${KERNEL_OUT}" modules

# 安装 modules 到 staging 目录
MOD_STAGE="${BUILD_DIR}/modules-staging"
rm -rf "${MOD_STAGE}"
echo "[simple-h1] 安装 modules 到 ${MOD_STAGE}/lib/modules/${KERNEL_RELEASE}"
make -j"${JOBS}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" O="${KERNEL_OUT}" \
    INSTALL_MOD_PATH="${MOD_STAGE}" modules_install

echo ""
echo "=========================================="
echo "[simple-h1] 内核编译完成 ✓"
echo "  Image:      ${KERNEL_OUT}/arch/arm64/boot/Image"
echo "  DTB:        ${KERNEL_OUT}/arch/arm64/boot/dts/qcom/${DTB_NAME}"
echo "  Modules:    ${MOD_STAGE}/lib/modules/${KERNEL_RELEASE}"
echo "=========================================="
