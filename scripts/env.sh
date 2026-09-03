#!/bin/bash
# ============================================================
# simple-h1 SDK 环境脚本
# 用法: source scripts/env.sh
# ============================================================
# 项目根目录 (本脚本所在目录的上级)
SDK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SDK_ROOT

# 版本配置 (与原生固件一致, 可修改)
export KERNEL_VERSION="6.6.116"
# 注意: LOCALVERSION 仅用于计算 KERNEL_RELEASE 字符串, 不能 export
# 内核版本后缀由 scripts/kernel-config 中的 CONFIG_LOCALVERSION 控制,
# 若 export 会被内核 Makefile 读取导致双重叠加
LOCALVERSION="-qli-1.7-ver.1.1"
export KERNEL_RELEASE="${KERNEL_VERSION}${LOCALVERSION}"
export MACHINE="qcm6490-idp"
export DTB_NAME="qcs6490-idp-pi.dtb"

# 目录
export KERNEL_SRC="${SDK_ROOT}/kernel"              # 内核源码
export KERNEL_OUT="${SDK_ROOT}/build/kernel"        # 内核编译输出 (O=)
export OVERLAY_DIR="${SDK_ROOT}/overlay"            # 文件系统增量目录
export PREBUILDS_DIR="${SDK_ROOT}/prebuilds"        # 原始镜像
export TOOLS_DIR="${SDK_ROOT}/tools"                # 工具
export TOOLCHAIN_DIR="${SDK_ROOT}/toolchains"       # 交叉编译链
export BUILD_DIR="${SDK_ROOT}/build"                # 编译产物
export OUT_DIR="${SDK_ROOT}/build/output"           # 最终固件输出

# 交叉编译链 PATH
export PATH="${TOOLCHAIN_DIR}/gcc/bin/aarch64-qcom-linux:${PATH}"
export CROSS_COMPILE="aarch64-qcom-linux-"
export ARCH="arm64"

# UKI 打包工具
export UKIFY="${TOOLS_DIR}/uki/ukify"
export EFI_STUB="${TOOLS_DIR}/uki/linuxaa64.efi.stub"
export INITRAMFS="${TOOLS_DIR}/uki/initramfs-qcom-image-qcm6490-idp.cpio.gz"
export BASE_DTB="${TOOLS_DIR}/uki/${DTB_NAME}"

# 内核 cmdline (与原生固件一致)
export KERNEL_CMDLINE="root=/dev/disk/by-partlabel/system rw rootwait console=ttynull pcie_pme=nomsi rcupdate.rcu_expedited=1 rcu_nocbs=0-7 kpti=off kasan=off kasan.stacktrace=off no-steal-acc nokaslr swiotlb=128 mitigations=auto net.ifnames=0"

# 确保目录存在
mkdir -p "${KERNEL_OUT}" "${OUT_DIR}"

echo "[simple-h1] SDK_ROOT=${SDK_ROOT}"
echo "[simple-h1] KERNEL_RELEASE=${KERNEL_RELEASE}"
echo "[simple-h1] CROSS_COMPILE=${CROSS_COMPILE}"
