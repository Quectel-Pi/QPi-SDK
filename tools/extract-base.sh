#!/usr/bin/env bash
# ============================================================================
# 从 update.img 解出底包到 base_image/
#   用于: 新版本固件发布时, 生成对应的内核 SDK 底包
# 用法:
#   ./extract-base.sh <update.img> [输出目录]
# 示例:
#   ./tools/extract-base.sh /path/to/update.img
# ============================================================================
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/.." && pwd)"
BASE_IMAGE_DIR="${2:-$ROOT_DIR/prebuilds/base_image}"
PACK_TOOL_DIR="$TOOLS_DIR/pack_tools"
UPDATE_IMG="${1:-}"

if [ -z "$UPDATE_IMG" ] || [ ! -f "$UPDATE_IMG" ]; then
    echo "用法: $0 <update.img路径> [输出目录]"
    exit 1
fi
if [ ! -x "$PACK_TOOL_DIR/rkImageMaker" ] || [ ! -x "$PACK_TOOL_DIR/afptool" ]; then
    echo "缺少打包工具: $PACK_TOOL_DIR/rkImageMaker / afptool"
    exit 1
fi

mkdir -p "$ROOT_DIR/build"
WORK_DIR="$(mktemp -d "$ROOT_DIR/build/.unpack.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "[1/3] rkImageMaker 解外层头..."
"$PACK_TOOL_DIR/rkImageMaker" -unpack "$UPDATE_IMG" "$WORK_DIR"

echo "[2/3] afptool 解分区..."
"$PACK_TOOL_DIR/afptool" -unpack "$WORK_DIR/firmware.img" "$WORK_DIR"

echo "[3/3] 拷贝到 $BASE_IMAGE_DIR ..."
mkdir -p "$BASE_IMAGE_DIR"
for f in package-file parameter.txt MiniLoaderAll.bin uboot.img misc.img \
         boot.img recovery.img rootfs.img oem.img userdata.img; do
    if [ -f "$WORK_DIR/$f" ]; then
        cp -f "$WORK_DIR/$f" "$BASE_IMAGE_DIR/"
        echo "  + $f ($(du -h "$WORK_DIR/$f" | cut -f1))"
    fi
done

echo
echo "底包已生成: $BASE_IMAGE_DIR"
echo "注意: rootfs.img 约 6GB, 已按 .gitignore 排除, 不入 git 仓库"
