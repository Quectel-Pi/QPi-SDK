#!/bin/bash
# ============================================================
# simple-h1 一键烧录脚本 (UFS)
# 功能: 检测设备 -> 进入 EDL (9008) -> qdl 烧录
# 用法: ./scripts/flash.sh [ufs|emmc]
#   默认 ufs。烧录前请确认 build/output/ 已生成完整固件
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

FS_TYPE="${1:-ufs}"
FW_DIR="${OUT_DIR}"
QDL="${TOOLS_DIR}/qdl"
ADB="${TOOLS_DIR}/adb"

# 固件完整性检查
for f in prog_firehose_Qcm6490_ddr.elf efi.bin system.img dtb.bin; do
    [ -f "${FW_DIR}/${f}" ] || { echo "[ERROR] 固件缺少 ${f}, 请先运行 ./scripts/build-all.sh"; exit 1; }
done
[ -d "${FW_DIR}/partition_${FS_TYPE}" ] || { echo "[ERROR] 缺少 partition_${FS_TYPE} 目录"; exit 1; }

echo "=========================================="
echo "[simple-h1] 烧录固件 (${FS_TYPE})"
echo "  固件目录: ${FW_DIR}"
echo "=========================================="

# 1. 检测 ADB 设备
echo "[simple-h1] 检测 ADB 设备..."
if ! "${ADB}" devices 2>/dev/null | grep -q "device$"; then
    echo "[WARN] 未检测到 ADB 设备, 请确认 USB 连接"
fi

# 2. 进入 EDL 模式
echo "[simple-h1] 设备进入 EDL 模式..."
"${ADB}" shell reboot edl 2>/dev/null || true

# 3. 等待 9008 设备
echo "[simple-h1] 等待 9008 EDL 设备..."
for i in $(seq 1 60); do
    if lsusb 2>/dev/null | grep -q "05c6:9008"; then
        echo "[simple-h1] 已进入 EDL 模式 ✓"
        break
    fi
    [ "$i" -eq 60 ] && { echo "[ERROR] 等待 9008 设备超时, 请检查 USB 连接或手动断电重进 EDL"; exit 1; }
    sleep 1
done

# 4. 执行 qdl 烧录
cd "${FW_DIR}"
echo "[simple-h1] qdl 烧录中 (保留 persist 分区)..."
sudo "${QDL}" -s "${FS_TYPE}" -i . \
    "prog_firehose_Qcm6490_ddr.elf" \
    partition_${FS_TYPE}/rawprogram[0-5].xml \
    partition_${FS_TYPE}/patch[0-5].xml

echo ""
echo "[simple-h1] 烧录完成 ✓"
echo "  请断电重新上电启动设备"
