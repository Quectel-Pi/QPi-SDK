#!/bin/bash
#
# one_key_rebuild_kernel.sh —— 一键执行公开版 system-only 构建
#
# ╔══════════════════════════════════════════════════════════════════════╗
# ║ 使用前：把【出厂固件包】放且只放一份到 ./fw/ 下                       ║
# ║                                                                      ║
# ║   mkdir -p fw                                                        ║
# ║   cp -a /path/to/QSM200U..._V01 fw/                                  ║
# ║                                                                      ║
# ║ 为什么需要它：dt 不是从零构建镜像，而是在【出厂基线镜像】上原地替换   ║
# ║ 模块。fw 包里的 system_1..59.img 就是基线 system.img 的内容，构建时   ║
# ║ 由 fw_system_img.py 还原（已实测与 simg2img(prebuilds/system.img) ║
# ║ 逐字节相同）。放成【唯一一份】是为了防止选错固件版本。               ║
# ╚══════════════════════════════════════════════════════════════════════╝
#
# 用法：
#   ./tools/compat/one_key_rebuild_kernel.sh                # 编译内核自带模块并生成 out-system/system.img
#   ./tools/compat/one_key_rebuild_kernel.sh --check        # 只做前置检查，不构建
#   ./tools/compat/one_key_rebuild_kernel.sh --dry-run      # 打印将要执行的动作
#
# 环境变量：
#   DT_FW_DIR=<目录>   指定固件包（默认自动找 ./fw/ 下的唯一一份）
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$ROOT"

# 档位（8 个：<SoC>-<rootfs>[-perf]）：一次性把档位与所有派生变量赋好并 export
# （fw 包前缀、DT 清单名、ramdisk 名、system.img 名、内核 config 名 …）。
# 档位来源：./fw/ 里那份包 > .tmp/platform 缓存 > 默认。【没有环境变量入口】
# 详见 config/platforms.sh 头部。
. "$ROOT/config/platforms.sh"
dt_platform_ensure || {
	echo "ERROR: 档位未定 —— 请把固件包放进 ./fw/（见 config/platforms.sh）" >&2
	exit 1
}

T0=$(date +%s)

# 工作目录。⚠️ 必须在【任何地方引用 .tmp 之前】建好：
#   .tmp/ 在 .gitignore 里，所以 `git clean -fdx` 会把它删掉，
#   而本脚本要用 .tmp/one_key.log（构建日志）和 .tmp/verify.raw（模块数校验）。
#   忘了这一步的表现极具误导性：构建还没开始就报「构建失败」，列出的却是
#   version magic / config check 那些内核原因（实测踩过，2026-09-14）。
mkdir -p "$ROOT/.tmp"

# 本仓库【只重建内核侧】：内核 Image + 内核自带模块。
# vendor 外部模块（audio/camera/bt/video/mmrm/graphics/wlan/data…）的源码与
# 构建逻辑已移除，它们在镜像里保持出厂版本不动。
DO_CHECK=0
DRY=0
for a in "$@"; do
	case "$a" in
	--check) DO_CHECK=1 ;;
	--dry-run) DRY=1 ;;
	# 便于用真正的出厂路径提示（客户拿到交付包时这个提示会被原样保留）
	--import-fw=*) IMPORT_FW=${a#*=} ;;
	-h | --help)
		sed -n '2,/^set -euo pipefail$/p' "$0" |
			sed -e 's/^# \{0,1\}//' -e '/^set -euo pipefail$/d'
		exit 0
		;;
	*)
		echo "未知参数: $a（用 --help 看用法）" >&2
		exit 1
		;;
	esac
done

say() {
	printf '\n\033[1m=== %s ===\033[0m' "$*"
	[ -n "${T0:-}" ] && printf ' \033[2m[已用时 %s]\033[0m' "$(elapsed)"
	printf '\n'
}
sub() { printf '  %s\n' "$*"; }
elapsed() {
	local d=$(( $(date +%s) - T0 ))
	if [ "$d" -lt 60 ]; then printf '%ds' "$d"
	elif [ "$d" -lt 3600 ]; then printf '%dm%02ds' $((d / 60)) $((d % 60))
	else printf '%dh%02dm' $((d / 3600)) $(((d % 3600) / 60)); fi
}
die() {
	printf '\n\033[1;31m[中止]\033[0m %s\n' "$*" >&2
	exit 1
}

# ───────────────────────── 1. 前置检查 ─────────────────────────
say "1/4 前置检查"

# 1.1 --import-fw：帮忙把固件包拷进 ./fw/
if [ -n "${IMPORT_FW:-}" ]; then
	[ -d "$IMPORT_FW" ] || die "--import-fw 指向的目录不存在: $IMPORT_FW"
	mkdir -p "$ROOT/fw"
	sub "拷贝固件包:"
	sub "  $IMPORT_FW"
	sub "  -> $ROOT/fw/$(basename "$IMPORT_FW")"
	[ "$DRY" = 1 ] && {
		sub "（--dry-run，未真正拷贝）"
	} || cp -a "$IMPORT_FW" "$ROOT/fw/"
