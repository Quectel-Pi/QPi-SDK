#!/usr/bin/env bash
# ============================================================================
# fetch-base-image.sh - 一键下载 M2 编译资源包并生成 sysroot
# ============================================================================
# 背景: prebuilds/base_image 对应 Quectel 官方发布的"Quectel_Pi_M2编译资源包"
#       (zip, 内含 rootfs.img / update.img / parameter.txt 等)。
#       prebuilds/sysroot 则是从 base_image/rootfs.img 解出的应用编译 sysroot。
#
# 本脚本整套流程 (全部发生在 prebuilds/ 目录下):
#   1. 下载 Quectel_Pi_M2编译资源包.zip
#   2. 解压并整理为 prebuilds/base_image/
#   3. 调用 tools/extract-sysroot.sh 从 rootfs.img 生成 prebuilds/sysroot/
#
# 用法:
#   ./tools/fetch-base-image.sh                        # 使用默认官方下载地址
#   ./tools/fetch-base-image.sh -u <zip下载地址>       # 自定义 zip 地址
#   ./tools/fetch-base-image.sh --no-sysroot           # 只下载解压, 不生成 sysroot
#   ./tools/fetch-base-image.sh --keep-zip             # 保留下载的 zip (默认解压后删除)
#   FORCE=1 ./tools/fetch-base-image.sh                # base_image/sysroot 已存在时自动备份
#
# 依赖: curl (或 wget), unzip (或 7z); sysroot 阶段还需 e2fsprogs(debugfs)
# ============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREBUILTS_DIR="$ROOT_DIR/prebuilds"
BASE_IMAGE_DIR="$PREBUILTS_DIR/base_image"

DEFAULT_URL="https://developer.quectel.com/doc/files/Quectel_Pi_M2%E7%BC%96%E8%AF%91%E8%B5%84%E6%BA%90%E5%8C%85.zip"
URL="$DEFAULT_URL"
DO_SYSROOT=1
KEEP_ZIP=0
FORCE="${FORCE:-0}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,/^$/p' | sed 's/^#/ /'
    exit "${1:-0}"
}

# --- 参数解析 ---------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        -u|--url)      URL="$2"; shift 2 ;;
        --no-sysroot)  DO_SYSROOT=0; shift ;;
        --keep-zip)    KEEP_ZIP=1; shift ;;
        -f|--force)    FORCE=1; shift ;;
        -h|--help)     usage 0 ;;
        *) echo "未知参数: $1"; usage 1 ;;
    esac
done

ZIP_NAME="$(basename "$URL")"
[ -n "$ZIP_NAME" ] || ZIP_NAME="Quectel_Pi_M2编译资源包.zip"
ZIP_FILE="$PREBUILTS_DIR/$ZIP_NAME"

