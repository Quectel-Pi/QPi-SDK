#!/bin/bash
# ============================================================
# simple-h1 全盘烧录脚本 (UFS)
# 功能: 检测 EDL (9008) -> qdl 全 LUN 烧录 (rawprogram0-5 + patch0-5)
# 用法: ./scripts/flash.sh [ufs|emmc]
#   默认 ufs。只做全盘烧录 (所有 LUN 的所有 xml), 不增量/不跳过。
#   设备须已在 EDL 模式 (9008):
#     - 正常运行: adb shell reboot edl
#     - panic/900e: 断电重上电 (按住 EDL 组合键) 进 9008
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

FS_TYPE="${1:-ufs}"
FW_DIR="${OUT_DIR}"
QDL="${TOOLS_DIR}/qdl"
SUDO="${SUDO:-sudo}"

# 固件完整性检查
for f in prog_firehose_Qcm6490_ddr.elf efi.bin system.img dtb.bin; do
    [ -f "${FW_DIR}/${f}" ] || { echo "[ERROR] 固件缺少 ${f}, 请先运行 ./scripts/build-all.sh"; exit 1; }
done
[ -d "${FW_DIR}/partition_${FS_TYPE}" ] || { echo "[ERROR] 缺少 partition_${FS_TYPE} 目录"; exit 1; }

echo "=========================================="
echo "[simple-h1] 全盘烧录固件 (${FS_TYPE})"
echo "  固件目录: ${FW_DIR}"
echo "  模式: 全 LUN 烧录 (rawprogram0-5 + patch0-5)"
echo "=========================================="

# 1. 等待 EDL (9008) 设备 (最多 60s, 供用户手动进 EDL)
echo "[simple-h1] 等待 9008 EDL 设备 (若未进 EDL: 断电重上电按住组合键)..."
in_edl=0
for i in $(seq 1 60); do
    if lsusb 2>/dev/null | grep -q "05c6:9008"; then
        echo "[simple-h1] 已检测到 9008 EDL 设备 ✓"
        in_edl=1
        break
    fi
    [ "$i" -eq 60 ] && { echo "[ERROR] 等待 9008 超时 (60s)。请确认设备已进 EDL。"; exit 1; }
    sleep 1
done

# 2. 全盘烧录 (所有 LUN 的 rawprogram + patch)
cd "${FW_DIR}"
echo "[simple-h1] qdl 全盘烧录中..."
# 显式列出 0-5 全部 LUN (保证顺序, 不依赖 glob 顺序)
XMLS=()
for lun in 0 1 2 3 4 5; do
    XMLS+=(partition_${FS_TYPE}/rawprogram${lun}.xml partition_${FS_TYPE}/patch${lun}.xml)
done
${SUDO} "${QDL}" -s "${FS_TYPE}" -i . \
    "prog_firehose_Qcm6490_ddr.elf" \
    "${XMLS[@]}"

echo ""
echo "[simple-h1] 全盘烧录完成 ✓"
echo "  请断电重新上电启动设备"