fi

. "$ROOT/tools/lib/fw_locate.sh"

# 1.2 固件包：必须唯一
if ! FW=$(fw_locate); then
	echo
	echo "  提示：如果固件包在别处，也可以直接指定："
	echo "        DT_FW_DIR=/path/to/QSM... ./tools/compat/one_key_rebuild_kernel.sh"
	exit 1
fi
sub "固件包          : $FW"

# 1.3 必要的 modules.list 与 config
# 注意【不含】kernel release —— 它不是"主仓库出包产物"，而是从 fw 的 ramdisk 派生的
# 值（prebuilds/kernel[.perf].release 不随交付包预置），交给下面的 restore 步骤
# 现推，所以这里不能把它当"交付包完整性"来卡。
for f in kernel/msm-kernel/modules.list.msm.bengal.le \
	$DT_KCONFIG; do
	[ -f "$ROOT/$f" ] || die "缺少 $f（交付包不完整？）"
	done
sub "modules.list/config: 齐全"

# 1.4 基线（system.img / initramfs / Image / kernel.release）：缺了或不一致就从 fw 还原
"$ROOT/build.sh" restore --check 2>&1 | sed 's/^/  /' || true
if ! "$ROOT/build.sh" restore 2>&1 | sed 's/^/  /'; then
	die "基线还原失败（检查 ./fw/ 里的固件包是否完整）"
fi
[ -f "$ROOT/$DT_KREL_FILE" ] || die "基线还原后仍缺 $DT_KREL_FILE"
sub "内核 release    : $(cat "$ROOT/$DT_KREL_FILE")"

# 1.5 docker
command -v docker >/dev/null || die "找不到 docker（构建必须在容器里跑：宿主 make 版本与 5.15 Kbuild 不兼容）"
sub "docker          : $(docker --version | cut -d, -f1)"

if [ "$DO_CHECK" = 1 ]; then
	say "前置检查通过（--check 模式，不构建）"
	cat <<EOF

  下一步会执行：
    ./docker_env/build.sh ". build.sh; buildall"
EOF
	exit 0
fi

# ───────────────────────── 2. 构建 ─────────────────────────
say "2/4 构建（内核 Image 为副产物；默认产物为 out-system/system.img）"
sub "说明：vendor 外部模块（audio/camera/wlan/显示栈…）保持出厂版本，本次不重建。"

CMD="./docker_env/build.sh"
CMD_ARG=". build.sh; buildall"
LOG=$ROOT/.tmp/one_key.log
sub "命令: $CMD \"$CMD_ARG\""
sub "日志: $LOG"
sub ""
sub "提示：内核对 modules_install 等步骤会连续好几分钟零输出，"
sub "      这时 progress_tee.py 会打【带上下文的进度心跳】，形如："
sub "          ⏳ 已静默 92s（累计 4m08s，日志 123456 字节）"
sub "             │ 阶段 1/5 编译内核 (Image + 自带模块)"
sub "             │ 已收集 199 个 .ko"
sub "             │ 容器内 87 个进程，近 1 分钟改动 7491 个文件"
sub "      心跳走 stderr，日志文件本身不含心跳。"
[ "$DRY" = 1 ] && {
	sub "（--dry-run，未真正构建）"
	exit 0
}
# 用 progress_tee.py 代替 plain tee：既落盘又把进度打到终端，
# 且长时间静默时会报告「到底还在干活还是真死了」。
# （早期版本用后台 bash 看护线程，实测在真实构建里不输出、根因不明，
#   换成单进程 Python 过滤器后行为确定。见 progress_tee.py 头部说明。）
[ -x "$ROOT/tools/progress_tee.py" ] || { echo "ERROR: 缺少可执行的 $ROOT/tools/progress_tee.py" >&2; exit 1; }

# 分开取管道两端的退出码：progress_tee 自己起不来（如日志目录写不了）和
# 「构建真的失败」是两回事，混在一个提示里会把人带偏（实测踩过）。
set +e
"$CMD" "$CMD_ARG" 2>&1 | ROOT=$ROOT "$ROOT/tools/progress_tee.py" "$LOG"
_st=("${PIPESTATUS[@]}")
set -e
rc_build=${_st[0]:-0}
rc_tee=${_st[1]:-0}

