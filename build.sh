#!/usr/bin/env bash
#
# dt 仓库构建入口（Quectel SC200U / SC200E —— bengal_le 家族两个产品）
#
# 用法（交互）:
#   source build.sh          # 注册 build* 命令并打印帮助
#   buildall                 # 公开版主流程 → out-system/system.img
#
# 用法（非交互，容器/CI）:
#   ./docker_env/build.sh ". build.sh; buildall"
#
# 本文件只做【编排】：具体每一步的实现在 tools/ 下。
#   restore_baseline -> 从 fw 导出 prebuilds/ 那 4 个大基线（原独立脚本，已内联）
#   buildenv      -> restore_baseline + 检查 config/docker（环境准备）
#   buildmenuconfig -> tools/build-menuconfig.sh  交互修改当前档位的完整内核配置
#   buildkernel   -> tools/build-kernel.sh    编内核 → Image（副产物）+ out-modules/kernel/*.ko
#   buildstage    -> 本文件内联（按 modules.list 分第一段/第二段）
#   buildramdisk  -> tools/build-ramdisk.sh   → out-ramdisk/*.cpio.lz4（替换第一段模块）
#   buildsystem   -> tools/build-system.sh    → out-system/system.img（替换第二段模块）
#
# 注意：本文件【刻意不设 set -e】—— 它会被 source 进用户当前 shell，
#       设了会污染交互环境。错误处理全部显式写成 "|| return 1"。
#

_dt_build_is_sourced() {
	[ "${BASH_SOURCE[0]}" != "$0" ]
}

DT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DT_ROOT
export TOPDIR="$DT_ROOT"

DT_TOOLS="$DT_ROOT/tools"

# ---------------------------------------------------------------------------
# 档位（8 个：<SoC>-<rootfs>[-perf]）
# ---------------------------------------------------------------------------
#     200u-debian  200u-debian-perf  200u-linux  200u-linux-perf
#     200e-debian  200e-debian-perf  200e-linux  200e-linux-perf
# 裸 200u / 200e 等价于 200u-debian / 200e-debian（兼容旧写法）。
#
# 两个与产品无关的轴决定差异（详见 config/platforms.sh 头部）：
#     rootfs  debian / linux   —— /opt/quectel/*.ko 有无、fw 的 BD01/BL01
#     perf    带 / 不带        —— config/kernel[.perf].config、kernel[.perf].release、fw 的 _perf
#
# 生效档位（$DT_PLATFORM_EFF）的来源，优先级从高到低：
#     ./fw/ 里那份合格固件包  >  .tmp/platform 缓存  >  $DT_PLATFORM_DEFAULT
# 【没有环境变量入口】—— 档位本来就由 ./fw/ 里那份包唯一决定，再加覆盖只会
# 制造「env 说 A、fw 说 B」的分裂（踩过）。详见 config/platforms.sh 头部。
. "$DT_ROOT/config/platforms.sh"

# 解析平台并导出 —— tools/ 下的脚本靠 export 拿到，不必各自再解析一遍。
# $1=quiet 时抑制错误输出（给各 build* 函数调用时重新解析用）。
#
# 为什么各 build* 函数要「调用时重新解析」：本文件被 source 后档位就定死了，
# 而用户可能在同一个 shell 里换了 ./fw/ 的固件包、或刚跑完 buildenv 让
# .tmp/platform 变了。调用时重新解析让这些变化【立刻生效】，不必重新 source
# （也因此 fw 与缓存的优先级才那么重要）。
_dt_baseline_platform_hint() {
	local normal="$DT_ROOT/config/kernel.config.meta"
	local perf="$DT_ROOT/config/kernel.perf.config.meta"
	local p=""
	if [ -s "$normal" ] && [ ! -e "$perf" ]; then
		p=$(sed -n 's/^PLATFORM=//p' "$normal" | head -1)
	elif [ -s "$perf" ] && [ ! -e "$normal" ]; then
		p=$(sed -n 's/^PLATFORM=//p' "$perf" | head -1)
	fi
	[ -n "$p" ] && dt_platform_valid "$p" || return 1
	printf '%s\n' "$p"
}

_dt_resolve_platform() {
	local quiet=${1:-} baseline_platform=""
	baseline_platform=$(_dt_baseline_platform_hint 2>/dev/null || true)
	# ⚠ 这里【不能】写成 p=$(dt_platform_resolve …) —— 命令替换会 fork 子 shell，
	#   _dt_platform_resolve_impl 设的 DT_PLATFORM_EFF / DT_PLATFORM_SRC 就全丢在
	#   子 shell 里，本 shell 只拿到那行回显。而 DT_PLATFORM_SRC 正是判断
	#   "档位是探测到的还是默认兜底"的依据（buildall 靠它拒绝盲构建）。
	if [ -n "$baseline_platform" ]; then
		DT_PLATFORM_EFF=$baseline_platform
		DT_PLATFORM_SRC=baseline
		DT_PLATFORM_SRC_DESC="current baseline metadata"
		export DT_PLATFORM_EFF DT_PLATFORM_SRC DT_PLATFORM_SRC_DESC
	elif [ "$quiet" = quiet ]; then
		_dt_platform_resolve_impl 2>/dev/null || return 1
	else
		_dt_platform_resolve_impl || return 1
	fi
	# 一次性把档位与【所有派生变量】赋好并 export（含 DT_KCONFIG /
	# DT_KREL_FILE / DT_SYSIMG / DT_IMAGE …）。
	# 各脚本一律用这些变量，别自己拼文件名 —— 那样轴一变就要满地改。
	dt_platform_set_env "$DT_PLATFORM_EFF"
}

# 解析失败（如两份固件包并存且没指定）时不让整个 shell 挂掉 —— 本文件会被 source
if ! _dt_resolve_platform; then
	echo "WARN: 档位未定（原因见上），本次按默认 $DT_PLATFORM_DEFAULT 继续。" >&2
	echo "      把目标档位的固件包放进 ./fw/ 后重跑一次 buildenv 即可 —— 档位没有环境变量入口。" >&2
	dt_platform_set_env "$DT_PLATFORM_DEFAULT"
fi

# ---------------------------------------------------------------------------
# 内部工具
# ---------------------------------------------------------------------------

# 在仓库根下跑 tools/ 里的步骤脚本。
# 用子 shell：既保证 cwd=仓库根（tools/ 下那些脚本依赖裸相对路径
# prebuilds/ dts/ .scratch/ ...），又不把 cd 泄漏给调用者。
_dt_step() {
	local script="$1"; shift
	# 子 shell 里重新解析平台，把 export 带进去给被 exec 的脚本
	( cd "$DT_ROOT" || exit 1
	  _dt_resolve_platform quiet || true
	  exec "$DT_TOOLS/$script" "$@" )
}

# 阶段 banner。格式【必须】保持 "# N/M 描述"：
# tools/progress_tee.py 用正则 (\d+)/(\d+)\s+(.+?) 从日志里认阶段，见其第 47-49 行。
_dt_banner() {
	echo
	echo "################################################################"
	echo "# $*"
	echo "################################################################"
}

# ---------------------------------------------------------------------------
# 应用开发（V1：Docker 内 Ubuntu ARM64 GNU C/C++ 交叉工具链）
# ---------------------------------------------------------------------------

DT_APP_TEMPLATES="$DT_ROOT/docs/templates"
DT_APP_EXAMPLES="$DT_ROOT/docs/examples"

# 从模板创建应用：newapp <应用名> [模板名]
newapp() {
	local name="${1:-}"
	local template="${2:-hello}"
	local tpl_dir dst_dir

	if [ -z "$name" ]; then
		echo "用法: newapp <应用名> [模板名]" >&2
		return 1
	fi
	case "$name" in
		*[!a-zA-Z0-9_]*)
			echo "ERROR: 应用名仅允许字母、数字和下划线: $name" >&2
			return 1
			;;
	esac
	if [ "$template" != hello ]; then
		echo "ERROR: 未知模板: $template（V1 仅支持 hello）" >&2
		return 1
	fi

	tpl_dir="$DT_APP_TEMPLATES/$template"
	dst_dir="$DT_APP_EXAMPLES/$name"
	for f in CMakeLists.txt main.cpp hello_c.c; do
		if [ ! -f "$tpl_dir/$f" ]; then
			echo "ERROR: 模板不完整，缺少: $tpl_dir/$f" >&2
			return 1
		fi
	done
	if [ -e "$dst_dir" ] || [ -L "$dst_dir" ]; then
		echo "ERROR: 目标已存在，拒绝覆盖: $dst_dir" >&2
		return 1
	fi

	mkdir -p "$DT_APP_EXAMPLES" || return 1
	cp -a "$tpl_dir" "$dst_dir" || return 1
	sed -i "s/{{PROJECT_NAME}}/$name/g" "$dst_dir/CMakeLists.txt" || return 1

	echo "已创建应用: $dst_dir"
	echo "编译: buildapp docs/examples/$name"
}

