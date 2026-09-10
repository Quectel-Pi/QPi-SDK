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

# ---------------------------------------------------------------------------
# 平台检测:
#   Linux / WSL  -> qdl (本脚本后续逻辑, 依赖 libusb + udev)
#   Windows      -> QFIL 后端 (fh_loader + QSaharaServer), 走 scripts/flash.bat
#   macOS        -> 不支持 (无 udev / 无 Linux ELF 执行能力)
# ---------------------------------------------------------------------------
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        echo "[simple-h1] 检测到 Windows 环境, 切换为 QFIL 后端烧录"
        BAT="$(pwd)/scripts/flash.bat"
        [ -f "${BAT}" ] || { echo "[ERROR] 找不到 Windows 烧录脚本: ${BAT}"; exit 1; }
        [ -d "$(pwd)/tools/qfil" ] || { echo "[ERROR] 缺少 QFIL 后端目录: $(pwd)/tools/qfil"; exit 1; }
        if command -v cmd.exe >/dev/null 2>&1; then
            if command -v cygpath >/dev/null 2>&1; then
                exec env MSYS_NO_PATHCONV=1 cmd.exe /c "$(cygpath -w "${BAT}")" "$@"
            fi
            exec env MSYS_NO_PATHCONV=1 cmd.exe /c "scripts\\flash.bat" "$@"
        fi
        echo "[ERROR] 无法调用 cmd.exe, 请手动运行:"
        echo "        ${BAT} ${*:-ufs}"
        exit 1
        ;;
    Darwin)
        echo "[ERROR] macOS 不支持本 SDK 烧录 (需 udev/libusb, 且 tools/qdl 为 Linux ELF)"
        echo "        请在 Linux 或 WSL2 内运行, 或使用 Windows 下的 scripts/flash.bat"
        exit 1
        ;;
esac

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
echo "  qdl 已发送复位命令, 设备将启动新固件"
echo "  (如需跳过复位, 加 -R: qdl 的 --skip-reset)"
