#!/bin/bash
# ============================================================
# simple-h1 efi.bin 打包脚本
# 功能: 用 ukify 将内核 Image + dtb + initramfs 打包为 UKI,
#       替换 efi.bin (FAT 启动分区) 内的 UKI 文件
# 用法: ./scripts/pack-efi.sh [Image路径] [dtb路径]
# ============================================================
set -e
cd "$(dirname "$0")/.."
source scripts/env.sh

# 参数: 内核 Image 和 dtb (默认用编译产物)
IMAGE="${1:-${KERNEL_OUT}/arch/arm64/boot/Image}"
DTB="${2:-${KERNEL_OUT}/arch/arm64/boot/dts/qcom/${DTB_NAME}}"
EFI_IMG="${OUT_DIR}/efi.bin"
UKI_NAME="linux-${MACHINE}.efi"   # linux-qcm6490-idp.efi

# sudo 支持 (与 pack-system.sh 一致)
SUDO="${SUDO:-sudo}"
if ! ${SUDO} -n true 2>/dev/null; then
    echo "[simple-h1] 需要 root 权限, 请先执行: sudo -v"
    ${SUDO} -v
fi

# 合并 dtbo (与官方 linux-qcom-mergedtb 一致)
DTBO_DIR="${TOOLS_DIR}/uki/dtbo"
MERGED_DTB="${BUILD_DIR}/merged-${DTB_NAME}"
if [ -f "${DTBO_DIR}/qcm6490-graphics.dtbo" ] && [ -f "${DTBO_DIR}/qcm6490-camera-rb3.dtbo" ] && [ -f "${DTBO_DIR}/qcm6490-video.dtbo" ]; then
    echo "[simple-h1] 合并 dtbo overlay -> ${MERGED_DTB}"
    cp "${DTB}" "${MERGED_DTB}"
    fdtoverlay -i "${MERGED_DTB}" -o "${MERGED_DTB}.out" \
        "${DTBO_DIR}/qcm6490-graphics.dtbo" \
        "${DTBO_DIR}/qcm6490-camera-rb3.dtbo" \
        "${DTBO_DIR}/qcm6490-video.dtbo"
    mv "${MERGED_DTB}.out" "${MERGED_DTB}"
    DTB="${MERGED_DTB}"
fi

for f in "${IMAGE}" "${DTB}" "${INITRAMFS}" "${EFI_STUB}"; do
    [ -f "$f" ] || { echo "[ERROR] 缺少文件: $f"; exit 1; }
done

echo "=========================================="
echo "[simple-h1] 打包 efi.bin"
echo "  Image:      ${IMAGE}"
echo "  DTB:        ${DTB}"
echo "  Initramfs:  ${INITRAMFS}"
echo "  Cmdline:    ${KERNEL_CMDLINE}"
echo "=========================================="

# 1. 生成 UKI
UKI="${BUILD_DIR}/${UKI_NAME}"
echo "[simple-h1] ukify 生成 UKI..."
python3 "${UKIFY}" build \
    --efi-arch=aa64 \
    --stub="${EFI_STUB}" \
    --linux="${IMAGE}" \
    --initrd="${INITRAMFS}" \
    --cmdline="${KERNEL_CMDLINE}" \
    --devicetree="${DTB}" \
    --os-release="@${TOOLS_DIR}/uki/os-release" \
    --uname="${KERNEL_RELEASE}" \
    --output="${UKI}"

echo "[simple-h1] UKI: ${UKI} ($(stat -c%s "${UKI}") bytes)"

# 2. 从 prebuilds 复制原始 efi.bin
rm -f "${EFI_IMG}"
cp "${PREBUILDS_DIR}/efi.bin" "${EFI_IMG}"

# 3. 挂载并替换 UKI
MNT="${BUILD_DIR}/efi-mnt"
mkdir -p "${MNT}"
echo "[simple-h1] 挂载 efi.bin..."
${SUDO} mount -o loop,rw "${EFI_IMG}" "${MNT}"

# 查找 UKI 目标路径: 优先 /EFI/Linux/, 其次 /ostree/poky-*/vmlinuz-*
TARGET=""
if [ -f "${MNT}/EFI/Linux/${UKI_NAME}" ]; then
    TARGET="${MNT}/EFI/Linux/${UKI_NAME}"
elif compgen -G "${MNT}/ostree/poky-*/vmlinuz-*" >/dev/null; then
    TARGET=$(ls ${MNT}/ostree/poky-*/vmlinuz-* | head -1)
fi
if [ -z "${TARGET}" ]; then
    echo "[ERROR] efi.bin 中未找到 UKI 目标路径"
    ${SUDO} umount "${MNT}"
    exit 1
fi

echo "[simple-h1] 替换: ${TARGET}"
${SUDO} cp "${UKI}" "${TARGET}"
${SUDO} sync
${SUDO} umount "${MNT}"
rmdir "${MNT}"

echo ""
echo "[simple-h1] efi.bin 打包完成 ✓"
echo "  输出: ${EFI_IMG}"
