#!/bin/bash
#
# fw_locate.sh —— 定位固件包目录（被 build_system.sh / tools/compat/one_key_rebuild_kernel.sh source）
#
# 约定：将对应固件目录放入 <SDK_ROOT>/fw/
#
# SDK 同时支持 M1 / L1，对应固件包可以并存，具体选择由 $DT_FW_PATTERN 控制。
# （QSM200U* / QSM200E*）过滤。只放一份时行为与以前完全一样（必须唯一）。
#
# 查找优先级：
#   1) $DT_FW_DIR 环境变量
#   2) config/fw_dir.txt（一行，可写相对路径，注释用 #）
#   3) $ROOT/fw/*/  —— 必须恰好 1 份（多份直接报错，避免选错固件）
#
# 依赖调用方已定义 $ROOT。提供两个函数：
#   fw_locate    -> stdout 输出 fw 目录绝对路径；失败返回 1 并把原因写 stderr
#   fw_require   -> 同上，但失败时直接 exit 1（给脚本开头用）
#

# $ROOT 兜底：正常调用方（build_system.sh / one_key_...）都会先设 ROOT，
# 但若没设（例如手工 `source fw_locate.sh` 试一试），路径会退化成
# "/fw/" "/config/..." 这种根目录路径，报错信息极具迷惑性（实测踩过）。
# 用本文件所在目录兜底 —— 它就在仓库根。
if [ -z "${ROOT:-}" ]; then
	ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
fi

# 一个目录要算合格的固件包，必须能"还原出 system.img"：
#   rawprogram_unsparse0.xml  分片位置表
#   gpt_main0.bin             (可选) 分区起点
#   partition.xml             (可选) 备用分区大小
fw_is_valid() {
	[ -d "$1" ] && [ -f "$1/rawprogram_unsparse0.xml" ]
}

# 所有候选：$ROOT/fw/<任意>/ 里面合格的
fw_candidates() {
	local f
	for f in "$ROOT"/fw/*/; do
		[ -d "$f" ] || continue
		fw_is_valid "${f%/}" && echo "${f%/}"
	done
}

# 有档位 glob（$DT_FW_PATTERN）时只留该档位的固件包。
# 没设时原样返回（保持「必须恰好一份」的旧行为）。
#
# $DT_FW_EXCLUDE 是【必须不匹配】的 glob —— 非 perf 档靠它排掉 _perf* 包，
# 否则 QSM200E*BD01* 会把同目录下的 DEB_PERF 包也一起匹配上（两份 → 报歧义）。
fw_filter_platform() {
	local f b
	if [ -z "${DT_FW_PATTERN:-}" ]; then
		printf '%s\n' "$@"
		return 0
	fi
	for f in "$@"; do
		b=$(basename "$f")
		case "$b" in
		${DT_FW_PATTERN}) ;;
		*) continue ;;
		esac
		if [ -n "${DT_FW_EXCLUDE:-}" ]; then
			case "$b" in
			${DT_FW_EXCLUDE}) continue ;;
			esac
		fi
		printf '%s\n' "$f"
	done
}

# 档位一致性提醒：固件包名里带 BD01/BL01（rootfs 轴）与 _perf（perf 轴），
# 若与当前档位的包名模式对不上，说明基线配错了档位 ——
# 那会导致 system.img / ramdisk / Image / kernel.release 全部错位。
# 只告警不拦截：DT_FW_DIR 与 config/fw_dir.txt 都是【显式】指定，目录名也可能
# 被人改过；但必须让人看见，不能静默（实测这类错配最难查）。
fw_warn_arch_mismatch() {
	local b
	[ -n "${DT_FW_PATTERN:-}" ] || return 0
	b=$(basename "$1")
	[ -n "$(fw_filter_platform "$b")" ] && return 0
	{
		echo "WARN: 固件包 '$b' 与当前档位 ${DT_PLATFORM_EFF:-?} 的包名模式不匹配。"
		echo "      期望: ${DT_FW_PATTERN}${DT_FW_EXCLUDE:+  （排除 ${DT_FW_EXCLUDE}）}"
		echo "      若确实要用它，说明档位认错了 —— 检查 ./fw/ 里是不是还放着别的包。"
	} >&2
}

fw_locate() {
	local f line

	# 1) 显式指定
	if [ -n "${DT_FW_DIR:-}" ]; then
		if fw_is_valid "$DT_FW_DIR"; then
			fw_warn_arch_mismatch "$DT_FW_DIR"
			echo "$DT_FW_DIR"
			return 0
		fi
		echo "ERROR: DT_FW_DIR=$DT_FW_DIR 里没有 rawprogram_unsparse0.xml（不是有效的固件包）" >&2
		return 1
	fi

	# 2) config/fw_dir.txt
	for f in "$ROOT/config/fw_dir.txt" "$ROOT/../fw_dir.txt"; do
		[ -f "$f" ] || continue
		line=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' "$f" | head -1)
		[ -n "$line" ] || continue
		case "$line" in
		/*) ;;
		*) line="$ROOT/$line" ;;
		esac
		if fw_is_valid "$line"; then
			fw_warn_arch_mismatch "$line"
			echo "$line"
			return 0
		fi
		echo "WARN: $f 里指定的 $line 不是有效的固件包（缺 rawprogram_unsparse0.xml），忽略" >&2
	done

	# 3) $ROOT/fw/ —— 先按平台过滤，再要求恰好一份
	local -a all=() cand=()
	while IFS= read -r f; do
		[ -n "$f" ] && all+=("$f")
	done < <(fw_candidates)

	if [ -n "${DT_FW_PATTERN:-}" ]; then
		while IFS= read -r f; do
			[ -n "$f" ] && cand+=("$f")
		done < <(fw_filter_platform "${all[@]}")
		if [ "${#cand[@]}" -eq 0 ] && [ "${#all[@]}" -gt 0 ]; then
			{
				echo "ERROR: $ROOT/fw/ 下没有 ${DT_FW_PATTERN} 的固件包（当前档位需要它）。"
				echo "       现有 ${#all[@]} 份："
				printf '         %s\n' "${all[@]}"
				echo "       解决办法（本项目约定 ./fw/ 只放一份）："
				echo "         1) 把 ${DT_FW_PATTERN} 的包放进 ./fw/（换档位就是换包）"
				echo "         2) DT_FW_DIR=/path/to/QSM...   只对本次生效"
				} >&2
			return 1
		fi
	else
		cand=("${all[@]}")
	fi

	if [ "${#cand[@]}" -eq 1 ]; then
		echo "${cand[0]}"
		return 0
	fi

	if [ "${#cand[@]}" -eq 0 ]; then
		{
			echo "ERROR: $ROOT/fw/ 下没有固件包。"
			echo "       请把固件包放进来："
			echo "         mkdir -p $ROOT/fw"
			echo "         cp -a <固件包目录> $ROOT/fw/"
			echo "       目录名形如 QSM200UPEMPIRL1A01_..._V01（200u）"
			echo "               或 QSM200EPNAPIRL1A01_..._V01（200e），"
			echo "       里面应含 rawprogram_unsparse0.xml、system_1..N.img 等。"
		} >&2
		return 1
	fi

	{
		echo "ERROR: $ROOT/fw/ 下有 ${#cand[@]} 份同平台的固件包，只允许 1 份（否则不知道用哪个）："
		printf '         %s\n' "${cand[@]}"
		echo "       请保留当前那台设备对应的那一份，删掉其余的。"
	} >&2
	return 1
}

fw_require() {
	local d
	if ! d=$(fw_locate); then
		exit 1
	fi
	echo "$d"
}
