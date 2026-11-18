#!/bin/bash
#
# build_system.sh —— 用新编译的模块替换 system.img 里的 .ko
#
# system.img 是 ext4 镜像（外面套了一层 Android sparse 格式）。本脚本
# 不重建文件系统，只做「就地换文件」：
#
#   simg2img  sparse -> raw (逻辑 8GiB)
#     -> debugfs 逐个 rm + write + 修正属主/权限
#     -> e2fsck 修一致性
#     -> img2simg raw -> sparse
#
# 为什么用 debugfs 而不是 mount：
#   容器里以普通用户(root)运行但没有 sudo，`mount -o loop` 会报
#   "only root can use --options option"。debugfs 直接操作镜像文件，
#   只需要文件写权限，是唯一可行方案。
#
# ── 模块在镜像里的 4 个位置（出厂布局，用于对照排查）───────────────────
#   /lib/modules/<kv>/                         内核自带模块（199）
#   /lib/modules/<kv>/extra/                   vendor: audio 29 + rmnet_core 1
#   /lib/modules/<kv>/kernel/drivers/net/usb/  vendor: GobiNet / qmi_wwan_q
#   /opt/quectel/                              vendor: 显示/GPU 栈（17），在【/ 下】
#                                              由 start_msm_drm.sh 手动 insmod
#   4 个位置互不重叠。
#   ⚠️ 本仓库【只重建内核自带模块】，它们全部落在 /lib/modules/<kv>/ 这一处；
#      其余三处是 vendor 外部模块 —— 其源码与构建逻辑已在瘦身分支里移除，
#      镜像里保持出厂原版不动（所以那三处只会统计到 0 个替换）。
#   另外 /lib/modules/ 根层还有 6 个（msm-rng/qce50/qseecom/...，TZ 相关），
#   不是我们构建的，保持出厂原版。
#
# ── 策略：替换靠【镜像】定位，新增落到 <kv>/ ────────────────────────────
#   1) 扫描镜像，建「basename -> 镜像内路径」映射（出厂布局的唯一权威）
#   2) 收集内核自带模块（stage/second/*.ko），默认目标目录 = /lib/modules/<kv>/
#   3) 逐个处理：
#        basename 命中镜像 -> 替换到【镜像里那个位置】
#                             布局与出厂逐一致，脚本无需硬编码位置规则
#        basename 不在镜像 -> 【新增】到 $MODDIR
#                             ⚠️ 这一步必须有！否则客户新开的 config 编出的
#                             模块会被静默丢掉（踩过：CONFIG_NULL_TTY=m 的
#                             ttynull.ko 明明在 stage/second 里，镜像却一直
#                             是 248 个，而且不报任何错）
#   4) 有新增模块时重建模块索引（depmod），否则 modprobe 找不到它们
#
#   要严格出厂对齐（不新增任何模块）：NO_ADD_NEW=1
#   不重建模块索引：                  NO_DEPMOD=1
#
# 输入：
#   prebuilds/system.img            基准镜像（统一名；从 fw 还原，sparse；
#                                   归属见 prebuilds/baseline.platform）
#   $DT_KREL_FILE
#   stage/second/*.ko              内核自带模块（第二段）
# 输出：
#   out-system/system.img          以及 out-system/.added.txt（新增模块清单）
#
set -e
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# 档位（8 个：<SoC>-<rootfs>[-perf]）—— 一般由 build.sh 的 _dt_step export 进来；
# 直接手跑本脚本时 dt_platform_ensure 会就地解析一份。详见 config/platforms.sh。
. "$ROOT/config/platforms.sh"
dt_platform_ensure || { echo "ERROR: 平台未定（见 config/platforms.sh）" >&2; exit 1; }

BASE=$ROOT/$DT_SYSIMG

