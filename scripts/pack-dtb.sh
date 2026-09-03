#!/bin/bash
# ============================================================
# simple-h1 dtb.bin 打包脚本
# 功能: 更新 dtb.bin (FAT, 含 combined-dtb.dtb) 中的设备树
# 用法: ./scripts/pack-dtb.sh [dtb路径]
# ============================================================
set -e
cd "$(dirname "$0")/.."
source scripts/env.sh

DTB="${1:-${KERNEL_OUT}/arch/arm64/boot/dts/qcom/${DTB_NAME}}"
SRC_DTB_BIN="${PREBUILDS_DIR}/dtb.bin"
OUT_DTB_BIN="${OUT_DIR}/dtb.bin"
MNT="${BUILD_DIR}/dtb-mnt"

# sudo 支持 (仅 mtools 缺失回退挂载时需要; 默认 mtools 免 root)
SUDO="${SUDO:-sudo}"

[ -f "${SRC_DTB_BIN}" ] || { echo "[ERROR] 原始 dtb.bin 不存在: ${SRC_DTB_BIN}"; exit 1; }
[ -f "${DTB}" ] || { echo "[ERROR] DTB 不存在: ${DTB}"; exit 1; }

echo "=========================================="
echo "[simple-h1] 打包 dtb.bin"
echo "  DTB:   ${DTB}"
echo "  输出:  ${OUT_DTB_BIN}"
echo "=========================================="

# 合并 dtbo (与官方 linux-qcom-mergedtb 一致)
DTBO_DIR="${TOOLS_DIR}/uki/dtbo"
MERGED_DTB="${BUILD_DIR}/combined-dtb.dtb"
rm -f "${MERGED_DTB}"
if [ -f "${DTBO_DIR}/qcm6490-graphics.dtbo" ] && [ -f "${DTBO_DIR}/qcm6490-camera-rb3.dtbo" ] && [ -f "${DTBO_DIR}/qcm6490-video.dtbo" ]; then
    echo "[simple-h1] 合并 dtbo overlay -> combined-dtb.dtb"
    cp "${DTB}" "${MERGED_DTB}"
    fdtoverlay -i "${MERGED_DTB}" -o "${MERGED_DTB}.out" \
        "${DTBO_DIR}/qcm6490-graphics.dtbo" \
        "${DTBO_DIR}/qcm6490-camera-rb3.dtbo" \
        "${DTBO_DIR}/qcm6490-video.dtbo"
    mv "${MERGED_DTB}.out" "${MERGED_DTB}"
else
    cp "${DTB}" "${MERGED_DTB}"
fi

rm -f "${OUT_DTB_BIN}"
cp "${SRC_DTB_BIN}" "${OUT_DTB_BIN}"

# 替换 combined-dtb.dtb (优先 mtools 免 root; 无 mtools 时回退 loop 挂载)
if command -v mcopy >/dev/null 2>&1; then
    echo "[simple-h1] 用 mtools 更新 ${OUT_DTB_BIN} (免 root)..."
    if mdir -i "${OUT_DTB_BIN}" ::/combined-dtb.dtb >/dev/null 2>&1; then
        echo "[simple-h1] 替换 ::/combined-dtb.dtb"
        mcopy -o -i "${OUT_DTB_BIN}" "${MERGED_DTB}" ::/combined-dtb.dtb
    else
        echo "[WARN] 未找到 ::/combined-dtb.dtb, 列出内容:"
        mdir -i "${OUT_DTB_BIN}" ::/ 2>/dev/null | head -20
    fi
else
    echo "[simple-h1] 未找到 mtools, 回退 loop 挂载 (需要 root)"
    mkdir -p "${MNT}"
    ${SUDO} mount -o loop,rw "${OUT_DTB_BIN}" "${MNT}"

    if [ -f "${MNT}/combined-dtb.dtb" ]; then
        echo "[simple-h1] 替换 ${MNT}/combined-dtb.dtb"
        ${SUDO} cp "${MERGED_DTB}" "${MNT}/combined-dtb.dtb"
    else
        echo "[WARN] 未找到 combined-dtb.dtb, 列出内容:"
        ${SUDO} ls -la "${MNT}/"
    fi

    ${SUDO} sync
    ${SUDO} umount "${MNT}"
    rmdir "${MNT}"
fi

echo ""
echo "[simple-h1] dtb.bin 打包完成 ✓"
echo "  输出: ${OUT_DTB_BIN}"