# --- 前置检查 ---------------------------------------------------------------
LOCAL_SRC=""
case "$URL" in
    file://*)
        LOCAL_SRC="${URL#file://}"
        ;;
    /*)
        LOCAL_SRC="$URL"
        ;;
esac
if [ -n "$LOCAL_SRC" ]; then
    [ -f "$LOCAL_SRC" ] || { log_err "本地文件不存在: $LOCAL_SRC"; exit 1; }
    log_info "使用本地 zip: $LOCAL_SRC"
elif command -v curl >/dev/null 2>&1; then
    DL="curl"
elif command -v wget >/dev/null 2>&1; then
    DL="wget"
else
    log_err "缺少下载工具: 请安装 curl 或 wget"; exit 1
fi
if command -v unzip >/dev/null 2>&1; then
    UNZ="unzip"
elif command -v 7z >/dev/null 2>&1; then
    UNZ="7z"
else
    log_err "缺少解压工具: 请安装 unzip 或 p7zip"; exit 1
fi
if [ "$DO_SYSROOT" = "1" ]; then
    for t in 7z debugfs; do
        command -v "$t" >/dev/null 2>&1 || { log_err "缺少依赖工具: $t (请先安装 p7zip-full 和 e2fsprogs)"; exit 1; }
    done
    [ -x "$ROOT_DIR/tools/extract-sysroot.sh" ] || { log_err "缺少 $ROOT_DIR/tools/extract-sysroot.sh"; exit 1; }
fi
mkdir -p "$PREBUILTS_DIR"

avail_mb=$(df -Pm "$PREBUILTS_DIR" | awk 'NR==2{print $4}')
log_info "下载地址: $URL"
log_info "目标分区可用 ${avail_mb}MB (zip 约 5GB, 解压后约 10GB, 建议 >30GB)"

# --- 1/3: 下载 zip -----------------------------------------------------------
download() {
    local url="$1" out="$2"
    if [ "$DL" = "curl" ]; then
        if [ -f "$out" ] && [ -s "$out" ]; then
            log_info "已存在 $out ($(du -h "$out" | cut -f1)), 尝试断点续传"
            curl -fSL -C - --retry 3 --retry-delay 2 -o "$out" "$url" \
                && return 0
            # -C - 在文件已完整时返回 HTTP 416, curl 会报错; 大小 >0 即视为已完成
            [ -s "$out" ] && return 0
            return 1
        fi
        curl -fSL --retry 3 --retry-delay 2 -o "$out" "$url"
    else
        wget -c -O "$out" "$url"
    fi
}

log_info "[1/3] 下载 $ZIP_NAME ..."
if [ -f "$ZIP_FILE" ] && [ -s "$ZIP_FILE" ]; then
    log_ok "zip 已存在, 跳过下载: $ZIP_FILE ($(du -h "$ZIP_FILE" | cut -f1))"
elif [ -n "$LOCAL_SRC" ]; then
    cp -f "$LOCAL_SRC" "$ZIP_FILE"
    log_ok "已复制本地 zip: $ZIP_FILE ($(du -h "$ZIP_FILE" | cut -f1))"
else
    if ! download "$URL" "$ZIP_FILE"; then
        log_err "下载失败: $URL"
        rm -f "$ZIP_FILE"
        exit 1
    fi
    log_ok "下载完成: $ZIP_FILE ($(du -h "$ZIP_FILE" | cut -f1))"
fi

# --- 2/3: 解压并整理为 base_image/ ------------------------------------------
log_info "[2/3] 解压到 $PREBUILTS_DIR ..."
EXTRACT_DIR="$(mktemp -d "$PREBUILTS_DIR/.extract.XXXXXX")"
trap 'rm -rf "$EXTRACT_DIR"' EXIT

if [ "$UNZ" = "unzip" ]; then
    unzip -q -o "$ZIP_FILE" -d "$EXTRACT_DIR"
else
    7z x -y "$ZIP_FILE" -o"$EXTRACT_DIR" >/dev/null
fi

# zip 内可能有顶层目录 (如 "Quectel_Pi_M2编译资源包/"), 也可能直接是文件。
# 统一以 rootfs.img 所在目录作为内容源。
ROOTFS_IMG="$(find "$EXTRACT_DIR" -maxdepth 3 -type f -name rootfs.img | head -1)"
if [ -z "$ROOTFS_IMG" ]; then
    log_err "解压结果中未找到 rootfs.img, 请确认 zip 内容为 base_image 资源包"
    exit 1
fi
SRC_DIR="$(dirname "$ROOTFS_IMG")"
log_ok "找到 rootfs.img: $SRC_DIR/rootfs.img"

# 处理已存在的 base_image
if [ -d "$BASE_IMAGE_DIR" ] && [ -n "$(ls -A "$BASE_IMAGE_DIR" 2>/dev/null)" ]; then
    if [ "$FORCE" = "1" ]; then
        BAK="${BASE_IMAGE_DIR}.bak.$(date +%Y%m%d%H%M%S)"
        mv "$BASE_IMAGE_DIR" "$BAK"
        log_warn "旧 base_image 已备份到: $BAK"
    else
        log_err "prebuilds/base_image 已存在且非空"
        log_err "请删除/备份后重试, 或设置 FORCE=1 自动备份"
        exit 1
    fi
fi
mkdir -p "$BASE_IMAGE_DIR"

if [ "$SRC_DIR" = "$EXTRACT_DIR" ]; then
    mv "$EXTRACT_DIR"/* "$EXTRACT_DIR"/.[!.]* "$BASE_IMAGE_DIR"/ 2>/dev/null || true
else
    mv "$SRC_DIR"/* "$SRC_DIR"/.[!.]* "$BASE_IMAGE_DIR"/ 2>/dev/null || true
fi
log_ok "base_image 已生成: $BASE_IMAGE_DIR"
ls -lh "$BASE_IMAGE_DIR" | sed 's/^/  /'

if [ "$KEEP_ZIP" != "1" ]; then
    rm -f "$ZIP_FILE"
    log_info "已删除下载的 zip (如需保留请加 --keep-zip)"
else
    log_info "zip 保留在: $ZIP_FILE"
fi
rm -rf "$EXTRACT_DIR"
trap - EXIT

# --- 3/3: 生成 sysroot -------------------------------------------------------
if [ "$DO_SYSROOT" = "1" ]; then
    log_info "[3/3] 调用 extract-sysroot.sh 从 rootfs.img 生成 sysroot ..."
    FORCE="$FORCE" "$ROOT_DIR/tools/extract-sysroot.sh" \
        "$BASE_IMAGE_DIR/rootfs.img" "$PREBUILTS_DIR/sysroot"
else
    log_info "[3/3] 跳过 sysroot 生成 (--no-sysroot)"
fi

echo
log_ok "全部完成:"
echo "  base_image: $BASE_IMAGE_DIR"
echo "  sysroot:    $PREBUILTS_DIR/sysroot ($(du -sh "$PREBUILTS_DIR/sysroot" 2>/dev/null | cut -f1))"
