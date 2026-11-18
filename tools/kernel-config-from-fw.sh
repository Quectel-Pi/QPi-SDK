#!/bin/bash

set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
EXTRACT_IKCONFIG="$ROOT/kernel/msm-kernel/scripts/extract-ikconfig"

die() {
	echo "ERROR: $*" >&2
	exit 1
}

[ "$#" -eq 5 ] || die "用法: $0 prepare|check <fw目录> <config路径> <normal|perf> <platform>"

MODE=$1
FW=$2
CONFIG=$3
PROFILE=$4
PLATFORM=$5
META=${CONFIG}.meta

case "$MODE" in prepare | check) ;; *) die "未知操作: $MODE" ;; esac
case "$PROFILE" in normal | perf) ;; *) die "未知 profile: $PROFILE" ;; esac

FW=$(cd "$FW" 2>/dev/null && pwd) || die "固件目录不存在: $FW"
[ -f "$FW/rawprogram_unsparse0.xml" ] || die "找不到 $FW/rawprogram_unsparse0.xml"

locate_boot() {
	python3 - "$FW/rawprogram_unsparse0.xml" "$FW" <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

xml_path, fw_dir = sys.argv[1:]

def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)

try:
    root = ET.parse(xml_path).getroot()
except (ET.ParseError, OSError) as exc:
    fail(f"无法解析 {xml_path}: {exc}")

images = {"boot_a": [], "boot_b": []}
for elem in root.iter():
    if elem.tag.rsplit("}", 1)[-1] != "program":
        continue
    label = elem.get("label")
    if label in images:
        filename = (elem.get("filename") or "").strip()
        if not filename:
            fail(f"{label} 的 filename 为空")
        images[label].append(filename)

if not images["boot_a"]:
    fail("rawprogram_unsparse0.xml 中没有 boot_a")
for label, filenames in images.items():
    if len(set(filenames)) > 1:
        fail(f"{label} 存在多个冲突 filename: {filenames}")

relative = images["boot_a"][0]
if images["boot_b"] and images["boot_b"][0] != relative:
    fail(f"boot_a/boot_b filename 冲突: {relative} / {images['boot_b'][0]}")

fw_real = os.path.realpath(fw_dir)
boot_real = os.path.realpath(os.path.join(fw_real, relative))
try:
    inside = os.path.commonpath((fw_real, boot_real)) == fw_real
except ValueError:
    inside = False
if not inside:
    fail(f"boot filename 路径越界: {relative}")
if not os.path.isfile(boot_real):
    fail(f"boot image 不存在或不是普通文件: {boot_real}")

print(os.path.relpath(boot_real, fw_real))
PY
}

BOOT_RELATIVE_PATH=$(locate_boot) || exit 1
BOOT=$FW/$BOOT_RELATIVE_PATH
BOOT_SHA256=$(sha256sum "$BOOT" | awk '{print $1}')
FW_NAME=${FW##*/}

validate_config() {
	local file=$1 localversion
	[ -s "$file" ] || die "Kernel config 为空: $file"
	grep -qx 'CONFIG_IKCONFIG=y' "$file" || die "Kernel config 缺少 CONFIG_IKCONFIG=y: $file"
	grep -qx 'CONFIG_ARM64=y' "$file" || die "Kernel config 缺少 CONFIG_ARM64=y: $file"
	localversion=$(sed -n 's/^CONFIG_LOCALVERSION=//p' "$file")
	case "$PROFILE:$localversion" in
	normal:'"-gki-consolidate"' | perf:'""') ;;
	*) die "Kernel config 与 $PROFILE profile 不匹配: CONFIG_LOCALVERSION=${localversion:-<缺失>}" ;;
	esac
}

read_metadata() {
	local metadata=${1:-$META} line key value
	SCHEMA_VERSION= BASELINE_SOURCE_META= PROFILE_META= PLATFORM_META= FW_NAME_META=
	BOOT_RELATIVE_PATH_META= BOOT_SHA256_META= FACTORY_CONFIG_SHA256=
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in *=*) key=${line%%=*}; value=${line#*=} ;; *) die "metadata 格式错误: $line" ;; esac
		case "$key" in
		SCHEMA_VERSION) SCHEMA_VERSION=$value ;;
		BASELINE_SOURCE) BASELINE_SOURCE_META=$value ;;
		PROFILE) PROFILE_META=$value ;;
		PLATFORM) PLATFORM_META=$value ;;
		FW_NAME) FW_NAME_META=$value ;;
		BOOT_RELATIVE_PATH) BOOT_RELATIVE_PATH_META=$value ;;
		BOOT_SHA256) BOOT_SHA256_META=$value ;;
		FACTORY_CONFIG_SHA256) FACTORY_CONFIG_SHA256=$value ;;
		*) die "metadata 含未知字段: $key" ;;
		esac
	done < "$metadata"
	[ "$SCHEMA_VERSION" = 1 ] || die "metadata SCHEMA_VERSION 不支持: ${SCHEMA_VERSION:-<缺失>}"
	[ "$BASELINE_SOURCE_META" = factory ] || die "metadata BASELINE_SOURCE 不支持: ${BASELINE_SOURCE_META:-<缺失>}"
	[ -n "$FACTORY_CONFIG_SHA256" ] || die "metadata 缺少 FACTORY_CONFIG_SHA256"
}