if [ "$rc_tee" != 0 ] || [ "$rc_build" != 0 ]; then
	echo
	# 过滤器先倒的话，构建侧多半是被 SIGPIPE 带走的，先报它的错
	if [ "$rc_tee" != 0 ]; then
		die "进度过滤器 progress_tee.py 退出码 $rc_tee（构建输出未能记录到 $LOG）
  这不是内核/模块的问题。常见原因：
    - 日志所在目录不可写（\$ROOT/.tmp）
    - $ROOT/tools/progress_tee.py 被改动过，直接跑它看看报什么错：
          echo x | ROOT=$ROOT $ROOT/tools/progress_tee.py /tmp/t.log"
	fi
	die "构建失败（退出码 $rc_build），完整日志: $LOG
  常见原因：
    - version magic mismatch  -> 内核 release 与 fw 不一致：./build.sh restore 重新校对
    - config check 报缺项      -> 你改的 CONFIG_* 名写错了或有依赖未满足（日志里会列）
    - docker 权限              -> 需把用户加进 docker 组
    - 源码不完整               -> 与主仓库核对 ./tools/maintenance/sync_kernel.sh 是否跑过"
fi

# ───────────────────────── 3. 产物校验 ─────────────────────────
say "3/4 产物校验"

IMG_SYS=$ROOT/out-system/system.img

[ -f "$IMG_SYS" ] || die "没有生成 $IMG_SYS"

# system.img 的模块目录必须与当前 baseline 的 Kernel release 一致。
KREL=$(cat "$ROOT/$DT_KREL_FILE")
sub "内核 release    : $KREL"
sub ""
printf '  %-12s %-10s %s\n' 文件 大小 md5
for f in "$IMG_SYS"; do
	[ -f "$f" ] || continue
	printf '  %-12s %-10s %s\n' \
		"$(basename "$f")" "$(du -h "$f" | cut -f1)" "$(md5sum "$f" | cut -d' ' -f1)"
done

# 新增模块清单（build_system.sh 产出）
if [ -s "$ROOT/out-system/.added.txt" ]; then
	sub ""
	sub "本次新增到 system.img 的模块（$(wc -l <"$ROOT/out-system/.added.txt") 个）:"
	sed 's/^/    /' "$ROOT/out-system/.added.txt"
fi

# 镜像里实际有多少模块（和运行时 modprobe 看到的一致）
# 注意：`debugfs -R "ls"` 是【多列输出】（一行 4 个条目），
#       必须用 `ls -l`（一行一个），否则 grep '\.ko$' 会全部漏掉（实测数出 0）。
if command -v debugfs >/dev/null && command -v simg2img >/dev/null; then
	sub ""
	sub "校验镜像内模块数..."
	RAW=$ROOT/.tmp/verify.raw
	if simg2img "$IMG_SYS" "$RAW" 2>/dev/null; then
		kcnt() { debugfs -R "ls -l $1" "$RAW" 2>/dev/null | grep -c '\.ko$' || true; }
		# 第 1 处是内核自带模块（本次重建）；其余是 vendor 出厂模块，
		# 源码与构建逻辑不在本仓库，镜像里保持原样。
		# /opt/quectel 只在 debian 档存在（linux 档的 rootfs 不含 meta-quectel-debian
		# 那套配方），所以按 rootfs 轴有条件地列 —— 否则 linux 档会显示一个
		# 恒为 0 的目录，让人误以为模块丢了。
		DIRS=("/lib/modules/$KREL"
			"/lib/modules/$KREL/extra"
			"/lib/modules/$KREL/kernel/drivers/net/usb")
		[ "$DT_ROOTFS" = debian ] && DIRS+=("/opt/quectel")
		tot=0 i=0
		for d in "${DIRS[@]}"; do
			i=$((i + 1))
			c=$(kcnt "$d")
			tot=$((tot + c))
			if [ "$i" -eq 1 ]; then
				printf '  %-44s %4s 个 .ko   (内核自带，本次重建)\n' "$d" "$c"
			else
				printf '  %-44s %4s 个 .ko   (vendor 出厂，保持原样)\n' "$d" "$c"
			fi
		done
		printf '  %-44s %4s 个 .ko\n' "合计" "$tot"
		rm -f "$RAW"
	fi
fi

# ───────────────────────── 4. 烧写指引 ─────────────────────────
say "4/4 烧写（二选一）"

cat <<EOF

  本 SDK 只生成 out-system/system.img，不生成 boot.img、DTB 或 dtbo.img。
  设备上这些分区继续使用当前 fw 的原厂版本。

  使用本仓库的 tools/flash.sh 写入 system.img：
    cd $ROOT
    ./tools/flash.sh --dry-run      # 先检查目标槽和烧写计划
    ./tools/flash.sh                # 自动选择 A/B 中当前未运行的槽
EOF

# ───────────────────────── 5. 收尾 ─────────────────────────
say "完成"
sub "公开版默认产物: $IMG_SYS"
sub "完整日志   -> $LOG"
sub "总耗时     : $(elapsed)"
sub ""
sub "烧写后建议在设备上验证："
sub "  adb shell /sbin/abctl --boot_slot                  # 确认在哪个槽"
sub "  adb shell 'ls /lib/modules/$KREL/*.ko | wc -l'     # 模块数"