# ---- 基线镜像：没有 prebuilds/system.img 就从 fw 固件包还原 ----
# fw 包里的 system_N.img 是裸数据块（checksparse.py 从 sparse 镜像切出来的），
# 按 rawprogram_unsparse0.xml 的 start_sector 写回零填充分区即可，
# 已实测与 prebuilds/system.img 的 simg2img 结果逐字节相同。
# 这样交付时不必预置 4.7GB 的 system.img，也强制客户用配对的 fw。
# 细节见 build.sh 的 restore_baseline / tools/fw_system_img.py / tools/lib/fw_locate.sh。
if [ ! -f "$BASE" ]; then
	echo ">>> $DT_SYSIMG 不存在，从 fw 固件包还原"
	"$ROOT/build.sh" restore --only system || exit 1
fi
[ -f "$BASE" ] || { echo "ERROR: 仍缺少 $BASE" >&2; exit 1; }

KREL=$(dt_krel_get || true)
[ -n "$KREL" ] || { echo "ERROR: 既没有 $DT_KREL_FILE，也无法从 $DT_RD_BASE 派生（先跑一次 buildenv）" >&2; exit 1; }

SECOND=$ROOT/stage/second
[ -d "$SECOND" ] || { echo "ERROR: 缺少 $SECOND，请先跑 source build.sh && buildkernel && buildstage" >&2; exit 1; }

for t in simg2img img2simg debugfs e2fsck; do
	command -v "$t" >/dev/null || { echo "ERROR: 找不到 $t（容器里用 ./docker_env/build.sh '. build.sh; buildsystem' 跑）" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# debugfs 版本必须 >= 1.46
#
# Ubuntu 20.04 自带的 1.45.5 写【多块目录】会丢条目：/lib/modules/<release>
# 有近 200 个 .ko（目录 2 块），用它 rm/write 后第 2 块的条目会全消失，
# 而且 e2fsck 查不出来（它认为结构一致），只有挂载上来才发现目录不全。
# docker_env/Dockerfile 用 Ubuntu 22.04 自带的 1.46.5（实测与自编译 1.47.0 等价）。
# ---------------------------------------------------------------------------
DBGVER=$(debugfs 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
DBGMAJ=${DBGVER%%.*}
DBGMIN=$(echo "$DBGVER" | cut -d. -f2)
if [ -z "$DBGVER" ] || [ "$DBGMAJ" -lt 1 ] || { [ "$DBGMAJ" -eq 1 ] && [ "$DBGMIN" -lt 46 ]; }; then
	echo "ERROR: debugfs 版本过低 ($DBGVER)，写多块目录会丢文件。" >&2
	echo "       请用 ./docker_env/build.sh '. build.sh; buildsystem' 跑（镜像里带 1.46.5），" >&2
	echo "       或在宿主上安装 e2fsprogs >= 1.46。" >&2
	exit 1
fi
echo "debugfs: $DBGVER ($(command -v debugfs))"

OUTDIR=$ROOT/out-system
RAW=$OUTDIR/system.raw
OUT=$OUTDIR/system.img
mkdir -p "$OUTDIR"

# 检查临时空间（raw 镜像 = 逻辑大小，本机是 8GiB）
need=$(stat -c%s "$BASE")
avail=$(df -B1 --output=avail "$OUTDIR" | tail -1)
if [ "$avail" -lt $((need * 3)) ]; then
	echo "ERROR: 临时空间不足。需要约 $((need * 3 / 1024 / 1024 / 1024))GiB，可用 $((avail / 1024 / 1024 / 1024))GiB" >&2
	exit 1
fi

MAP=$OUTDIR/.imgmap.txt
: > "$MAP"

echo "=== 1/6 展开 sparse -> raw ==="
rm -f "$RAW"
simg2img "$BASE" "$RAW"
echo "  raw: $(stat -c%s "$RAW") 字节"

MODDIR=/lib/modules/$KREL

# 递归列出一个目录树里的所有 .ko，输出 "名字 完整路径"
#
# debugfs 没有 find，只能自己递归。跳过：
#   build/           内核构建目录（巨大，且不含要装的 ko）
#   .debug/          调试符号目录
# 深度上限 6（实测最深的是 <kv>/kernel/drivers/net/usb/ = 4 层）
scan_tree() {
	local dir=$1 depth=$2
	[ "$depth" -gt 6 ] && return 0
	local mode name
	while read -r mode name; do
		[ -n "${name:-}" ] || continue
		case "$name" in .|..|build|.debug|source|lost+found) continue ;; esac
		case "$mode" in
			4*)   scan_tree "$dir/$name" $((depth + 1)) ;;
			100*) case "$name" in *.ko) echo "$name $dir/$name" ;; esac ;;
		esac
	done < <(debugfs -R "ls -l $dir" "$RAW" 2>/dev/null | awk '{print $2, $NF}')
}