path_exists() {
	[ -e "$1" ] || [ -L "$1" ]
}

check_existing_work_configs() {
	local config_dir normal_config perf_config candidate candidate_meta
	local config_exists meta_exists
	config_dir=$(dirname "$CONFIG")
	normal_config=$config_dir/kernel.config
	perf_config=$config_dir/kernel.perf.config

	for candidate in "$normal_config" "$perf_config"; do
		candidate_meta=${candidate}.meta
		config_exists=0
		meta_exists=0
		path_exists "$candidate" && config_exists=1
		path_exists "$candidate_meta" && meta_exists=1
		[ "$config_exists" = "$meta_exists" ] ||
			die "Kernel config 状态不完整（config/meta 必须同时存在或同时不存在）: $candidate / $candidate_meta"
		[ "$config_exists" = 1 ] || continue

		read_metadata "$candidate_meta"
		if [ "$PROFILE_META" != "$PROFILE" ] ||
			[ "$PLATFORM_META" != "$PLATFORM" ] ||
			[ "$FW_NAME_META" != "$FW_NAME" ] ||
			[ "$BOOT_RELATIVE_PATH_META" != "$BOOT_RELATIVE_PATH" ] ||
			[ "$BOOT_SHA256_META" != "$BOOT_SHA256" ]; then
			die "发现属于其他固件/profile 的 Kernel 工作配置: ${candidate#$ROOT/} (metadata: profile=$PROFILE_META platform=$PLATFORM_META fw=$FW_NAME_META boot_sha256=$BOOT_SHA256_META; current: profile=$PROFILE platform=$PLATFORM fw=$FW_NAME boot_sha256=$BOOT_SHA256)"
		fi
	done
}

check_identity() {
	validate_config "$CONFIG"
	read_metadata "$META"
	[ "$PROFILE_META" = "$PROFILE" ] || die "Kernel config profile 不匹配: metadata=$PROFILE_META current=$PROFILE"
	[ "$PLATFORM_META" = "$PLATFORM" ] || die "Kernel config platform 不匹配: metadata=$PLATFORM_META current=$PLATFORM"
	[ "$FW_NAME_META" = "$FW_NAME" ] || die "Kernel config 固件不匹配: metadata=$FW_NAME_META current=$FW_NAME"
	[ "$BOOT_RELATIVE_PATH_META" = "$BOOT_RELATIVE_PATH" ] || die "Kernel config boot 路径不匹配: metadata=$BOOT_RELATIVE_PATH_META current=$BOOT_RELATIVE_PATH"
	[ "$BOOT_SHA256_META" = "$BOOT_SHA256" ] || die "Kernel config boot SHA256 不匹配: metadata=$BOOT_SHA256_META current=$BOOT_SHA256"
	echo "  Kernel config 身份匹配，保留现有工作配置: ${CONFIG#$ROOT/}"
}

check_existing_work_configs

config_exists=0
meta_exists=0
path_exists "$CONFIG" && config_exists=1
path_exists "$META" && meta_exists=1

if [ "$config_exists" = 1 ] && [ "$meta_exists" = 1 ]; then
	check_identity
	exit 0
fi

if [ "$config_exists" != "$meta_exists" ]; then
	die "Kernel config 状态不完整（config/meta 必须同时存在或同时不存在）: $CONFIG / $META"
fi

[ "$MODE" = prepare ] || die "缺少 Kernel config 及 metadata；请执行 buildenv 初始化"
[ -x "$EXTRACT_IKCONFIG" ] || die "找不到可执行的 $EXTRACT_IKCONFIG"

mkdir -p "$(dirname "$CONFIG")"
config_tmp=$(mktemp "$(dirname "$CONFIG")/.$(basename "$CONFIG").tmp.XXXXXX")
meta_tmp=$(mktemp "$(dirname "$META")/.$(basename "$META").tmp.XXXXXX")
trap 'rm -f "$config_tmp" "$meta_tmp"' EXIT HUP INT TERM

"$EXTRACT_IKCONFIG" "$BOOT" > "$config_tmp" 2>/dev/null || die "从 $BOOT 提取 IKCONFIG 失败"
validate_config "$config_tmp"
FACTORY_CONFIG_SHA256=$(sha256sum "$config_tmp" | awk '{print $1}')
cat > "$meta_tmp" <<EOF
SCHEMA_VERSION=1
BASELINE_SOURCE=factory
PROFILE=$PROFILE
PLATFORM=$PLATFORM
FW_NAME=$FW_NAME
BOOT_RELATIVE_PATH=$BOOT_RELATIVE_PATH
BOOT_SHA256=$BOOT_SHA256
FACTORY_CONFIG_SHA256=$FACTORY_CONFIG_SHA256
EOF
chmod 0644 "$config_tmp" "$meta_tmp"

[ ! -e "$CONFIG" ] && [ ! -L "$CONFIG" ] || die "$CONFIG 已出现，拒绝覆盖"
[ ! -e "$META" ] && [ ! -L "$META" ] || die "$META 已出现，拒绝覆盖"
mv "$config_tmp" "$CONFIG"
mv "$meta_tmp" "$META"
trap - EXIT HUP INT TERM

echo "  已从当前 fw 初始化 Kernel config: ${CONFIG#$ROOT/}"
echo "  factory config SHA256: $FACTORY_CONFIG_SHA256"
