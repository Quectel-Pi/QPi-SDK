#!/bin/bash
#
# crc_compare.sh —— 对比两次构建的符号 CRC，判定「新旧模块能否混用」
#
# ⚠️ 关于 System.map：它【没有 CRC】，只有「符号名 → 地址」。
#    运行期 modprobe 校验用的是 vmlinux 里 __kcrctab / __kcrctab_gpl / __kcrctab_unused
#    这些段的 CRC 表，跟模块的 __versions 段比对。
#    所以权威做法是【从 vmlinux 抽 CRC 表】，而不是看 System.map。
#
# 本脚本对两份 vmlinux 分别抽 __kcrctab 并比对：
#   - CRC 变了   → 依赖该符号的【旧模块】加载会报
#                  "disagrees about version of symbol"  → 不能混用
#   - 只新增符号 → 安全（旧模块不依赖新符号）
#   - 删除符号   → 依赖它的旧模块报 "Unknown symbol"    → 不能混用
#
# 用法：
#   ./tools/diagnostics/crc_compare.sh <old.vmlinux> <new.vmlinux>
#
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

OLD=${1:?用法: $0 <old.vmlinux> <new.vmlinux>}
NEW=${2:?用法: $0 <old.vmlinux> <new.vmlinux>}

for f in "$OLD" "$NEW"; do
	[ -f "$f" ] || { echo "ERROR: 找不到 $f" >&2; exit 1; }
done

TOOL="${CROSS_OBJDUMP:-}"
if [ -z "$TOOL" ]; then
	for c in llvm-objdump aarch64-linux-gnu-objdump objdump; do
		command -v "$c" >/dev/null && { TOOL=$c; break; }
	done
	for c in "$ROOT"/kernel/prebuilts/clang/host/linux-x86/clang-r450784e/bin/llvm-objdump; do
		[ -x "$c" ] && TOOL=$c
	done
fi
[ -n "$TOOL" ] || { echo "ERROR: 找不到 objdump" >&2; exit 1; }
echo "objdump: $TOOL"

# 抽 CRC 表：__kcrctab 段里存的是 u32 CRC，顺序与 __ksymtab 的符号一一对应。
# 光看 __kcrctab 拿不到「名字」，所以用 vmlinux 的符号表把两者对齐：
#   拿到 __kcrctab / __kcrctab_gpl 的【起止地址】→ 按 4 字节切 → 得到 CRC 数组；
#   再拿 __ksymtab_strings 里按顺序排列的符号名。
# 这个对齐容易出错，更稳的办法是直接用 Module.symvers（它就是 CRC 的来源，
# 且记录了符号名）。所以这里两个都做：
#   (A) Module.symvers —— 符号名 ↔ CRC，最可靠
#   (B) vmlinux __kcrctab —— 段大小/条目数，用于交叉验证 A 的完整性

extract_symvers() {
	local vmlinux=$1 out=$2
	# Module.symvers 与 vmlinux 同目录（dist/）
	local sv; sv=$(dirname "$vmlinux")/Module.symvers
	if [ -f "$sv" ]; then
		# 格式: CRC<TAB>Symbol<TAB>Module<TAB>ExportType
		awk -F'\t' 'NF>=2 {print $2"\t"$1}' "$sv" | sort > "$out"
		echo "  (A) Module.symvers: $(wc -l < "$out") 个符号  <- $sv"
	else
		echo "  (A) Module.symvers: 同目录下没找到" >&2
		: > "$out"
	fi
}

kcrctab_stat() {
	local vmlinux=$1
	echo "  (B) __kcrctab 段大小（交叉验证用）:"
	$TOOL -h "$vmlinux" 2>/dev/null \
		| awk '/__kcrctab/{printf "      %-24s size=0x%s\n",$2,$3}'
}

echo
echo "=== 抽取符号 CRC ==="
echo "旧: $OLD"
extract_symvers "$OLD" /tmp/.crc.old
kcrctab_stat "$OLD"
echo "新: $NEW"
extract_symvers "$NEW" /tmp/.crc.new
kcrctab_stat "$NEW"

[ -s /tmp/.crc.old ] && [ -s /tmp/.crc.new ] || {
	echo
	echo "ERROR: 拿不到 Module.symvers，无法比对（旁边应该有 dist/Module.symvers）" >&2
	exit 1
}

echo
echo "======================================================"
echo " CRC 差异汇总"
echo "======================================================"
added=$(comm -13 /tmp/.crc.old /tmp/.crc.new)
removed=$(comm -23 /tmp/.crc.old /tmp/.crc.new)
changed=$(join -t$'\t' /tmp/.crc.old /tmp/.crc.new | awk -F'\t' '$2!=$3')

printf '  %-28s %6s\n' "新增符号"   "$(echo "$added"   | grep -c . || true)"
printf '  %-28s %6s\n' "删除符号"   "$(echo "$removed" | grep -c . || true)"
printf '  %-28s %6s\n' "CRC 变化的符号" "$(echo "$changed" | grep -c . || true)"

if [ -n "$changed" ]; then
	echo
	echo "  --- CRC 变化的符号（前 30）---"
	echo "$changed" | head -30 | awk -F'\t' '{printf "    ! %-46s %s -> %s\n",$1,$2,$3}'
	echo
	echo "  ❌ 结论：不能混用。依赖这些符号的旧模块会加载失败。必须整包重出。"
else
	echo
	echo "  ✅ 结论：所有已有符号的 CRC 完全未变。"
	echo "     旧模块依赖的符号 CRC 全部对得上 → 可以加载到新内核上。"
	if [ -z "$removed" ]; then
		echo "     且没有删除任何符号。"
	fi
fi

echo
echo "======================================================"
echo " 怎么解读"
echo "======================================================"
cat <<'EOF'
  CONFIG_MODVERSIONS 只哈希【函数/变量的类型签名】，不哈希函数体：
    - 改函数内部实现（不改签名）  -> CRC 不变 -> 旧模块照常加载 ✅
    - 改结构体布局/字段/函数原型  -> CRC 变化 -> 旧模块加载失败 ❌
                                     （明确报 "disagrees about version of
                                       symbol"，是【好事】：报错而非静默错乱）
  所以「混用是否安全」=「CRC 有没有变」，与改了哪些 .c 文件无关。
EOF
