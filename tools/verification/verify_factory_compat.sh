#!/bin/bash
#
# verify_factory_compat.sh —— 校验【本次构建的 system.img】里的模块与
#                            【出厂基线】是否 CRC 一致
#
# 回答的问题：我把新 boot.img + system.img 烧上去，会不会出现
#   "disagrees about version of symbol" / 模块加载失败？
#
# 原理（与 modprobe 加载时的判定一致）：
#   模块的 __versions 段存着它依赖的每个符号 + 编译时的 CRC；
#   逐项比对两个版本模块的 CRC 表，任何一项不同就意味着不能混用。
#
# 用法：
#   ./tools/verification/verify_factory_compat.sh              # 新 out-system/system.img vs prebuilds/system.img
#   ./tools/verification/verify_factory_compat.sh <新镜像> <基线镜像>
#
# 退出码：0 = CRC 全一致；1 = 有差异或出错
#
# 注意：会临时展开两个 8GiB raw（顺序复用同一文件），需要几 GB 空间。
#
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$ROOT"

# 档位（8 个：<SoC>-<rootfs>[-perf]）：基线镜像按平台取，见 config/platforms.sh
. "$ROOT/config/platforms.sh"
dt_platform_ensure || { echo "ERROR: 档位未定（见 config/platforms.sh）" >&2; exit 1; }

NEW=${1:-$ROOT/out-system/system.img}
FAC=${2:-$ROOT/$DT_SYSIMG}

[ -f "$NEW" ] || { echo "ERROR: 找不到新镜像 $NEW" >&2; exit 1; }
[ -f "$FAC" ] || { echo "ERROR: 找不到基线镜像 $FAC" >&2; exit 1; }
KREL=$(dt_krel_get || true)
[ -n "$KREL" ] || { echo "ERROR: 既没有 $DT_KREL_FILE，也无法从 $DT_RD_BASE 派生（先跑一次 buildenv）" >&2; exit 1; }

# 临时区：优先大容量盘，否则用仓库 .tmp
if [ -d /mnt/hdd8000g ] && [ -w /mnt/hdd8000g ]; then
	W=/mnt/hdd8000g/.verify_factory_compat
else
	W=$ROOT/.tmp/verify_factory_compat
fi
rm -rf "$W"
mkdir -p "$W"
trap 'rm -rf "$W"' EXIT

# 模块可能出现的 4 个位置（与 build_system.sh 的 COLLECT_SPECS 一致）
MODPATHS="/lib/modules/$KREL /lib/modules/$KREL/extra /lib/modules/$KREL/kernel/drivers/net/usb /opt/quectel"

extract_from() {   # $1=sparse镜像 $2=输出目录
	local img=$1 out=$2 d
	echo "  展开 $(basename "$img") ..."
	simg2img "$img" "$W/tmp.raw" || return 1
	mkdir -p "$out"
	for d in $MODPATHS; do
		debugfs -R "rdump $d $out" "$W/tmp.raw" >/dev/null 2>&1
	done
	rm -f "$W/tmp.raw"
	echo "    抽出 $(find "$out" -name '*.ko' | wc -l) 个 .ko"
}

echo "=== 1/4 从新构建镜像抽模块 ==="
extract_from "$NEW" "$W/new" || exit 1

echo
echo "=== 2/4 从出厂基线抽模块 ==="
extract_from "$FAC" "$W/factory" || exit 1

echo
echo "=== 3/4 模块集合差异 ==="
(cd "$W/new" && find . -name '*.ko' | sort) > "$W/list_new.txt"
(cd "$W/factory" && find . -name '*.ko' | sort) > "$W/list_fac.txt"
echo "  新构建: $(wc -l < "$W/list_new.txt") 个"
echo "  出厂  : $(wc -l < "$W/list_fac.txt") 个"
echo '  --- 仅新构建有（新增/升级）---'
comm -23 "$W/list_new.txt" "$W/list_fac.txt" | sed 's/^/    + /'
echo '  --- 仅出厂有（本次未产出，保持出厂版本）---'
comm -13 "$W/list_new.txt" "$W/list_fac.txt" | sed 's/^/    - /'

echo
echo "=== 4/4 共有模块的符号 CRC 对比 ==="
comm -12 "$W/list_new.txt" "$W/list_fac.txt" > "$W/common.txt"
ok=0 diff=0 err=0
: > "$W/crc_diff.txt"
while read -r m; do
	a=$(modprobe --dump-modversions "$W/new/$m" 2>/dev/null | sort)
	b=$(modprobe --dump-modversions "$W/factory/$m" 2>/dev/null | sort)
	if [ -z "$a" ] || [ -z "$b" ]; then err=$((err + 1)); continue; fi
	if [ "$a" = "$b" ]; then ok=$((ok + 1)); else
		diff=$((diff + 1))
		echo "$m" >> "$W/crc_diff.txt"
	fi
done < "$W/common.txt"

printf '  共有模块        : %s 个\n' "$(wc -l < "$W/common.txt")"
printf '  ✅ CRC 完全一致 : %s 个\n' "$ok"
printf '  ❌ CRC 有差异   : %s 个\n' "$diff"
printf '  ⚠  无法读取     : %s 个\n' "$err"
if [ "$diff" -gt 0 ]; then
	echo '  差异清单（前 20）:'
	head -20 "$W/crc_diff.txt" | sed 's/^/    /'
fi

echo
if [ "$diff" = 0 ]; then
	echo "  ===> ✅ 新模块与出厂模块 CRC 完全一致，可与出厂内核/模块混用"
	exit 0
fi
echo "  ===> ❌ 有 $diff 个模块 CRC 不同 —— boot.img 与 system.img 必须成对烧写"
exit 1