echo
echo "=== 2/6 递归扫描镜像里所有模块位置 ==="
scan_tree "$MODDIR" 0 > "$MAP"
scan_tree "/opt/quectel" 0 >> "$MAP"

# 按目录汇总报告
awk '{ sub("/[^/]+$", "", $2); print $2 }' "$MAP" | sort | uniq -c \
	| while read -r c d; do printf '  %-52s %s 个\n' "$d/" "$c"; done
total=$(wc -l < "$MAP")
echo "  合计 $total 个 .ko"

# 同名出现在两处 -> 位置有歧义，必须先解决
dup=$(awk '{print $1}' "$MAP" | sort | uniq -d)
if [ -n "$dup" ]; then
	echo "ERROR: 下列模块在镜像里出现多次，位置有歧义：" >&2
	echo "$dup" | sed 's/^/       /' >&2
	exit 1
fi

	echo
	echo "=== 3/6 收集候选模块（内核自带模块，第二段 → /lib/modules/<kv>/）==="
	SRCLIST=$OUTDIR/.srclist.txt
	: > "$SRCLIST"
	c=0
	for ko in "$SECOND"/*.ko; do
		[ -f "$ko" ] || continue
		# 必须拼上文件名！只写目录的话后面 write 到目录上会失败，而紧接着的
		# `sif <dir> mode 0100644` 里的 0100000 是 S_IFREG —— 会把【目录变成
		# 普通文件】，之后整个 /lib/modules/<kv> 就废了（踩过，非常隐蔽）
		echo "$ko|$MODDIR/$(basename "$ko")" >> "$SRCLIST"
		c=$((c + 1))
	done
	printf '  %-46s %s 个 -> %s\n' "stage/second" "$c" "$MODDIR"
	[ "$c" -gt 0 ] || { echo "ERROR: $SECOND 里没有 .ko，请先跑 source build.sh && buildkernel && buildstage" >&2; exit 1; }

	echo
	echo "=== 4/6 生成 debugfs 命令 ==="
	CMDFILE=$OUTDIR/.debugfs.cmd
	: > "$CMDFILE"
	NEWLIST=$OUTDIR/.added.txt
	: > "$NEWLIST"
	replaced=0
	skipped=0
	added=0
	declare -A HIT_BY_LOC=()
	while IFS='|' read -r ko dest; do
		[ -n "$ko" ] || continue
		name=$(basename "$ko")
		target=$(awk -v n="$name" '$1 == n {print $2}' "$MAP")
		do_rm=1
		if [ -z "$target" ]; then
			# 镜像里没有 -> 本次构建【新产生】的模块（例如客户新开的 config 产出的
			# .ko）。必须新增进去，不能静默丢掉 —— 踩过：CONFIG_NULL_TTY=m 的
			# ttynull.ko 明明在 stage/second 里，镜像却一直是 248 个。
			if [ "${NO_ADD_NEW:-0}" = "1" ]; then
				skipped=$((skipped + 1))
				continue
			fi
			target=$dest          # 用来源目录对应的目标位置
			do_rm=""
			added=$((added + 1))
			echo "$name -> $target" >> "$NEWLIST"
		else
			replaced=$((replaced + 1))
		fi
		# 防御：目标必须是 .ko 文件路径。若变成目录，debugfs 的
		# `sif <dir> mode 0100644` 会把目录【变成普通文件】，静默毁掉整个目录树。
		# 宁可在这里直接退出。
		case "$target" in
			*.ko) ;;
			*) echo "ERROR: 目标路径不是 .ko 文件: '$target'（来自 $ko）" >&2; exit 1 ;;
		esac
		{
			if [ -n "$do_rm" ]; then echo "rm $target"; fi
			echo "write $ko $target"
			echo "sif $target mode 0100644"
			echo "sif $target uid 0"
			echo "sif $target gid 0"
		} >> "$CMDFILE"
		# 统计写入位置（替换 + 新增）
		case "$target" in
			"$MODDIR"/extra/*) HIT_BY_LOC[extra]=$(( ${HIT_BY_LOC[extra]:-0} + 1 )) ;;
			"$MODDIR"/kernel/*) HIT_BY_LOC[kernel]=$(( ${HIT_BY_LOC[kernel]:-0} + 1 )) ;;
			"$MODDIR"/*)       HIT_BY_LOC[root]=$(( ${HIT_BY_LOC[root]:-0} + 1 )) ;;
			/opt/quectel/*)    HIT_BY_LOC[opt]=$(( ${HIT_BY_LOC[opt]:-0} + 1 )) ;;
		esac
	done < "$SRCLIST"

	echo "  --- 替换（镜像里已有对应文件）---"
	echo "  $MODDIR/        <- ${HIT_BY_LOC[root]:-0} 个"
	echo "  $MODDIR/extra/  <- ${HIT_BY_LOC[extra]:-0} 个"
	echo "  $MODDIR/kernel/ <- ${HIT_BY_LOC[kernel]:-0} 个  (vendor: GobiNet / qmi_wwan_q)"
	echo "  /opt/quectel/   <- ${HIT_BY_LOC[opt]:-0} 个  (vendor: 显示/GPU 栈)"
	echo "  替换合计 $replaced 个"
	echo "  --- 新增（镜像里没有，本次构建新产生）---"
	if [ "$added" -gt 0 ]; then
		while read -r line; do printf '    + %s\n' "$line"; done < "$NEWLIST"
	else
		echo "    （无）"
	fi
	echo "  新增合计 $added 个 / 跳过 $skipped 个"
	[ "$replaced" -gt 0 ] || { echo "ERROR: 没有任何模块可替换" >&2; exit 1; }

	echo
	echo "=== 5/6 写入镜像 (debugfs) ==="
	debugfs -w -f "$CMDFILE" "$RAW" > "$OUTDIR/.debugfs.log" 2>&1 || true
	echo "  写入完成（日志: $OUTDIR/.debugfs.log）"

	echo "  修文件系统一致性 (e2fsck)"
	e2fsck -fy "$RAW" > "$OUTDIR/.e2fsck.log" 2>&1 || true
	tail -3 "$OUTDIR/.e2fsck.log" | sed 's/^/    /'

	# ---------------------------------------------------------------------------
	# 重建模块索引（仅当【新增过模块】）
	#
	# /etc/modules-load.d/*.conf 里的模块名由 modprobe 加载，走 modules.dep[.bin]。
	# 新增的 .ko 若不重建索引就 modprobe 不到（insmod 绝对路径仍可用）。
	# depmod 只读 .ko 自身的符号信息、不需要 vmlinux，可以离线跑。
	# 注：出厂 modules.dep 本身就不一致（含 10 条指向 /opt/quectel 的条目，而那些
	# 模块实际不在 /lib/modules 下；同时又漏了 extra/rmnet_core.ko），重建会顺带修正。
	# ---------------------------------------------------------------------------
	if [ "$added" -gt 0 ] && [ "${NO_DEPMOD:-0}" != "1" ]; then
		echo
		echo "=== 5.5/6 重建模块索引 (depmod) ==="
		DT=$OUTDIR/.depmod
		rm -rf "$DT"
		# ⚠️ 不能用 rdump /lib/modules：镜像里 <kv>/build/ 是【整个内核源码树】
		#    （实测 Links=24，即 22 个子目录，几万个文件）。rdump 会把它全部 dump
		#    出来 —— 巨慢，而且 depmod 根本不需要。
		#    改为逐个 dump 需要的文件：.ko + modules.builtin 等。一个 debugfs 进程
		#    配 -f 命令文件批量 dump，速度没问题。
		DKD=$DT/lib/modules/$KREL
		mkdir -p "$DKD"
		DUMP=$OUTDIR/.dump.cmd
		: > "$DUMP"
		# 镜像里此时已经写入了新模块，所以重新扫一遍拿完整清单
		scan_tree "$MODDIR" 0 > "$OUTDIR/.maptree.txt"
		n_tree=$(wc -l < "$OUTDIR/.maptree.txt")
		echo "  重新扫描镜像内模块: $n_tree 个"
		while read -r mn mp; do
			[ -n "${mn:-}" ] || continue
			mkdir -p "$DT$(dirname "$mp")"
			echo "dump_inode $mp $DT$mp" >> "$DUMP"
		done < "$OUTDIR/.maptree.txt"
		# depmod 还需要这几个非 .ko 文件才能正确区分 built-in；
		# 顺带把现有索引文件也 dump 下来，好比较 "重建前/后" 的条目数
		for f in modules.builtin modules.builtin.modinfo modules.order \
			 modules.dep modules.dep.bin modules.alias modules.alias.bin \
			 modules.softdep modules.devname modules.symbols modules.symbols.bin \
			 modules.builtin.alias.bin; do
			mkdir -p "$DT$(dirname "$MODDIR/$f")"
			echo "dump $MODDIR/$f $DT$MODDIR/$f" >> "$DUMP"
		done
		debugfs -f "$DUMP" "$RAW" > "$OUTDIR/.dump.log" 2>&1 || true
		echo "  dump 命令 $(wc -l < "$DUMP") 条 -> 产出文件 $(find "$DKD" -type f 2>/dev/null | wc -l) 个"
		rm -f "$DUMP" "$OUTDIR/.maptree.txt"
		if [ -f "$DKD/modules.dep" ] && command -v depmod >/dev/null 2>&1; then
			before=$(wc -l < "$DKD/modules.dep")
			depmod -b "$DT" "$KREL" 2>&1 | head -5 | sed 's/^/    /'
			echo "  modules.dep: $before -> $(wc -l < "$DKD/modules.dep") 行"
			IDX=$OUTDIR/.depmod.cmd
			: > "$IDX"
			n_idx=0
			for f in modules.dep modules.dep.bin modules.alias modules.alias.bin \
			         modules.order modules.softdep modules.devname \
			         modules.symbols modules.symbols.bin modules.builtin.alias.bin; do
			[ -f "$DKD/$f" ] || continue
			{
				echo "rm $MODDIR/$f"
				echo "write $DKD/$f $MODDIR/$f"
				echo "sif $MODDIR/$f mode 0100644"
				echo "sif $MODDIR/$f uid 0"
				echo "sif $MODDIR/$f gid 0"
			} >> "$IDX"
			n_idx=$((n_idx + 1))
		done
		debugfs -w -f "$IDX" "$RAW" >/dev/null 2>&1 || true
		echo "  已写回索引文件 $n_idx 个"
		rm -f "$IDX"
	else
		if ! command -v depmod >/dev/null 2>&1; then
			echo "  ⚠️  容器里没有 depmod，跳过索引重建" >&2
		else
			echo "  ⚠️  抽取模块树失败（$DKD 不存在），跳过索引重建" >&2
		fi
		echo "      新增模块在设备上要用 insmod 绝对路径加载" >&2
	fi
	rm -rf "$DT"
	fi

	echo
	echo "=== 6/6 重新打包 sparse ==="
	rm -f "$OUT"
	img2simg "$RAW" "$OUT" 4096
	rm -f "$RAW" "$CMDFILE" "$MAP" "$SRCLIST"
	# 保留 .debugfs.log / .e2fsck.log 以便排查（写入阶段出错时非常有用）

	echo
	echo "=== buildsystem 完成 ==="
	echo "输出镜像: $OUT"
	echo
	echo "下一步可执行 ./tools/flash.sh 进行 system.img 烧录。"
