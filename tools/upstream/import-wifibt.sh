#!/usr/bin/env bash
# 导入与 SDK 内核基准相同提交的官方 M2 SDIO 驱动/固件，不拷上游工作区产物。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${UPSTREAM_SRC:-/home/q/work/linux/RK3576_Linux6.1_BL01_v1.2.0}"
REF="${1:-$(sed -n 's/^commit=//p' "$ROOT/tools/upstream/base.txt")}"
TARGET="$(git -C "$SRC" rev-parse --verify "$REF^{commit}")"
DEST="$ROOT/external/rkwifibt"
[[ ! -e "$DEST" ]] || { echo "拒绝覆盖已有无线源码，请先备份并审核差异: $DEST" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git -C "$SRC" archive "$TARGET" \
    external/rkwifibt/drivers/aic8800_sdio \
    external/rkwifibt/firmware/aic/sdio | tar -xf - -C "$TMP"
[[ -f "$TMP/external/rkwifibt/drivers/aic8800_sdio/Makefile" ]]
mkdir -p "$ROOT/external"
mv "$TMP/external/rkwifibt" "$DEST"
echo "已导入官方 M2 SDIO 驱动及固件: $TARGET"
echo "请核对 tools/upstream/wifibt.txt 中的固定来源，再编译验证；不自动提交。"