# 在现有 Docker 环境中交叉编译应用：buildapp <应用目录>
buildapp() {
	local dir="${1:-}"
	local app_dir app_q command

	if [ -z "$dir" ]; then
		echo "用法: buildapp <应用目录>" >&2
		return 1
	fi
	app_dir=$(cd "$dir" 2>/dev/null && pwd -P) || {
		echo "ERROR: 应用目录不存在: $dir" >&2
		return 1
	}
	case "$app_dir" in
		"$DT_ROOT"|"$DT_ROOT"/*) ;;
		*)
			echo "ERROR: 应用目录必须位于当前 SDK 内: $DT_ROOT" >&2
			return 1
			;;
	esac

	printf -v app_q '%q' "$app_dir"
	command="$DT_ROOT/tools/build-app.sh $app_q"
	"$DT_ROOT/docker_env/build.sh" "$command"
}

# ---------------------------------------------------------------------------
# 环境准备
# ---------------------------------------------------------------------------

# 从 fw 固件包还原 prebuilds/ 里的基线文件（原名 restore_baseline，
# 2026-09-17 内联进本文件，这样 buildenv 直接调用它，不必多一个脚本）。
#
# 背景：dt 不是从零构建镜像，而是在【出厂基线镜像】上原地替换模块。这些基线
# 本来来自 Yocto 出包目录，但 fw 包里也有同样内容，所以可以不随交付包预置：
#
#   $DT_SYSIMG                     prebuilds/system.img         <- fw 的 system_*.img 分片
#   $DT_RD_BASE                    prebuilds/ramdisk.cpio.lz4
#                                  <- fw/boot.img 里那个 $DT_RD_NAME
#   $DT_IMAGE                      prebuilds/Image              <- fw/boot.img 的 kernel
#   $DT_DTB_BASE                   prebuilds/dtb.img          <- fw/boot.img 的 DTB 段
#   $DT_DTBO_BASE                  prebuilds/dtbo.img         <- fw/dtbo.img
#   $DT_KREL_FILE                  prebuilds/kernel[.perf].release <- 【派生】自上面
#                                  那个 ramdisk 的 lib/modules/<release>，不预置
#
# 落盘名的带轴规则（关键设计，别退回"每档位一份"）：
#   统一名（不带档位）system.img / Image / ramdisk.cpio.lz4
#       —— 内容确实每档位都不同，所以【身份由 prebuilds/baseline.platform 承载】：
#          换档位后必须查标记才知道这份基线是谁的。别再退回"只看文件存在性"的
#          判定 —— 那会让换档位时静默拿上一个档位的基线（实测会混档）。
#   只带【perf】轴 kernel[.perf].release / config/kernel[.perf].config
#       —— config 是用户会手改的文件，绝不能按档位复制 4 份（改了不生效最坑）
#       —— release 是【派生态】（值 = ramdisk 里 lib/modules/<release> 目录名），
#          所以也不预置：每次 buildenv 用 dt_krel_derive 校对，值变了才落盘
#   统一名（不带档位）dtb.img / dtbo.img
#       —— 从当前档位 fw 的 boot.img / dtbo.img 还原，同样必须用归属标记防止混档
#   统一名（不带档位）ramdisk.cpio.lz4
#       —— fw 里那个原始名只由 MACHINE 决定，同 SoC 的档位会撞名；
#          而实测内容确实不同（模块大小、lib/modules/<release> 都可能不一样），
#          所以基线副本必须带档位后缀，否则会"已存在 → 跳过"而用错基线
#
# 另一类【不预置、也不另存副本】的：模块分段清单 modules.list.msm.bengal.le。
# 它本来就住在内核源码树里（kernel/msm-kernel/，由 tools/maintenance/sync_kernel.sh 同步，
# 内核构建自己也按它打 vendor_dlkm），buildstage 直接读那一份，不再拷到
# prebuilds/ —— 避免两份分叉后分段与内核预期静默不一致。
#
# 前置：固件包放 ./fw/ 下（见 tools/lib/fw_locate.sh）
#       ./fw/ 下【只允许放一份】合格固件包（本项目约定）。放两份会直接报错 ——
#       不替你猜，因为猜错就是拿别的档位的 MACHINE / 清单 / 基线去构建。
#
# 参数：--check 只报告 / --force 全部重导 / --only {system,ramdisk,kernel,dt,release}
# 环境变量：DT_FW_DIR=<fw目录>
#
# ⚠️ 整个主体包在子 shell + set -euo pipefail 里：本文件会被 source 进用户
#    shell，顶层不能设 -e；放进子 shell 既不污染用户环境，又能原样保留原来
#    那套 exit/trap 写法（trap ... EXIT 在子 shell 退出时触发）。
restore_baseline() {
	_dt_resolve_platform quiet || true
	(
	# ⚠ 见下面 FW=$(fw_require) 处的注释：本函数总被 `|| …` / if 调用，
	#   bash 会因此抑制函数体内的 -e，所以这句 set -e 是【名义上的】。
	#   凡可能失败的命令都要自带 `|| die` / `|| exit 1`，别依赖隐式 -e。
	set -euo pipefail

	cd "$DT_ROOT" || exit 1
	ROOT=$DT_ROOT

	FORCE=0
	CHECK=0
	ONLY=all
	while [ $# -gt 0 ]; do
		case "$1" in
		--force) FORCE=1 ;;
		--check) CHECK=1 ;;
		--only)
			ONLY=${2:?--only 需要参数: system|ramdisk|kernel|dt|release}
			shift
			;;
		-h | --help)
			printf '%s\n' \
				"用法: restore_baseline [--check] [--force] [--only system|ramdisk|kernel|dt|release]" \
				"  (无参数)  只还原【缺失】的" \
				"  --force   全部重新还原" \
				"  --only X  只处理 X: system | ramdisk | kernel | dt | release" \
				"  --check   只报告状态，不写文件" \
				"" \
				"环境变量: DT_FW_DIR=<fw目录>" \
				"详见 build.sh 里 restore_baseline 的注释头"
			exit 0
			;;
		*) echo "未知参数: $1（用 --help 看用法）" >&2; exit 1 ;;
		esac
		shift
	done

	case "$ONLY" in system | ramdisk | kernel | dt | release | all) ;; *) echo "ERROR: --only 只支持 system|ramdisk|kernel|dt|release" >&2; exit 1 ;; esac

	say() { printf '\n=== %s ===\n' "$*"; }
	sub() { printf '  %s\n' "$*"; }
	die() {
		printf '\n[中止] %s\n' "$*" >&2
		exit 1
	}

	SYS=$ROOT/$DT_SYSIMG
	RD=$ROOT/$DT_RD_BASE
	IMG=$ROOT/$DT_IMAGE
	DTB=$ROOT/$DT_DTB_BASE
	DTBO=$ROOT/$DT_DTBO_BASE
	KREL_F=$ROOT/$DT_KREL_FILE
	# 基线归属标记（统一文件名方案的地位等价物）：记着每项大基线属于哪个档位
	BL_MARK=$(dt_baseline_mark_file)
	DT_BASELINE_MARK_FILE=${BL_MARK#"$ROOT/"}	# 打印用（相对路径）

	want() { [ "$ONLY" = all ] || [ "$ONLY" = "$1" ]; }

	# 内核 release 的推导算法只有一份，在 config/platforms.sh 的 dt_krel_derive()
	# （tools/verification/verify_* / tools/flash.sh 也都走它）。这里直接用 —— 别在本文件里再抄一份，
	# 两份实现迟早会漂移（本文件早先就有一份 derive_krel）。

	# ── 状态报告 ────────────────────────────────────────────
	# 统一名之后，"文件在不在"不足以说明可用性 —— 还要看标记里它属于哪个档位。
	status_line() {
		local f=$1 label=$2
		if [ ! -f "$f" ]; then
			printf '  %-46s %-10s %s\n' "$label" "-" "缺失（需还原）"
			return
		fi
		local h
		case "$label" in
		"$DT_SYSIMG") h=system ;;
		"$DT_RD_BASE") h=ramdisk ;;
		"$DT_IMAGE") h=kernel ;;
		"$DT_DTB_BASE") h=dtb ;;
		"$DT_DTBO_BASE") h=dtbo ;;
		*) h="" ;;
		esac
		if [ -n "$h" ]; then
			local cur
			cur=$(dt_baseline_mark_get "$h" 2>/dev/null || true)
			if [ "$cur" = "$DT_PLATFORM_EFF" ]; then
				printf '  %-46s %-10s %s\n' "$label" "$(du -h "$f" | cut -f1)" "已存在（属于 $cur）✅"
			elif [ -n "$cur" ]; then
				printf '  %-46s %-10s %s\n' "$label" "$(du -h "$f" | cut -f1)" "⚠ 属于 $cur，非本档位（需重导）"
			else
				printf '  %-46s %-10s %s\n' "$label" "$(du -h "$f" | cut -f1)" "⚠ 无归属标记（需重导）"
			fi
		else
			printf '  %-46s %-10s %s\n' "$label" "$(du -h "$f" | cut -f1)" "已存在"
		fi
	}

	if [ "$CHECK" = 1 ]; then
		say "基线状态"
		status_line "$SYS" "$DT_SYSIMG"
		status_line "$RD" "$DT_RD_BASE"
		status_line "$IMG" "$DT_IMAGE"
		status_line "$DTB" "$DT_DTB_BASE"
		status_line "$DTBO" "$DT_DTBO_BASE"
		# release 是派生态：文件不在也能从 ramdisk 现推出来，"没文件"不等于"缺基线"；
		# 反过来，文件在但与 ramdisk 不一致（换了 ./fw/ 里的固件包）才真要更新。
		krel_rd=$(dt_krel_derive "$RD" || true)
		krel_file=$(cat "$KREL_F" 2>/dev/null || true)
		if [ -n "$krel_rd" ] && [ "$krel_file" = "$krel_rd" ]; then
			printf '  %-46s %-10s %s\n' "$DT_KREL_FILE" "$(du -h "$KREL_F" | cut -f1)" "已存在 = $krel_rd（与 $DT_RD_BASE 一致）"
		elif [ -n "$krel_rd" ]; then
			printf '  %-46s %-10s %s\n' "$DT_KREL_FILE" "-" "待更新 -> $krel_rd（由 $DT_RD_BASE 派生）"
		elif [ -n "$krel_file" ]; then
			printf '  %-46s %-10s %s\n' "$DT_KREL_FILE" "$(du -h "$KREL_F" | cut -f1)" "已存在 = $krel_file"
		else
			status_line "$KREL_F" "$DT_KREL_FILE"
		fi
		echo
		miss=0
		# 统一名 ⇒ 必须"文件在 且 标记属于本档位"才算齐
		want system && { [ ! -f "$SYS" ] || ! dt_baseline_ok system; } && miss=1
		want ramdisk && { [ ! -f "$RD" ] || ! dt_baseline_ok ramdisk; } && miss=1
		want kernel && { [ ! -f "$IMG" ] || ! dt_baseline_ok kernel; } && miss=1
		want dt && { [ ! -s "$DTB" ] || ! dt_baseline_ok dtb; } && miss=1
		want dt && { [ ! -s "$DTBO" ] || ! dt_baseline_ok dtbo; } && miss=1
		want release && [ -z "$krel_rd" ] && [ -z "$krel_file" ] && miss=1
		want release && [ -n "$krel_rd" ] && [ "$krel_file" != "$krel_rd" ] && miss=1
		if [ "$miss" = 0 ]; then
			echo "  基线齐全 ✅"
		else
			echo "  有缺失 —— 跑 build.sh restore（或 buildenv）从 fw 还原"
		fi
		exit 0
	fi

# ⚠⚠ 这些基线现在是【统一文件名】，所以判定必须是
	#     「文件存在 且 标记里写的就是当前档位」——只看 [ -f ] 会混档（实测过）。
	need_sys=0
	want system && { [ ! -f "$SYS" ] || ! dt_baseline_ok system || [ "$FORCE" = 1 ]; } && need_sys=1
	need_rd=0
	want ramdisk && { [ ! -f "$RD" ] || ! dt_baseline_ok ramdisk || [ "$FORCE" = 1 ]; } && need_rd=1
	need_img=0
	want kernel && { [ ! -f "$IMG" ] || ! dt_baseline_ok kernel || [ "$FORCE" = 1 ]; } && need_img=1
	need_dtb=0
	want dt && { [ ! -s "$DTB" ] || ! dt_baseline_ok dtb || [ "$FORCE" = 1 ]; } && need_dtb=1
	need_dtbo=0
	want dt && { [ ! -s "$DTBO" ] || ! dt_baseline_ok dtbo || [ "$FORCE" = 1 ]; } && need_dtbo=1
	# release 不是独立基线，而是由 ramdisk 派生的值。所以这里判断的是"派生的值
	# 是否已正确落盘"，而不是"文件是否存在"：
	#   - 换了 ./fw/ 里的固件包（ramdisk 里 lib/modules/<release> 变了）→ 自动重写，
	#     修掉旧写法 [ ! -f "$KREL_F" ] 留下的"陈旧值永不更新"
	#   - 值本来就一致 → 不动它，于是也不会逼着每次 buildenv 都必须能找到 fw
	need_krel=0
	if want release; then
		krel_rd=$(dt_krel_derive "$RD" || true)
		if [ -z "$krel_rd" ]; then
			need_krel=1 # ramdisk 还没有/不可读 —— 等它从 fw 还原出来再派生
		elif [ "$FORCE" = 1 ]; then
			need_krel=1
		elif [ ! -f "$KREL_F" ] || [ "$(cat "$KREL_F" 2>/dev/null)" != "$krel_rd" ]; then
			need_krel=1
		fi
	fi

	if [ "$need_sys" = 0 ] && [ "$need_rd" = 0 ] && [ "$need_img" = 0 ] && \
		[ "$need_dtb" = 0 ] && [ "$need_dtbo" = 0 ] && [ "$need_krel" = 0 ]; then
		say "基线齐全，无需还原"
		status_line "$SYS" "$DT_SYSIMG"
		status_line "$RD" "$DT_RD_BASE"
		status_line "$IMG" "$DT_IMAGE"
		status_line "$DTB" "$DT_DTB_BASE"
		status_line "$DTBO" "$DT_DTBO_BASE"
		status_line "$KREL_F" "$DT_KREL_FILE"
		exit 0
	fi

	# ── 定位 fw ────────────────────────────────────────────
	. "$DT_TOOLS/lib/fw_locate.sh"
	say "定位固件包"
	# ⚠⚠ 必须写 `|| exit 1`，不能只靠上面那句 set -e —— 实测（2026-09-17）：
	#   bash 规定「函数若在 || / && 列表或 if/while 条件里被调用，则其函数体内
	#   所有命令都不受 -e 影响」，连体内显式 set -e 的嵌套子 shell 也一起被抑制。
	#   而本函数的【所有】调用点都是 `restore_baseline || rc=1` 或 if 形式，
	#   所以那句 set -e 实际不生效。少了 `|| exit 1` 的后果实测过：fw 缺失时
	#   FW 留空、继续往下跑，最后报出 `[中止]  里没有 boot.img` 这种无名错误。
	FW=$(fw_require) || exit 1
	[ -n "$FW" ] || die "内部错误: fw_require 返回成功但路径为空"
	sub "fw 目录: $FW"
	if [ "$need_rd" = 1 ] || [ "$need_img" = 1 ] || [ "$need_dtb" = 1 ] || [ "$need_krel" = 1 ]; then
		[ -f "$FW/boot.img" ] || die "$FW 里没有 boot.img，无法还原 ramdisk / Image / dtb / kernel.release"
	fi
	if [ "$need_dtbo" = 1 ]; then
		[ -s "$FW/dtbo.img" ] || die "$FW 里没有有效的 dtbo.img，无法还原 DT baseline"
	fi

	mkdir -p "$ROOT/prebuilds"

	# ── 1. system.img ──────────────────────────────────────
	if [ "$need_sys" = 1 ]; then
		say "还原 $DT_SYSIMG（从 fw 的 system_*.img 分片）"
		[ -x "$DT_TOOLS/fw_system_img.py" ] || die "缺少 $DT_TOOLS/fw_system_img.py"
		TMPRAW=$ROOT/$DT_TMPRAW
		trap 'rm -f "$TMPRAW"' EXIT
		if command -v img2simg >/dev/null 2>&1; then
			"$DT_TOOLS/fw_system_img.py" "$FW" system_a "$TMPRAW" --sparse "$SYS" || die "system.img 还原失败"
		else
			# 宿主只负责拼出 raw；raw/sparse 都在仓库挂载内，
			# 因此任意 DT_FW_DIR 仍由宿主读取，容器只做 raw -> sparse。
			"$DT_TOOLS/fw_system_img.py" "$FW" system_a "$TMPRAW" || die "system.img raw 还原失败"
			[ -x "$ROOT/docker_env/build.sh" ] || die "宿主缺少 img2simg，且找不到 $ROOT/docker_env/build.sh"
			rm -f "$SYS"
			printf -v img2simg_cmd 'img2simg %q %q 4096' "$TMPRAW" "$SYS"
			"$ROOT/docker_env/build.sh" "$img2simg_cmd" || die "Docker 内 img2simg 转换失败"
			[ -s "$SYS" ] || die "Docker 内 img2simg 未生成有效的 $DT_SYSIMG"
		fi
		rm -f "$TMPRAW"
		trap - EXIT
		# 数据写完了才记标记 —— 标记是"这一项已就位且属于本档位"的提交点
		dt_baseline_mark_set system || die "无法写基线标记 $DT_BASELINE_MARK_FILE"
		sub "完成: $(du -h "$SYS" | cut -f1)  $SYS  （标记: system=$DT_PLATFORM_EFF）"
	elif want system; then
		sub "$DT_SYSIMG 已存在且标记属于 $DT_PLATFORM_EFF，跳过"
	fi

	# ── 2. ramdisk ────────────────────────────────────────
	if [ "$need_rd" = 1 ]; then
		say "还原 $DT_RD_BASE（取自 fw/boot.img 里的 $DT_RD_NAME）"
		[ -x "$DT_TOOLS/fw_boot_extract.py" ] || die "缺少 $DT_TOOLS/fw_boot_extract.py"
		"$DT_TOOLS/fw_boot_extract.py" "$FW/boot.img" --ramdisk "$RD" || die "ramdisk 还原失败"
		if command -v lz4 >/dev/null 2>&1; then
			if lz4 -t "$RD" >/dev/null 2>&1; then
				sub "lz4 完整性校验通过"
			else
				rm -f "$RD"
				die "抽出的 ramdisk 不是合法 lz4，已删除"
			fi
		fi
		dt_baseline_mark_set ramdisk || die "无法写基线标记 $DT_BASELINE_MARK_FILE"
		sub "完成: $(du -h "$RD" | cut -f1)  $RD  （标记: ramdisk=$DT_PLATFORM_EFF）"
	elif want ramdisk; then
		sub "$DT_RD_BASE 已存在且标记属于 $DT_PLATFORM_EFF，跳过"
	fi

	# ── 3. Image（内核）───────────────────────────────────
	if [ "$need_img" = 1 ]; then
		say "还原 $DT_IMAGE（从 fw/boot.img）"
		[ -x "$DT_TOOLS/fw_boot_extract.py" ] || die "缺少 $DT_TOOLS/fw_boot_extract.py"
		"$DT_TOOLS/fw_boot_extract.py" "$FW/boot.img" --kernel "$IMG" || die "Image 还原失败"
		dt_baseline_mark_set kernel || die "无法写基线标记 $DT_BASELINE_MARK_FILE"
		sub "完成: $(du -h "$IMG" | cut -f1)  $IMG  （标记: kernel=$DT_PLATFORM_EFF）"
		sub "（仅供 build.sh 在【不重编内核】时回退使用；重编内核会用 out-kernel/dist/Image）"
	elif want kernel; then
		sub "$DT_IMAGE 已存在且标记属于 $DT_PLATFORM_EFF，跳过"
	fi

	# ── 4. 出厂 DTB / DTBO ───────────────────────────────
	if [ "$need_dtb" = 1 ]; then
		say "还原 $DT_DTB_BASE（从 fw/boot.img 的 DTB 段）"
		[ -x "$DT_TOOLS/fw_boot_extract.py" ] || die "缺少 $DT_TOOLS/fw_boot_extract.py"
		DTB_TMP="$DTB.tmp.$$"
		rm -f "$DTB_TMP"
		"$DT_TOOLS/fw_boot_extract.py" "$FW/boot.img" --dtb "$DTB_TMP" || {
			rm -f "$DTB_TMP"
			die "dtb.img 还原失败"
		}
		# 本项目 secure boot.img 会在镜像末尾追加 2048 字节签名块：
		# 前 256 字节为 RSA 签名，后 1792 字节为零。提取器按 boot v2
		# 布局取“DTB 偏移到文件末尾”，因此这里识别并裁掉该签名块。
		if [ "$(stat -c%s "$DTB_TMP")" -gt 2048 ] && \
			cmp -s <(tail -c 1792 "$DTB_TMP") <(head -c 1792 /dev/zero); then
			truncate -s -2048 "$DTB_TMP" || {
				rm -f "$DTB_TMP"
				die "无法从提取结果中移除 boot.img 签名块"
			}
		fi
		DTB_MAGIC=$(od -An -tx1 -N4 "$DTB_TMP" 2>/dev/null | tr -d '[:space:]')
		if [ ! -s "$DTB_TMP" ] || [ "$DTB_MAGIC" != d00dfeed ]; then
			rm -f "$DTB_TMP"
			die "从 fw/boot.img 抽出的 DTB 为空或 FDT magic 无效"
		fi
		mv -f "$DTB_TMP" "$DTB" || die "无法保存 $DT_DTB_BASE"
		dt_baseline_mark_set dtb || die "无法写基线标记 $DT_BASELINE_MARK_FILE"
		sub "完成: $(du -h "$DTB" | cut -f1)  $DTB  （标记: dtb=$DT_PLATFORM_EFF）"
	elif want dt; then
		sub "$DT_DTB_BASE 已存在且标记属于 $DT_PLATFORM_EFF，跳过"
	fi

	if [ "$need_dtbo" = 1 ]; then
		say "还原 $DT_DTBO_BASE（从 fw/dtbo.img）"
		DTBO_TMP="$DTBO.tmp.$$"
		cp -f "$FW/dtbo.img" "$DTBO_TMP" || {
			rm -f "$DTBO_TMP"
			die "dtbo.img 还原失败"
		}
		if [ ! -s "$DTBO_TMP" ]; then
			rm -f "$DTBO_TMP"
			die "从 fw 复制出的 dtbo.img 为空"
		fi
		mv -f "$DTBO_TMP" "$DTBO" || die "无法保存 $DT_DTBO_BASE"
		dt_baseline_mark_set dtbo || die "无法写基线标记 $DT_BASELINE_MARK_FILE"
		sub "完成: $(du -h "$DTBO" | cut -f1)  $DTBO  （标记: dtbo=$DT_PLATFORM_EFF）"
	elif want dt; then
		sub "$DT_DTBO_BASE 已存在且标记属于 $DT_PLATFORM_EFF，跳过"
	fi

	# ── 5. kernel.release ─────────────────────────────────
	if [ "$need_krel" = 1 ]; then
		say "派生 $DT_KREL_FILE（取自 ramdisk 的 lib/modules/<release>）"
		[ -f "$RD" ] || die "需要先有 $RD 才能派生 release"
		KREL=$(dt_krel_derive "$RD" || true)
		[ -n "${KREL:-}" ] || die "无法从 $RD 里解出 lib/modules/<release>"
		if [ "$(cat "$KREL_F" 2>/dev/null)" = "$KREL" ]; then
			sub "release = $KREL（未变）"
		else
			echo "$KREL" > "$KREL_F"
			sub "release = $KREL（已更新）"
		fi
	elif want release; then
		sub "$DT_KREL_FILE 与 $DT_RD_BASE 一致，跳过"
	fi

	say "完成"
	status_line "$SYS" "$DT_SYSIMG"
	status_line "$RD" "$DT_RD_BASE"
	status_line "$IMG" "$DT_IMAGE"
	status_line "$DTB" "$DT_DTB_BASE"
	status_line "$DTBO" "$DT_DTBO_BASE"
	status_line "$KREL_F" "$DT_KREL_FILE"
	echo
	sub "提示：还原出来的基线来自当前 ./fw/ 里的固件包，归属记在 $DT_BASELINE_MARK_FILE。"
	sub "      换了固件包【不必加 --force】—— 标记会与新档位不符，本步骤自动重导。"

	)
}


# 一键准备构建环境（作用对齐 QPi-SDK 的 buildenv，但内容按本仓库调整）：
#   1. 定位固件包（./fw/ 下唯一一份，或 $DT_FW_DIR / config/fw_dir.txt）
#   2. 按 tools/kernel-environment/sources.lock 准备/校验 Kernel 源码与公开构建依赖
#   3. 从当前 fw 初始化/校验 Kernel 工作 config
#   4. 从 fw 导出 prebuilds/ 大基线（system.img / ramdisk / Image / dtb / dtbo / kernel.release）
#   5. 检查小清单
#   6. 检查构建与烧写工具
#
# 为什么需要：dt 不是从零构建镜像，而是在【出厂基线镜像】上原地替换模块。
# 那几个 4.8 GB 的基线不随交付包预置，构建时从 fw 现取（见 restore_baseline 函数）。
#
# 参数：
#   --check    只检查状态，不写文件
#   重新初始化 baseline 请先执行 buildclean --all（buildenv 不覆盖现有状态）
# 环境变量：
#   DT_FW_DIR=<fw目录>
_dt_kernel_config_run() {
	local mode=$1 FW=$2 profile
	if [ "$DT_PERF" = 1 ]; then profile=perf; else profile=normal; fi
	"$DT_TOOLS/kernel-config-from-fw.sh" "$mode" "$FW" \
		"$DT_ROOT/$DT_KCONFIG" "$profile" "$DT_PLATFORM_EFF"
}

_dt_meta_get() {
	local file=$1 key=$2
	sed -n "s/^$key=//p" "$file" 2>/dev/null | head -1
}

_dt_kernel_config_is_device() {
	local meta="$DT_ROOT/$DT_KCONFIG.meta"
	[ -f "$meta" ] && [ "$(_dt_meta_get "$meta" BASELINE_SOURCE)" = device ]
}

_dt_device_baseline_check() {
	"$DT_TOOLS/init-baseline-from-device.sh" --check-installed \
		--platform "$DT_PLATFORM_EFF"
}

_dt_path_exists() {
	[ -e "$1" ] || [ -L "$1" ]
}

# Classify the one current baseline. Return 0=complete, 2=absent, 1=partial.
# On success DT_BASELINE_SOURCE and DT_BASELINE_PLATFORM are exported.
_dt_current_baseline_status() {
	local normal="$DT_ROOT/config/kernel.config"
	local perf="$DT_ROOT/config/kernel.perf.config"
	local normal_meta=${normal}.meta perf_meta=${perf}.meta
	local meta config release other_config other_meta other_release profile platform source
	local any=0 p key marker
	local -a dynamic=(
		"$normal" "$normal_meta" "$perf" "$perf_meta"
		"$DT_ROOT/prebuilds/system.img" "$DT_ROOT/prebuilds/kernel.release"
		"$DT_ROOT/prebuilds/kernel.perf.release" "$DT_ROOT/prebuilds/baseline.platform"
		"$DT_ROOT/prebuilds/device-baseline.meta" "$DT_ROOT/prebuilds/Image"
		"$DT_ROOT/prebuilds/ramdisk.cpio.lz4" "$DT_ROOT/prebuilds/dtb.img"
		"$DT_ROOT/prebuilds/dtbo.img"
	)
	for p in "${dynamic[@]}"; do _dt_path_exists "$p" && any=1; done
	if [ "$any" = 0 ]; then
		DT_BASELINE_SOURCE= DT_BASELINE_PLATFORM=
		return 2
	fi

	if _dt_path_exists "$normal" || _dt_path_exists "$normal_meta"; then
		_dt_path_exists "$normal" && _dt_path_exists "$normal_meta" || return 1
		meta=$normal_meta; config=$normal; release="$DT_ROOT/prebuilds/kernel.release"
		other_config=$perf; other_meta=$perf_meta; other_release="$DT_ROOT/prebuilds/kernel.perf.release"
		profile=normal
	elif _dt_path_exists "$perf" || _dt_path_exists "$perf_meta"; then
		_dt_path_exists "$perf" && _dt_path_exists "$perf_meta" || return 1
		meta=$perf_meta; config=$perf; release="$DT_ROOT/prebuilds/kernel.perf.release"
		other_config=$normal; other_meta=$normal_meta; other_release="$DT_ROOT/prebuilds/kernel.release"
		profile=perf
	else
		return 1
	fi
	! _dt_path_exists "$other_config" && ! _dt_path_exists "$other_meta" && ! _dt_path_exists "$other_release" || return 1

	platform=$(_dt_meta_get "$meta" PLATFORM)
	source=$(_dt_meta_get "$meta" BASELINE_SOURCE)
	[ "$(_dt_meta_get "$meta" SCHEMA_VERSION)" = 1 ] || return 1
	[ "$(_dt_meta_get "$meta" PROFILE)" = "$profile" ] || return 1
	dt_platform_valid "$platform" || return 1
	if [ "$profile" = normal ]; then
		case "$platform" in *-perf) return 1 ;; esac
	else
		case "$platform" in *-perf) ;; *) return 1 ;; esac
	fi
	[ -s "$config" ] && [ -s "$release" ] && [ -s "$DT_ROOT/prebuilds/system.img" ] || return 1
	grep -qx 'CONFIG_ARM64=y' "$config" || return 1
	grep -qx 'CONFIG_IKCONFIG=y' "$config" || return 1
	marker=$(_dt_meta_get "$DT_ROOT/prebuilds/baseline.platform" system)
	[ "$marker" = "$platform" ] || return 1

	dt_platform_set_env "$platform" || return 1
	case "$source" in
	device)
		[ -s "$DT_ROOT/prebuilds/device-baseline.meta" ] || return 1
		_dt_device_baseline_check >/dev/null || return 1
		;;
	factory)
		[ ! -e "$DT_ROOT/prebuilds/device-baseline.meta" ] || return 1
		for key in FW_NAME BOOT_RELATIVE_PATH BOOT_SHA256 FACTORY_CONFIG_SHA256; do
			[ -n "$(_dt_meta_get "$meta" "$key")" ] || return 1
		done
		for key in ramdisk kernel dtb dtbo; do
			[ "$(_dt_meta_get "$DT_ROOT/prebuilds/baseline.platform" "$key")" = "$platform" ] || return 1
		done
		for p in "$DT_ROOT/prebuilds/Image" "$DT_ROOT/prebuilds/ramdisk.cpio.lz4" \
			"$DT_ROOT/prebuilds/dtb.img" "$DT_ROOT/prebuilds/dtbo.img"; do
			[ -s "$p" ] || return 1
		done
		;;
	*) return 1 ;;
	esac
	DT_BASELINE_SOURCE=$source
	DT_BASELINE_PLATFORM=$platform
	export DT_BASELINE_SOURCE DT_BASELINE_PLATFORM
	return 0
}

_dt_kernel_config_check() {
	_dt_current_baseline_status
}

_dt_buildenv_finish() {
	local check=$1 cacheval t
	cacheval=$(cat "$DT_ROOT/.tmp/platform" 2>/dev/null || true)
	if [ "$check" = 1 ]; then
		[ "$cacheval" = "$DT_PLATFORM_EFF" ] || echo "  （--check 不写 platform cache）"
	else
		dt_platform_cache_write "$DT_PLATFORM_EFF" || return 1
	fi
	_dt_show_platform
	echo
	echo "== [5/6] 检查清单与 config =="
	_dt_check_inputs || return 1
	echo
	echo "== [6/6] 检查构建与烧写工具 =="
	if command -v docker >/dev/null 2>&1; then
		printf '  ✅ %-9s: %s\n' docker "$(docker --version | cut -d, -f1)"
	else
		printf '  ❌ %-9s: %s\n' docker '找不到 —— 构建必须走容器'
	fi
	for t in adb fastboot; do
		if command -v "$t" >/dev/null 2>&1; then
			printf '  ✅ %-9s: 已安装\n' "$t"
		else
			printf '  ⚠️  %-9s: 未安装（ADB 仅在 device baseline 初始化时需要；fastboot 仅烧写时需要）\n' "$t"
		fi
	done
	if [ "$check" = 1 ]; then
		echo; echo "检查完成（--check 模式，未写文件）"
	else
		echo; echo "环境就绪 ✅"; echo "  下一步: buildall"
	fi
}

buildenv() {
	_dt_resolve_platform quiet || true
	local check=0 a
	for a in "$@"; do
		case "$a" in
		--force)
			echo "ERROR: buildenv --force 已取消；请使用 buildclean --all 后重新执行 buildenv。" >&2
			return 1
			;;
		--check) check=1 ;;
		-h | --help)
			echo "用法: buildenv [--check]"
			echo "  --check   只检查状态，不写文件"
			echo "  完整当前 baseline 会直接复用；缺失时 factory fw 优先，否则从唯一合法设备初始化。"
			echo "环境变量: DT_FW_DIR=<fw目录>"
			return 0
			;;
		*)
			echo "ERROR: buildenv 未知参数: $a（用 buildenv --help）" >&2
			return 1
			;;
		esac
	done

	echo "== [1/6] 准备 Kernel 源码与构建依赖 =="
	local prep_rc=0
	if [ "$check" = 1 ]; then
		"$DT_TOOLS/prepare-kernel-environment.sh" --check || prep_rc=$?
	else
		"$DT_TOOLS/prepare-kernel-environment.sh" || prep_rc=$?
	fi
	if [ "$prep_rc" -ne 0 ]; then
		echo "ERROR: Kernel 源码或构建依赖准备失败（rc=$prep_rc）。" >&2
		echo "       请根据上方 Component / Stage / Source 提示修复后重新执行 buildenv。" >&2
		return "$prep_rc"
	fi

	echo
	echo "== [2/6] 检查当前 baseline =="
	local baseline_rc=0
	_dt_current_baseline_status || baseline_rc=$?
	case "$baseline_rc" in
	0)
		DT_PLATFORM_SRC=baseline
		DT_PLATFORM_SRC_DESC="current $DT_BASELINE_SOURCE baseline metadata"
		export DT_PLATFORM_SRC DT_PLATFORM_SRC_DESC
		echo "  复用完整当前 baseline: $DT_BASELINE_PLATFORM ($DT_BASELINE_SOURCE)"
		_dt_buildenv_finish "$check"
		return $?
		;;
	1)
		echo "ERROR: 当前 baseline 不完整或 metadata 不一致；拒绝混用旧/新状态。" >&2
		echo "       请执行: buildclean --all" >&2
		echo "                 buildenv" >&2
		return 1
		;;
	2) echo "  当前 baseline 不存在，需要重新初始化。" ;;
	*) echo "ERROR: 无法检查当前 baseline（rc=$baseline_rc）" >&2; return 1 ;;
	esac

	# ./fw/ 里必须【恰好一份】合格固件包（本项目约定）。
	# ⚠ 这个检查必须在这里显式做：dt_platform_resolve 发现多份时会 return 1，
	#   但各 build* 都用 _dt_resolve_platform quiet 调它（免得每次单步都刷屏），
	#   于是那条错误被吞掉、档位悄悄回落到默认值，最后只在下游报出
	#   "基线导出失败" 之类 —— 让人完全猜不到根因其实是 fw/ 里多了一份包。
	local nfw
	nfw=$(_dt_pl_fw_names | wc -l)
	if [ "${nfw:-0}" -gt 1 ]; then
		echo "ERROR: $DT_ROOT/fw/ 下有 $nfw 份合格固件包 —— 本项目约定【只放一份】。" >&2
		_dt_pl_fw_names | sed 's/^/         /' >&2
		echo "       不替你猜，因为猜错就是拿别的档位的 MACHINE / 清单 / 基线去构建。" >&2
		echo "       要换档位：把旧包挪出 ./fw/，放入新包，再跑 buildenv。" >&2
		return 1
	fi

	echo "== [2/6] 选择新的 baseline 来源 =="
	# 在子 shell 里 source fw_locate.sh：fw_locate 等函数只在子 shell 生效，
	# 不污染用户当前 shell。stderr 透传（要看失败原因），stdout 用来取值。
	# 必须用 fw_locate 而不是 fw_require —— 后者失败时 exit 1，
	# 而本文件是被 source 的，会直接杀掉用户 shell。
	local FW="" baseline_mode=factory explicit_fw=0 platform_from_device=""
	[ -n "${DT_FW_DIR:-}" ] && explicit_fw=1
	local fw_cfg fw_line
	for fw_cfg in "$DT_ROOT/config/fw_dir.txt" "$DT_ROOT/../fw_dir.txt"; do
		[ -f "$fw_cfg" ] || continue
		fw_line=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' "$fw_cfg" | head -1)
		[ -n "$fw_line" ] && explicit_fw=1
	done

	if [ "${nfw:-0}" -eq 0 ] && [ "$explicit_fw" -eq 0 ]; then
		baseline_mode=device
		platform_from_device=$("$DT_TOOLS/init-baseline-from-device.sh" --print-platform) || {
			echo "ERROR: 没有可用的 factory fw、当前 baseline 或唯一合法 ADB 设备。" >&2
			echo "       请放入一份 factory firmware，或连接已验证的 M1/L1 设备后重试。" >&2
			return 1
		}
		dt_platform_valid "$platform_from_device" || {
			echo "ERROR: device baseline returned invalid platform: $platform_from_device" >&2
			return 1
		}
		dt_platform_set_env "$platform_from_device" || return 1
		DT_PLATFORM_SRC=device
		DT_PLATFORM_SRC_DESC="connected device/device baseline metadata"
		export DT_PLATFORM_SRC DT_PLATFORM_SRC_DESC
		echo "  source: connected device ($DT_PLATFORM_EFF, system-only)"
	else
		FW=$(
			export ROOT="$DT_ROOT"
			. "$DT_TOOLS/lib/fw_locate.sh"
			fw_locate
		) || return 1
		[ -n "$FW" ] || { echo "ERROR: fw_locate returned an empty path" >&2; return 1; }
		echo "  fw 目录: $FW"
	fi

	# 以本次实际定位到的 fw 为最终权威，重新生成整套档位派生变量后再校验
	# Kernel config。这样同一 shell 中更换 fw 时，不会让 helper 继续使用
	# source build.sh 时留下的 DT_PLATFORM_EFF / DT_KCONFIG / DT_PERF。
	if [ "$baseline_mode" = factory ]; then
		local fw_platform
		fw_platform=$(dt_platform_of_fw "$(basename "$FW")") || {
			echo "ERROR: 无法从当前固件目录名识别档位: $(basename "$FW")" >&2
			return 1
		}
		dt_platform_set_env "$fw_platform" || return 1
		DT_PLATFORM_SRC=fw
		DT_PLATFORM_SRC_DESC="./fw/$(basename "$FW")"
		export DT_PLATFORM_SRC DT_PLATFORM_SRC_DESC
	fi

	echo
	echo "== [3/6] 初始化/校验 Kernel config =="
	if [ "$baseline_mode" = device ] && _dt_kernel_config_is_device; then
		_dt_device_baseline_check || return 1
	elif [ "$baseline_mode" = device ] && [ "$check" = 1 ]; then
		"$DT_TOOLS/init-baseline-from-device.sh" --detect-only || return 1
		echo "  device baseline 尚未安装（--check 不写文件）"
	elif [ "$baseline_mode" = device ]; then
		"$DT_TOOLS/init-baseline-from-device.sh" || return 1
		_dt_resolve_platform quiet || return 1
	elif [ "$check" = 1 ]; then
		_dt_kernel_config_run check "$FW" || {
			echo "ERROR: 请先执行 buildclean --all，再重新执行 buildenv。" >&2
			return 1
		}
	else
		_dt_kernel_config_run prepare "$FW" || {
			echo "ERROR: 请先执行 buildclean --all，再重新执行 buildenv。" >&2
			return 1
		}
	fi

	# 档位落缓存 —— 后续那些【不走 buildenv】的命令（buildkernel /
	# tools/flash.sh / verify_*.sh）才能拿到同一档位，尤其在 ./fw/ 事后被删掉之后
	# （那时已无从探测，会静默落回默认档位并用错 MACHINE / 清单 / 基线）。
	# 缓存写在 .tmp/ 下，整个目录都在 .gitignore 里 —— 不会脏工作区、也不跟 git 传走。
	# --check 承诺「不写文件」，那种模式下只提示。
	local cacheval
	cacheval=$(cat "$DT_ROOT/.tmp/platform" 2>/dev/null || true)
	if [ "$check" = 1 ]; then
		[ "$cacheval" = "$DT_PLATFORM_EFF" ] ||
			echo "  （--check 不写缓存；要让后续命令也认 $DT_PLATFORM_EFF，跑一次 buildenv）"
	else
		if dt_platform_cache_write "$DT_PLATFORM_EFF"; then
			[ "$cacheval" = "$DT_PLATFORM_EFF" ] ||
				echo "  档位 $DT_PLATFORM_EFF 已记入 .tmp/platform（后续命令照它走）"
		fi
	fi
	_dt_show_platform

	echo
	echo "== [4/6] 准备 prebuilds/ system baseline =="
	local rc=0
	if [ "$baseline_mode" = device ]; then
		if _dt_kernel_config_is_device; then
			_dt_device_baseline_check || rc=1
		elif [ "$check" = 1 ]; then
			echo "  device baseline 尚未安装"
		else
			rc=1
		fi
	elif [ "$check" = 1 ]; then
		restore_baseline --check || rc=1
	else
		restore_baseline || rc=1
	fi
	[ "$rc" = 0 ] || {
		echo "ERROR: baseline 准备失败" >&2
		return 1
	}
	if [ "$check" != 1 ]; then
		_dt_current_baseline_status || {
			echo "ERROR: 新 baseline 建立后完整性校验失败；请执行 buildclean --all 后重试。" >&2
			return 1
		}
	fi

	# 统一名改造后，旧命名的（Image.200e-debian / system.200e-debian.img 等）
	# 不再被引用，顺手清掉。只删匹配旧模式的，新名字显式排除（见 platforms.sh）。
	local _pruned
	_pruned=$(dt_baseline_prune_legacy)
	if [ -n "$_pruned" ]; then
		echo
		echo "== 清理旧命名基线（统一名后不再引用）=="
		printf '  %s\n' $_pruned
	fi

	echo
	echo "== [5/6] 检查清单与 config =="
	_dt_check_inputs

	echo
	echo "== [6/6] 检查构建与烧写工具 =="
	if command -v docker >/dev/null 2>&1; then
		printf '  ✅ %-9s: %s\n' docker "$(docker --version | cut -d, -f1)"
		if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null |
			grep -qx 'quectel-pi-builder:latest'; then
			printf '  ✅ %-9s: %s\n' 镜像 'quectel-pi-builder:latest 已存在'
		else
			printf '  ℹ️  %-9s: %s\n' 镜像 'quectel-pi-builder 不存在（首次构建会自动 docker.build）'
		fi
		if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
			printf '  ✅ %-9s: %s\n' 'docker组' '当前用户在组内（无需 sudo）'
		else
			printf '  ⚠️  %-9s: %s\n' 'docker组' '不在组内 —— sudo usermod -aG docker $USER 后重新登录'
		fi
	else
		printf '  ❌ %-9s: %s\n' docker '找不到 —— 构建必须走容器（宿主 make ≥4.4 与 5.15 Kbuild 不兼容）'
	fi
	for t in adb fastboot; do
		if command -v "$t" >/dev/null 2>&1; then
			printf '  ✅ %-9s: 已安装\n' "$t"
		else
			printf '  ⚠️  %-9s: 未安装（只在烧写时需要）\n' "$t"
		fi
	done

	if [ "$check" = 1 ]; then
		echo
		echo "检查完成（--check 模式，未写文件）"
		return 0
	fi

	echo
	echo "环境就绪 ✅"
	echo "  下一步: buildall"
}

# ---------------------------------------------------------------------------
# 各步骤
# ---------------------------------------------------------------------------

buildkernel() {
	_dt_resolve_platform quiet || true
	_dt_kernel_config_check || {
		echo "ERROR: 当前 baseline/config 不完整或不匹配；请先执行 buildclean --all，再运行 buildenv。" >&2
		return 1
	}
	_dt_step build-kernel.sh "$@"
}

buildmenuconfig() {
	_dt_resolve_platform || return 1
	if [ "${DT_PLATFORM_SRC:-default}" = default ]; then
		echo "ERROR: 档位未能确认，拒绝编辑默认档位对应的内核配置。" >&2
		echo "       请先放入目标档位固件包并执行 buildenv，再运行 buildmenuconfig。" >&2
		return 1
	fi
	_dt_kernel_config_check || {
		echo "ERROR: 当前 baseline/config 不完整或不匹配；请先执行 buildclean --all，再运行 buildenv。" >&2
		return 1
	}
	_dt_step build-menuconfig.sh "$@"
}

buildramdisk() {
	if _dt_kernel_config_is_device; then
		echo "ERROR: current device-derived baseline is system-only; buildramdisk requires an additional boot/ramdisk baseline." >&2
		return 1
	fi
	_dt_step build-ramdisk.sh "$@"
}

# buildsystem 所需的镜像工具是否可在当前环境安全使用。
# debugfs 1.45.x 写多块目录会丢条目，因此与底层脚本一致要求 >= 1.46。
_dt_buildsystem_tools_ready() {
	local t dbgver dbgmaj dbgmin

	for t in simg2img img2simg debugfs e2fsck; do
		command -v "$t" >/dev/null 2>&1 || return 1
	done

	dbgver=$(debugfs 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
	[ -n "$dbgver" ] || return 1
	dbgmaj=${dbgver%%.*}
	dbgmin=${dbgver#*.}
	dbgmin=${dbgmin%%.*}
	[ "$dbgmaj" -gt 1 ] || { [ "$dbgmaj" -eq 1 ] && [ "$dbgmin" -ge 46 ]; }
}

buildsystem() {
	local root_q docker_cmd

	if _dt_buildsystem_tools_ready; then
		_dt_step build-system.sh "$@"
		return $?
	fi

	if [ "${QPI_IN_DOCKER:-0}" = 1 ]; then
		echo "ERROR: Docker 构建环境缺少 buildsystem 所需工具，或 debugfs 版本低于 1.46。" >&2
		return 1
	fi

	echo "Host buildsystem 工具不完整或 debugfs 版本过低，自动转入 Docker..."
	[ -x "$DT_ROOT/docker_env/build.sh" ] || {
		echo "ERROR: 找不到 Docker 构建入口: $DT_ROOT/docker_env/build.sh" >&2
		return 1
	}

	printf -v root_q '%q' "$DT_ROOT"
	docker_cmd="export QPI_IN_DOCKER=1; cd $root_q || exit 1; . ./build.sh >/dev/null || exit 1; buildsystem"
	"$DT_ROOT/docker_env/build.sh" "$docker_cmd"
}

# 把 out-modules/kernel/*.ko 按内核源码里的 modules.list 分成两段：
#   stage/first/*.ko   -> 打进 initramfs（boot.img）
#   stage/second/*.ko  -> 打进 system.img
# 划分依据来自内核源码清单（= Yocto 的 KERNEL_MODULES_LIST）：
#   在清单里 = first-stage，否则 = second-stage
buildstage() {
	_dt_resolve_platform quiet || true
	local LIST="$DT_ROOT/kernel/msm-kernel/modules.list.msm.bengal.le"
	local STAGE="$DT_ROOT/stage"

	if [ ! -f "$LIST" ]; then
		echo "ERROR: 缺少 $LIST，请先跑 ./tools/maintenance/sync_kernel.sh" >&2
		return 1
	fi

	# 必须确保清空成功：旧文件残留会让 stage/first 混入过期模块，
	# 而 buildramdisk 只按 basename 覆盖 —— 混进的旧模块会被打进 initramfs。
	# （原 stage_modules.sh 靠 set -e 兜底；这里是函数，必须显式判错。）
	if ! rm -rf "$STAGE"; then
		echo "ERROR: 无法清空 $STAGE（多为容器以 root 建过，属主不对）" >&2
		echo "       先执行: sudo rm -rf $STAGE" >&2
		return 1
	fi
	mkdir -p "$STAGE/first" "$STAGE/second" || return 1

	# 去掉注释和空行（与 Yocto recipe 的 sed -e '/^ *#/d;/^ *$/d' 等价）
	local first_list
	first_list=$(sed -e '/^[[:space:]]*#/d;/^[[:space:]]*$/d' "$LIST")

	local n_first=0 n_second=0 ko name
	for ko in "$DT_ROOT"/out-modules/kernel/*.ko; do
		[ -f "$ko" ] || continue
		name=$(basename "$ko")
		if printf '%s\n' "$first_list" | grep -qxF "$name"; then
			cp -f "$ko" "$STAGE/first/$name"  || return 1
			n_first=$((n_first + 1))
		else
			cp -f "$ko" "$STAGE/second/$name" || return 1
			n_second=$((n_second + 1))
		fi
	done

	echo "======================================================"
	echo " first-stage  (-> initramfs) : $n_first 个"
	echo " second-stage (-> system.img): $n_second 个"
	echo "======================================================"

	# 清单里列了但没编出来的（正常，清单是通用的，含别的平台模块）
	local missing
	missing=$(comm -23 <(printf '%s\n' "$first_list" | sort -u) \
	                   <(ls "$STAGE/first" 2>/dev/null | sort -u) | tr '\n' ' ')
	if [ -n "$missing" ]; then
		echo "提示: 清单中以下模块本次未编译出来（通常是别的平台/未启用）："
		printf '  %s\n' $missing
	fi

	echo
	echo "first  -> $STAGE/first  ($(du -sh "$STAGE/first" | cut -f1))"
	echo "second -> $STAGE/second ($(du -sh "$STAGE/second" | cut -f1))"
}

# 检查 modules.list + config 是否齐全。config 已由当前 fw 初始化并完成身份校验；
# 被 buildenv 的 [3/4] 与 buildall 的前置检查共用。
# 返回 1 表示有缺失（并已打印补齐办法）。
_dt_check_inputs() {
	local f missing=0
	for f in kernel/msm-kernel/modules.list.msm.bengal.le \
		$DT_KCONFIG; do
		if [ -f "$DT_ROOT/$f" ]; then
			printf '  ✅ %s\n' "$f"
		else
			printf '  ❌ %s  缺失\n' "$f"
			missing=1
		fi
	done
	# kernel release 单独判：它是【派生态】（由 fw 的 ramdisk 派生，见 restore_baseline），
	# 不属于下面那条"来自主仓库出包产物"的补法。--check 模式不写文件，所以这里
	# 用 dt_krel_get（落盘值 → 没有就从 ramdisk 现推）而不是查文件是否存在。
	local krel_now
	krel_now=$(dt_krel_get || true)
	if [ -n "$krel_now" ]; then
		printf '  ✅ %s = %s\n' "$DT_KREL_FILE" "$krel_now"
	else
		printf '  ❌ %s  缺失，且无法从 %s 派生\n' "$DT_KREL_FILE" "$DT_RD_BASE"
		missing=1
	fi
	if [ "$missing" = 1 ]; then
		echo
		echo "  上面缺少内核构建所需的 config/modules 清单；config 请由 buildenv 从当前 fw 初始化。"
		return 1
	fi
	return 0
}

# buildall 的前置检查 —— 必须在 buildkernel 【之前】跑完。
#
# 为什么需要：在编译前先确认当前档位、system baseline、
# modules.list、kernel config 和原厂 kernel release，避免编译完才在镜像阶段失败。
#
# 更危险的还不是慢，而是【档位会静默落回默认值】：./fw/ 空 + 无 .tmp/platform
# 时 dt_platform_resolve 返回 0（不报错），给出 $DT_PLATFORM_DEFAULT。于是可能
# 拿另一个档位的 MACHINE / 内核 config（perf 轴）/ DT 清单编出一份错的固件，
# 全程没有任何提示。这比缺文件危险得多，所以这里【拒绝】按兜底档位构建。
_dt_buildall_precheck() {
	_dt_resolve_platform quiet || true

	if [ "${DT_PLATFORM_SRC:-default}" = default ]; then
		echo >&2
		echo "ERROR: 档位没能探测出来，只剩默认值 $DT_PLATFORM_DEFAULT 兜底 —— 拒绝按它构建。" >&2
		echo "       档位 = <SoC>-<rootfs>[-perf]，只由 ./fw/ 里那份固件包决定；" >&2
		echo "       而 ./fw/ 里没有合格固件包，$DT_ROOT/.tmp/platform 也没有缓存。" >&2
		echo "       若拿默认值硬编，可能用【别的档位】的 MACHINE / 内核 config / DT 清单" >&2
		echo "       产出一份错的固件，且全程无提示 —— 所以不替你猜。" >&2
		echo >&2
		echo "   怎么办：" >&2
		echo "     ① 放入目标档位的固件包（./fw/ 里【只放一份】，放哪份就是哪个档位）：" >&2
		echo "          mkdir -p $DT_ROOT/fw" >&2
		echo "          cp -a /path/to/QSM200U*BD01* 或 QSM200E*BL01*_perf 等  $DT_ROOT/fw/" >&2
		echo "        然后先跑 buildenv 导出 system 基线和原厂 kernel release，再跑 buildall。" >&2
		echo "     ② 之前跑过 buildenv 但 .tmp/platform 被删了：把 fw 放回去再跑一次" >&2
		echo "          ./build.sh buildenv" >&2
		echo >&2
		echo "   想先看当前状态（不写任何文件）：./build.sh buildenv --check" >&2
		return 1
	fi

	_dt_kernel_config_check || {
		echo "ERROR: 当前 baseline/config 不完整或不匹配；请先执行 buildclean --all，再运行 buildenv。" >&2
		return 1
	}

	echo
	echo "== 前置检查 [1/2] system 基线（缺了就从 ./fw/ 现取）=="
	restore_baseline --only system || {
		echo >&2
		echo "ERROR: system 基线没能就位 —— 见上面报错（多半是 ./fw/ 里没放固件包）。" >&2
		return 1
	}

	echo
	echo "== 前置检查 [2/2] 清单与 config =="
	_dt_check_inputs || {
		echo >&2
		echo "ERROR: 上面有缺失 —— 补齐后再跑 buildall。" >&2
		return 1
	}

	echo
	echo "  前置检查通过：档位 $DT_PLATFORM_EFF（来源：$DT_PLATFORM_SRC_DESC）"
	echo "                system 基线 / 清单 / config / 原厂 kernel release 齐全"
	echo
	return 0
}

# 公开版主流程：编内核模块 → 分阶段 → system.img。
# 原厂 boot.img / Kernel Image / DTB / dtbo.img 保持不变；新 Image 只是编译副产物。
#
# 本仓库【只重建内核侧】：内核 Image + 内核自带模块（.ko）。
# vendor 外部模块（audio/camera/bt/video/mmrm/graphics/wlan/data…）的源码与
# 构建逻辑已移除，它们在镜像里保持出厂版本不动。
buildall() {
	# 前置检查【必须】在最前面：否则会白编 10 分钟内核，或用兜底档位编出错的固件。
	# （buildkernel 里没有这些检查 —— 单独跑 buildkernel 时由它自己按需报错。）
	_dt_buildall_precheck || return 1
	_dt_banner "1/3 编译内核 (Image 副产物 + 自带模块)"
	buildkernel || return 1

	_dt_banner "2/3 按 modules.list 分第一段/第二段"
	buildstage || return 1

	_dt_banner "3/3 重打包 system.img (替换 stage/second 内核模块)"
	buildsystem || return 1

	_dt_banner "完成"
	echo "产物："
	[ -f "$DT_ROOT/out-system/system.img" ] && echo "  system.img        -> $DT_ROOT/out-system/system.img ($(du -h "$DT_ROOT/out-system/system.img" | cut -f1))"
	echo
	echo "公开版只交付 system.img；boot.img / Kernel Image / DTB / dtbo.img 使用 fw 原厂版本。"
	echo
	echo "下一步："
	echo "  设备通过 ADB 连接后，可先检查烧录计划："
	echo "    ./tools/flash.sh --dry-run"
	echo "  烧录 system.img 到当前未运行且未挂载的 system 槽："
	echo "    ./tools/flash.sh"
}

# 清理可再生输出。默认保留一套当前 baseline；--all 额外清除当前 baseline，
# 但两种模式都保留 Kernel 源码、Patch、工具链、下载 cache 和静态清单。
buildclean() {
	local -a targets=()
	local rel target parent bad entry all=0 arg
	local preflight_failed=0
	for arg in "$@"; do
		case "$arg" in
		--all) all=1 ;;
		-h|--help)
			echo "用法: buildclean [--all]"
			echo "  默认    只清理 build outputs，保留当前 firmware/device baseline"
			echo "  --all   同时清理当前 baseline；切换固件、板型、OS 或 profile 时使用"
			return 0 ;;
		*) echo "ERROR: buildclean 未知参数: $arg" >&2; return 1 ;;
		esac
	done
	local -a fixed_targets=(
		out-kernel
		out-modules
		stage
		out-system
		out-ramdisk
		.scratch
		boot.img
		dtbo.img
		boot.img.nonsecure
		boot.img.sha256
		boot.img.sig
		boot.img.sig.padded
		boot.img.secure
	)
	if [ "$all" = 1 ]; then
		fixed_targets+=(
			config/kernel.config
			config/kernel.config.meta
			config/kernel.perf.config
			config/kernel.perf.config.meta
			prebuilds/system.img
			prebuilds/kernel.release
			prebuilds/kernel.perf.release
			prebuilds/baseline.platform
			prebuilds/device-baseline.meta
			prebuilds/Image
			prebuilds/ramdisk.cpio.lz4
			prebuilds/dtb.img
			prebuilds/dtbo.img
			.tmp/platform
		)
	fi

	# 目标只能由上面的固定相对路径组成。
	for rel in "${fixed_targets[@]}"; do
		target="$DT_ROOT/$rel"
		case "$target" in
			"$DT_ROOT"/*) ;;
			*) echo "ERROR: 拒绝清理仓库外路径: $target" >&2; return 1 ;;
		esac
		[ -e "$target" ] || [ -L "$target" ] || continue
		targets+=("$target")
	done
	for target in "$DT_ROOT"/dtbo.img.tmp.*; do
		[ -e "$target" ] || [ -L "$target" ] || continue
		targets+=("$target")
	done

	if [ "$all" = 1 ]; then
		echo "=== 清理构建产物和当前 baseline ==="
	else
		echo "=== 清理构建产物（保留当前 baseline）==="
	fi

	# 先检查全部目标，任意一处无权限就不开始删除，避免半清理状态。
	for target in "${targets[@]}"; do
		parent=$(dirname "$target")
		if [ ! -w "$parent" ] || [ ! -x "$parent" ]; then
			echo "ERROR: 无法安全删除（父目录不可写/不可进入）: $target" >&2
			stat -c '       target owner=%U:%G mode=%A path=%n' -- "$target" >&2 2>/dev/null || true
			stat -c '       parent owner=%U:%G mode=%A path=%n' -- "$parent" >&2 2>/dev/null || true
			preflight_failed=1
			continue
		fi

		if [ -d "$target" ] && [ ! -L "$target" ]; then
			bad=$(find "$target" -type d \( ! -readable -o ! -writable -o ! -executable \) -print 2>&1) || {
				echo "ERROR: 无法完整检查清理目标: $target" >&2
				[ -z "$bad" ] || printf '       %s\n' "$bad" >&2
				stat -c '       owner=%U:%G mode=%A path=%n' -- "$target" >&2 2>/dev/null || true
				preflight_failed=1
				continue
			}
			if [ -n "$bad" ]; then
				echo "ERROR: 目标内存在不可安全清理的目录: $target" >&2
				while IFS= read -r entry; do
					stat -c '       owner=%U:%G mode=%A path=%n' -- "$entry" >&2 2>/dev/null || \
						printf '       path=%s\n' "$entry" >&2
				done <<< "$bad"
				preflight_failed=1
			fi
		fi
	done

	if [ "$preflight_failed" != 0 ]; then
		echo "ERROR: 权限预检失败，未删除任何构建产物。" >&2
		return 1
	fi

	for target in "${targets[@]}"; do
		rel=${target#"$DT_ROOT"/}
		echo "清理 $rel$([ -d "$target" ] && [ ! -L "$target" ] && printf /)"
		rm -rf -- "$target" || {
			echo "ERROR: 清理失败: $target" >&2
			return 1
		}
	done

	echo "buildclean 完成"
	if [ "$all" = 1 ]; then
		echo "已清除当前 baseline/config/platform；Kernel 源码、6 Patch、工具链、下载 cache 和静态清单均保留"
		echo "请放入目标 fw，或连接已验证的设备，再执行 buildenv"
	else
		echo "已保留当前 firmware/device baseline、Kernel 工作 config 和 platform metadata"
		echo "可直接执行 buildenv 复用当前 baseline"
	fi
}

# ---------------------------------------------------------------------------
# 帮助 / 分发
# ---------------------------------------------------------------------------

# 打印当前档位与全部相关文件路径。由 buildenv 在探测完成后调用。
#
# ⚠ 这里【没有】"手工设档位"的入口，是有意的：
#    · 档位由 buildenv 从 ./fw/ 里的固件包名认出，并记入 .tmp/platform（本机缓存）
#    · 也没有环境变量覆盖 —— 档位只由 ./fw/ 里那份包决定
#    原先那个 `platform set <档位>` 会把结果写进【被 git 跟踪】的 config/platform，
#    而它的内容其实取决于本机 fw/ 里临时放的那份包（fw/ 本身是 gitignore 的）——
#    自动写被跟踪的文件 = 每次 buildenv 都脏一次工作区，还容易被误提交。
_dt_show_platform() {
	local q
	echo
	echo "档位：$DT_PLATFORM_EFF   = $DT_SOC / $(dt_platform_desc "$DT_PLATFORM_EFF")"
	# 档位【来源】必须显式打出来：只看"档位=200u-debian"分不清这是真探测到的，
	# 还是 ./fw/ 空 + 无缓存时的默认值兜底 —— 后者会让 buildall 拒绝启动。
	# ⚠ 这里用 echo 而不是 sub —— sub/say/die 是 restore_baseline 子 shell 里的
	#   局部函数，本函数（以及 buildhelp）都在它们的作用域之外，调不到。
	echo "  来源               : $DT_PLATFORM_SRC_DESC"
	if [ "${DT_PLATFORM_SRC:-default}" = default ]; then
		echo "  ⚠ 这是【默认值兜底】，不是探测结果：./fw/ 里没有合格固件包，也没有"
		echo "     .tmp/platform 缓存。buildall 会拒绝按它构建 —— 放好固件包再跑。"
	fi
	echo "  轴                 : SoC=$DT_SOC  rootfs=$DT_ROOTFS  perf=$DT_PERF"
	echo "  Yocto MACHINE      : $DT_MACHINE"
	echo "  fw 包名            : ${DT_FW_PATTERN}${DT_FW_EXCLUDE:+   （排除 ${DT_FW_EXCLUDE}）}"
	echo "  ramdisk 名         : fw 内 $DT_RD_NAME / 基线 $DT_RD_BASE"
	echo "  内核 config        : $DT_KCONFIG"
	echo "  kernel release 文件: $DT_KREL_FILE"
	# 统一名之后，光看路径不知道这份基线是谁的 —— 把归属一起打出来
	local _m
	_m=$(dt_baseline_mark_file)
	if [ -f "$_m" ]; then
		echo "  基线归属标记       : ${_m#"$DT_ROOT/"}  [$(tr '\n' ' ' < "$_m" | sed 's/ $//')]"
	else
		echo "  基线归属标记       : ${_m#"$DT_ROOT/"}  （还没有 —— 基线尚未导出）"
	fi
	echo "  system.img 基线    : $DT_SYSIMG"
	echo "  Image 基线         : $DT_IMAGE"
	echo "  其它可选档位（8 个）："
	for q in $DT_PLATFORMS; do
		[ "$q" = "$DT_PLATFORM_EFF" ] && continue
		printf '    %-20s %s\n' "$q" "$(dt_platform_desc "$q")"
	done
}

buildhelp() {
	echo ""
	echo "============================================================"
	echo "  dt 仓库构建系统  |  档位 $DT_PLATFORM_EFF -> $DT_MACHINE"
	echo "            $DT_PLATFORM_EFF = $(dt_platform_desc "$DT_PLATFORM_EFF")"
	if [ "${DT_PLATFORM_SRC:-default}" = default ]; then
		echo "  ⚠⚠ 上面这个档位是【默认值兜底】—— ./fw/ 里没有固件包、也没有缓存。"
		echo "      buildall 会拒绝按它构建（猜错档位 = 编出错的固件）。"
		echo "      放好固件包：cp -a <固件包> $DT_ROOT/fw/  然后重跑本命令。"
	fi
	echo "============================================================"
	echo "  用法: source build.sh 后直接输入以下命令"
	echo ""
	echo "  ── 应用开发（Docker ARM64 GNU C/C++）──"
	echo "    newapp <名称> [模板]   从模板创建应用（从模板创建应用（V1 仅提供 hello 基础 C/C++ 模板））"
	echo "    buildapp <目录>        在 Docker 中交叉编译（CMake 优先，其次 Makefile）"
	echo ""
	echo "  ── 档位（8 个，不必手工选）──"
	echo "    200u-debian   200u-debian-perf   200u-linux   200u-linux-perf"
	echo "    200e-debian   200e-debian-perf   200e-linux   200e-linux-perf"
	echo "    buildenv 优先复用完整当前 baseline；重新初始化时先用唯一 factory fw，"
	echo "    没有 factory fw 才从唯一合法 ADB 设备识别档位并建立 device baseline。"
	echo "    ./fw/ 里【只允许放一份】合格固件包；放两份 buildenv 直接报错。"
	echo ""
	echo "  ── 环境准备 ──"
	echo "    buildenv               准备/复用 Kernel 工具 → 复用或初始化当前 baseline → 检查"
	echo "                           (别名 setenv; --check 只看状态不写文件)"
	echo "    restore_baseline       只做导出（buildenv 的第 4 步）"
	echo "                           --only system|ramdisk|kernel|dt|release"
	echo ""
	echo "  ── 一键 ──"
	echo "    buildall               公开版: 内核模块 → 分阶段 → system.img"
	echo "                           (Image 只是副产物；不重建 boot.img / dtbo.img)"
	echo ""
	echo "  ── 单步 ──"
	echo "    buildmenuconfig        交互修改当前档位的完整内核配置（需终端 TTY）"
	echo "    buildkernel            编内核 → Image(副产物) + out-modules/kernel/*.ko"
	echo "    buildstage             按 modules.list 分第一段/第二段 → stage/"
	echo "    buildsystem            用 stage/second 重打包 system.img → out-system/system.img"
	echo "    buildramdisk           保留的单步接口（不进入公开 buildall）"
	echo ""
	echo "  ── 资源 ──"
	echo "    tools/maintenance/sync_kernel.sh  从主仓库同步内核源码与 $DT_KCONFIG"
	echo ""
	echo "  ── 其他 ──"
	echo "    buildclean             只清理 build outputs；保留当前 firmware/device baseline"
	echo "    buildclean --all       清理 build outputs 和当前 baseline；切换固件/板型/OS/profile 时使用"
	echo "                           两者都保留 Kernel 源码、6 Patch、工具链和下载 cache"
	echo ""
	echo "  ── 非交互（容器）──"
	echo "    ./docker_env/build.sh \". build.sh; buildall\""
	echo "  ── 交互（容器）──"
	echo "    ./docker_env/build.sh --interactive \". build.sh; buildmenuconfig\""
	echo "============================================================"
	echo ""
}

if _dt_build_is_sourced; then
	buildhelp
else
	cmd="${1:-help}"
	shift || true
	case "$cmd" in
		newapp|new)                newapp       "$@" ;;
		buildapp|app)              buildapp     "$@" ;;
		restore|restore_baseline)  restore_baseline "$@" ;;
		env|buildenv|setenv)       buildenv      "$@" ;;
		all|buildall)              buildall      "$@" ;;
		menuconfig|buildmenuconfig) buildmenuconfig "$@" ;;
		kernel|buildkernel)        buildkernel   "$@" ;;
		stage|buildstage)          buildstage    "$@" ;;
		ramdisk|buildramdisk)      buildramdisk  "$@" ;;
		system|buildsystem)        buildsystem   "$@" ;;
		clean|buildclean)          buildclean    "$@" ;;
		help|--help|-h)            buildhelp ;;
		*) echo "ERROR: unknown command: $cmd" >&2; buildhelp; exit 1 ;;
	esac
fi
