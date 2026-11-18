#!/bin/bash
#
# check_mixable.sh —— 判定「旧模块能否加载到新内核上」
#
# 复刻 modprobe 的判定逻辑：
#   模块的 __versions 段里存着它依赖的每个符号 + 编译时的 CRC；
#   内核的 __kcrctab 段里存着当前内核里每个导出符号的 CRC；
#   两者逐项比对，任何一项不一致就报
#     "disagrees about version of symbol xxx" 并拒绝加载。
#
# 本脚本离线做同一件事：
#   1. 从【新内核】的 Module.symvers 取「符号 -> CRC」表
#   2. 用 `modprobe --dump-modversions` 从【旧模块】取它的依赖表
#   3. 逐项比对
#
# 用法：
#   ./tools/diagnostics/check_mixable.sh <新Module.symvers> <旧模块.ko> [更多.ko ...]
#
# ⚠️ 符号表要覆盖「旧模块依赖的所有 provider」，不能只看内核那一份
#
#   内核自带的 out-kernel/msm-kernel/Module.symvers 只含 **vmlinux 导出**的
#   符号。镜像里还有一批**独立构建**的 vendor DLKM（audio / wlan / usb WWAN /
#   显示栈 …），它们导出的符号（gpr_send_pkt、snd_event_notify、ipa3_* …）
#   只出现在各自的 Module.symvers 里。
#
#   本仓库不做那些 DLKM 的构建，所以脚本会【尽力】合并能找到的汇总表：
#   out-modules/sysroot/lib/modules/<release>/Module.symvers（若存在）。
#   需要额外来源时用环境变量指定：
#       EXTRA_SYMVERS="a.symvers b.symvers" ./tools/diagnostics/check_mixable.sh <新symvers> <旧.ko>
#
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

NEWSV=${1:?用法: $0 <新Module.symvers> <旧模块.ko> [更多.ko ...]}
shift
[ $# -ge 1 ] || { echo "ERROR: 至少给一个 .ko" >&2; exit 1; }
[ -f "$NEWSV" ] || { echo "ERROR: 找不到 $NEWSV" >&2; exit 1; }

# 收集要合并的符号表：主表 + sysroot 汇总表 + 用户指定的额外表
SV_LIST="$NEWSV"
for extra in \
	"$ROOT"/out-modules/sysroot/lib/modules/*/Module.symvers \
	"$(dirname "$NEWSV")"/../../sysroot/lib/modules/*/Module.symvers \
	${EXTRA_SYMVERS:-} ; do
	[ -f "$extra" ] || continue
	case " $SV_LIST " in *" $extra "*) ;; *) SV_LIST="$SV_LIST $extra" ;; esac
done

# 新内核的 CRC 表：符号 -> CRC
# Module.symvers 格式： CRC <TAB> 符号 <TAB> 提供者 <TAB> 导出类型 <TAB>
awk -F'\t' 'NF>=2 {print $2"\t"$1}' $SV_LIST | sort -u > /tmp/.newcrc.txt
echo "符号表: $(wc -l < /tmp/.newcrc.txt) 个唯一导出符号（已合并 $(echo $SV_LIST | wc -w) 份 symvers）"
for f in $SV_LIST; do echo "        + $f"; done

# modprobe 在哪里
MODPROBE=""
for c in modprobe /sbin/modprobe /usr/sbin/modprobe; do
	command -v "$c" >/dev/null 2>&1 && { MODPROBE="$c"; break; }
done
if [ -z "$MODPROBE" ]; then
	echo "ERROR: 找不到 modprobe（需要 kmod；且要支持 --dump-modversions）" >&2
	exit 1
fi

total_ok=0
total_bad=0
bad_files=""

for ko in "$@"; do
	[ -f "$ko" ] || { echo "跳过（不存在）: $ko"; continue; }
	name=$(basename "$ko")
	echo
	echo "────────────────────────────────────────────────────"
	echo " $name"
	echo "────────────────────────────────────────────────────"

	# 取模块的 modversions 表：格式 "<crc> <symbol>"
	table=$($MODPROBE --dump-modversions "$ko" 2>/dev/null) || {
		echo "  ⚠️ 无法读取 modversions（可能没开 CONFIG_MODVERSIONS）"
		continue
	}
	n=$(echo "$table" | grep -c . )
	echo "  依赖符号数: $n"

	ok=0; bad=0
	badlist=""
	while read -r crc sym; do
		[ -n "${crc:-}" ] || continue
		[ -n "${sym:-}" ] || continue
		# 新内核里该符号的 CRC
		newcrc=$(awk -v s="$sym" '$1==s {print $2; exit}' /tmp/.newcrc.txt)
		if [ -z "$newcrc" ]; then
			bad=$((bad + 1))
			badlist="$badlist\n    ? $sym   （新内核里【没有】这个符号）"
		elif [ "$newcrc" != "$crc" ]; then
			bad=$((bad + 1))
			badlist="$badlist\n    ! $sym   CRC $crc -> $newcrc"
		else
			ok=$((ok + 1))
		fi
	done <<< "$table"

	echo "  CRC 一致: $ok"
	echo "  有问题  : $bad"
	[ -n "$badlist" ] && echo -e "$badlist" | head -30

	if [ "$bad" = 0 ]; then
		echo "  ✅ 可以加载到新内核"
		total_ok=$((total_ok + 1))
	else
		echo "  ❌ 加载会被拒绝（disagrees about version of symbol）"
		total_bad=$((total_bad + 1))
		bad_files="$bad_files $name"
	fi
done

echo
echo "======================================================"
echo " 汇总"
echo "======================================================"
echo "  可混用 : $total_ok 个模块"
echo "  不可混用: $total_bad 个模块"
if [ -n "$bad_files" ]; then
	echo "  有问题的:$bad_files"
	echo
	echo "  → 结论：不能混用，必须把 system.img / boot.img 一起重出并同时烧写。"
else
	echo
	echo "  → 结论：所有旧模块的依赖 CRC 都与新内核对得上，可以安全混用。"
	echo "     （只改 .config 加模块、不动已有的结构体/函数原型时，就是这种情况）"
fi
