#!/bin/bash
#
# platforms.sh —— SDK 支持的平台档位表（被 build.sh / tools/*.sh source）
#
# ★ 档位 = <SoC>-<rootfs>[-perf]，共 8 个
#
#     <SoC>     200u = SC200U / SM6115 / bengal        （Yocto MACHINE sm6115-mtp）
#               200e = SC200E / QCM2290 / scuba-iot     （Yocto MACHINE qcm2290-mtp）
#     <rootfs>  debian = 带 Debian rootfs（poky/meta-quectel-debian 在 bblayers 里）
#               linux  = 纯 Yocto rootfs（bitbake-layers remove-layer meta-quectel-debian）
#     -perf     带 = DISTRO=qti-distro-fullstack-perf
#               不带 = DISTRO=qti-distro-fullstack-debug
#
#     200u-debian  200u-debian-perf  200u-linux  200u-linux-perf
#     200e-debian  200e-debian-perf  200e-linux  200e-linux-perf
#
#   为兼容旧写法，裸 200u / 200e 等价于 200u-debian / 200e-debian。
#
# ★ 每个轴到底影响什么（**实测**，来源见文件末尾「实测依据」）
#
#   | 受影响的东西                        | SoC | rootfs | perf |
#   |------------------------------------|-----|--------|------|
#   | Yocto MACHINE / deploy 目录名        | ✅  |        |      |
#   | initramfs 文件名                     | ✅  |        |      |
#   | fw 包名 BD01 / BL01 标记             |     | ✅     |      |
#   | fw 包名 _perf 后缀                   |     |        | ✅   |
#   | Yocto 出包目录名 build-qti-distro-…-{debug,perf} |  |    | ✅   |
#   | prebuilds/ramdisk.cpio.lz4（内容三者都不同）| ✅  | ✅  | ✅   |
#   | kernel out 目录名 …bengal_le{gki,-consolidate}   |  |    | ✅   |
#   | config/kernel[.perf].config          |     |        | ✅   |
#   | kernel release（/lib/modules/<名>）  |     |        | ✅   |
#   | /opt/quectel/*.ko 有没有             |     | ✅     |      |
#   | system.img 体积（4.6G vs 982M）      |     | ✅     |      |
#
#   两平台/两 rootfs/两 perf 之间可共用的源码与构建框架：
#     - 内核源码树 kernel/              两平台共用公开 Linux Kernel 与 DT 基础设施
#     - 内核源码内容                    kernel_platform 77200 个文件 0 差异（仅 defconfig 清单漂移）
#     - modules.list.msm.bengal.le     相同（不另存副本，直接读 kernel/msm-kernel/）
#     - build.config.msm.bengal.le     相同（bengal_le 家族同时覆盖 bengal/scuba）
#     - LTO                            两边都是 CONFIG_LTO_CLANG_FULL=y
#     - fw 里的 boot/dtbo/system 分区大小 98304/98304/24576/24576/8388608 KB 全同
#
# ★ 文件命名：带哪个后缀，取决于内容【真的随哪个轴变】
#   （派生变量见 dt_platform_set_env；调用方一律用变量，别自己拼文件名）
#
#   带【档位】后缀 —— 内容确实每档位都不同：
#     prebuilds/Image                               (DT_IMAGE)
#     prebuilds/system.img                          (DT_SYSIMG)
#     prebuilds/ramdisk.cpio.lz4                    (DT_RD_BASE)
#     prebuilds/.system.raw                         (DT_TMPRAW)
#     ↑ 这四个【统一名、不带档位】—— 归属由 prebuilds/baseline.platform 记录，
#       判定必须查标记，不能只看文件存在性（见 dt_baseline_ok）。
#
#   只带【perf】轴 —— 8 档位只有 2 份：
#     config/kernel[.perf].config               (DT_KCONFIG)
#     prebuilds/kernel[.perf].release           (DT_KREL_FILE)
#     ⚠ config 是【用户会手改的文件】，绝不能按档位复制 8 份 ——
#       那样改了不生效，而且极难查。
#
#   不带轴 —— 名字由其它东西决定：
#     prebuilds/qti-ramdisk-image-<MACHINE>.cpio.lz4
#        这是 fw/boot.img 里的【原始名】(DT_RD_NAME)，只由 MACHINE 决定；
#        同 SoC 的 4 个档位会撞名，而实测内容确实不同（200e-debian 与
#        200e-linux 的 cpio 条目 1847 vs 1850、同名模块大小不一；perf 档连
#        lib/modules/<release> 都从 5.15.180-gki-consolidate 变成 5.15.180）。
#        所以【基线副本】必须用带档位后缀的 DT_RD_BASE，两者别混用 ——
#        否则第二个档位会命中「已存在 → 跳过」，静默用错档位的 ramdisk。
#
# ★ 档位怎么定 —— 只有这三处来源，【没有环境变量入口】
#   1) 从 ./fw/ 里那份合格固件包名反推
#      （要求含 rawprogram_unsparse0.xml —— 那些 _debug/_debugimg/_ota 子包会被自动排除）
#   2) .tmp/platform 缓存      —— buildenv 探测到 fw 后自动落一行
#   3) 默认档位 $DT_PLATFORM_DEFAULT
#
#   ⚠ 为什么【不】支持用环境变量指定档位：
#     档位本来就由 ./fw/ 里那份包唯一决定（本项目约定 ./fw/ 只放一份）。
#     再加一个覆盖入口只会制造「env 说 A、fw 说 B」的分裂。实测踩过一次：
#     自己 export 的 DT_PLATFORM 被当成了下一轮的"用户输入"，于是换了 fw 包也
#     不会重新探测、.tmp/platform 缓存形同虚设，报错还提示"重跑 buildenv"，
#     而重跑多少次都没用。
#     要换档位就【换 ./fw/ 里的包】，然后跑一次 buildenv。
#     环境里若还留着老的 $DT_PLATFORM，dt_platform_resolve 会 WARN 提醒已被忽略。
#
#   生效档位存在 $DT_PLATFORM_EFF（各脚本一律读它），与用户可能残留的
#   $DT_PLATFORM 严格分开，避免"自己 export 的值回流成输入"。
#
#   为什么 fw 比缓存优先：缓存本来就是【从 fw 推出来的】，fw 才是物理事实。
#   换了 fw 包却还拿旧缓存，等于拿别的档位的 MACHINE / 清单 / 基线去构建。
#
#   ⚠ 缓存为什么必须有（而不是纯靠 fw）：
#     ./fw/ 是几 GB 的临时目录、经常被删。删掉之后 buildkernel /
#     tools/flash.sh / verify_*.sh 这些【不走 buildenv】的命令就无从判断档位，会静默
#     落回默认档位 → 用错 MACHINE、错 DT 清单、错基线，而且很难查。
#     所以 buildenv 一旦认出档位就把结果记进 .tmp/platform，后续命令照它走。
#
#   注意：.tmp/ 整个在 .gitignore 里，所以缓存是【本机行为】——
#        不会跟着 git 传给下一个人，也不会让工作区变脏。
#
#   ⚠ ./fw/ 里【只允许放一份】固件包（本项目约定）。放两份时 buildenv 会直接报错，
#     不会替你猜 —— 见 dt_platform_resolve 的分支与 tools/lib/fw_locate.sh。
#

DT_PLATFORMS="200u-debian 200u-debian-perf 200u-linux 200u-linux-perf
              200e-debian 200e-debian-perf 200e-linux 200e-linux-perf"
DT_PLATFORM_DEFAULT=200u-debian

# ---------------------------------------------------------------------------
# 轴解析
# ---------------------------------------------------------------------------

# dt_platform_norm <档位> -> 规范化档位名（裸 200u/200e 补成 -debian）
dt_platform_norm() {
	case "${1:-}" in
	200u) echo "200u-debian" ;;
	200e) echo "200e-debian" ;;
	"") return 1 ;;
	*) echo "$1" ;;
	esac
}

# dt_platform_soc <档位> -> 200u | 200e
dt_platform_soc() {
	case "$(dt_platform_norm "$1")" in
	200u-*) echo "200u" ;;
	200e-*) echo "200e" ;;
	*) return 1 ;;
	esac
}

# dt_platform_rootfs <档位> -> debian | linux
dt_platform_rootfs() {
	case "$(dt_platform_norm "$1")" in
	*-debian*) echo "debian" ;;
	*-linux*) echo "linux" ;;
	*) return 1 ;;
	esac
}

# dt_platform_perf <档位> -> 1 | 0
dt_platform_perf() {
	case "$(dt_platform_norm "$1")" in
	*-perf) echo 1 ;;
	*-debian | *-linux) echo 0 ;;
	*) return 1 ;;
	esac
}

# dt_platform_fwpfx <SoC> -> fw 包名前缀
dt_platform_fwpfx() {
	case "$1" in
	200u) echo "QSM200U" ;;
	200e) echo "QSM200E" ;;
	*) return 1 ;;
	esac
}

# dt_platform_machine <档位> -> Yocto MACHINE 名（也用于 ramdisk 文件名/deploy 目录）
dt_platform_machine() {
	local soc
	soc=$(dt_platform_soc "$1") || return 1
	case "$soc" in
	200u) echo "sm6115-mtp" ;;
	200e) echo "qcm2290-mtp" ;;
	esac
}

# dt_platform_fwpat <档位> -> fw 包名【必须】匹配的 glob
#   rootfs 决定 BD01 / BL01；perf 决定带不带 _perf 后缀。
dt_platform_fwpat() {
	local k soc rootfs perf pfx tag
	k=$(dt_platform_norm "$1") || return 1
	soc=$(dt_platform_soc "$k") || return 1
	rootfs=$(dt_platform_rootfs "$k") || return 1
	perf=$(dt_platform_perf "$k") || return 1
	pfx=$(dt_platform_fwpfx "$soc") || return 1
	case "$rootfs" in
	debian) tag=BD01 ;;
	linux) tag=BL01 ;;
	*) return 1 ;;
	esac
	if [ "$perf" = 1 ]; then
		printf '%s*%s*_perf*\n' "$pfx" "$tag"
	else
		printf '%s*%s*\n' "$pfx" "$tag"
	fi
}

# dt_platform_fwexcl <档位> -> fw 包名【必须不】匹配的 glob（空 = 不排除）
#   非 perf 档必须排掉 _perf*，否则 QSM200U*BD01* 会连 DEB_PERF 的包一起匹配上。
dt_platform_fwexcl() {
	local perf
	perf=$(dt_platform_perf "$1") || return 1
	[ "$perf" = 1 ] || printf '*_perf*\n'
}

# dt_platform_desc <档位> -> 人类可读描述
dt_platform_desc() {
	local k soc rootfs perf d r pf
	k=$(dt_platform_norm "$1") || {
		echo "未知档位"
		return 0
	}
	soc=$(dt_platform_soc "$k") || {
		echo "未知档位"
		return 0
	}
	rootfs=$(dt_platform_rootfs "$k")
	perf=$(dt_platform_perf "$k")
	case "$soc" in
	200u) d="SC200U / SM6115 / bengal" ;;
	200e) d="SC200E / QCM2290 / scuba-iot" ;;
	esac
	case "$rootfs" in
	debian) r="Debian rootfs" ;;
	linux) r="Linux rootfs" ;;
	esac
	[ "$perf" = 1 ] && pf="perf" || pf="debug"
	echo "$d / $r / $pf"
}

# dt_platform_of_fw <fw目录名或路径> -> 档位（认不出则返回 1）
dt_platform_of_fw() {
	local b soc rootfs perf=""
	b=$(basename "${1%/}")
	case "$b" in
	QSM200U*) soc=200u ;;
	QSM200E*) soc=200e ;;
	*) return 1 ;;
	esac
	case "$b" in
	*BD01*) rootfs=debian ;;
	*BL01*) rootfs=linux ;;
	*) return 1 ;;
	esac
	case "$b" in
	*_perf*) perf="-perf" ;;
	esac
	echo "$soc-$rootfs$perf"
}

# dt_platform_valid <档位> -> 0/1（裸 200u/200e 也认）
dt_platform_valid() {
	local k q
	k=$(dt_platform_norm "${1:-}") || return 1
	for q in $DT_PLATFORMS; do
		[ "$q" = "$k" ] && return 0
	done
	return 1
}

# dt_platform_set_env <档位> —— 把【生效档位】及其所有派生变量赋到当前 shell 并 export。
#
# 生效档位写在 $DT_PLATFORM_EFF（各脚本、各显示信息一律读它）。
#
# ⚠⚠ 本函数【故意不写 DT_PLATFORM】，而且 dt_platform_resolve 也不再读它。
#    DT_PLATFORM 这个环境变量在【整个仓库里都没有入口】了 —— 档位只由
#    ./fw/ 里那份固件包决定（理由见文件头部）。环境里若残留它，resolve 会 WARN。
#
#    为什么当初要拆出 _EFF（踩过的坑，2026-09-17 实测，供后人别再改回去）：
#      一开始 set_env 直接写并 export DT_PLATFORM，而 resolve 第 1 步又让
#      $DT_PLATFORM 优先级最高 —— 于是【自己 export 的值成了下一轮的"输入"】。
#      后果：`source build.sh` 之后档位被钉死，同一 shell 里把 ./fw/ 换成另一个
#      档位的包也【永远不会重新探测】，.tmp/platform 缓存形同虚设；报错还提示
#      "重跑 buildenv"，而重跑多少次都一样。
#      根治办法就是【根本不要环境变量入口】，让 fw 成为唯一判据；
#      _EFF 这个名字则保证"算出来的值"永远不可能被误当输入。
#
# 【不要用 eval / printf %q 那套】：DT_FW_PATTERN 里含 glob 的 *，
# 经 %q 转义后再 eval 会把星号变成字面量。
dt_platform_set_env() {
	local k perfsfx
	k=$(dt_platform_norm "$1") || return 1
	DT_PLATFORM_EFF=$k
	DT_SOC=$(dt_platform_soc "$k") || return 1
	DT_ROOTFS=$(dt_platform_rootfs "$k") || return 1
	DT_PERF=$(dt_platform_perf "$k") || return 1
	DT_MACHINE=$(dt_platform_machine "$k") || return 1
	DT_FW_PATTERN=$(dt_platform_fwpat "$k") || return 1
	DT_FW_EXCLUDE=$(dt_platform_fwexcl "$k") || return 1
	# ⚠ 两个 ramdisk 名【必须分开】：
	#   DT_RD_NAME = fw/boot.img 里那个原始名，只由 MACHINE 决定；用来在
	#                 boot.img 里定位它，以及作为 out-ramdisk/ 的输出名。
	#   DT_RD_BASE = prebuilds/ 里的【基线副本】名，必须带档位后缀 ——
	#                 实测 200e-debian 与 200e-linux 的 ramdisk 虽同名
	#                 （qti-ramdisk-image-qcm2290-mtp.cpio.lz4），内容却不同：
	#                 模块大小不一、debian 还多一个 systemd 软链；perf 档更是
	#                 连 lib/modules/<release> 都不一样。共用一名会命中
	#                 "已存在 → 跳过"，于是静默用错档位的 ramdisk。
	DT_RD_NAME="qti-ramdisk-image-$DT_MACHINE.cpio.lz4"
	# ⚠ 这几个【基线副本】的名字【统一，不带档位】—— 身份由
	#   prebuilds/baseline.platform 这个标记文件承载（见 dt_baseline_ok 的说明）。
	#   用统一名的前提是判定必须查标记，不能只看"文件在不在"：
	#   带档位后缀时"文件存在"⇒"内容属于本档位"；统一名时这个推论【不成立】。
	DT_RD_BASE="prebuilds/ramdisk.cpio.lz4"
	DT_DRV="$DT_SOC-$DT_ROOTFS"
	if [ "$DT_PERF" = 1 ]; then perfsfx=".perf"; else perfsfx=""; fi
	DT_PERF_SFX=$perfsfx
	DT_KREL_FILE="prebuilds/kernel$perfsfx.release"
	DT_KCONFIG="config/kernel$perfsfx.config"
	DT_SYSIMG="prebuilds/system.img"
	DT_IMAGE="prebuilds/Image"
	DT_DTB_BASE="prebuilds/dtb.img"
	DT_DTBO_BASE="prebuilds/dtbo.img"
	DT_TMPRAW="prebuilds/.system.raw"
	# kernel_platform 的 out 目录名随 CONFIG_LOCALVERSION 走（实测）：
	#   非 perf -> CONFIG_LOCALVERSION="-gki-consolidate" -> msm-kernel-bengal_le-consolidate
	#   perf     -> CONFIG_LOCALVERSION=""                -> msm-kernel-bengal_le-gki
	# （200u-debian / 200e-debian / 200e-linux 都是 -consolidate，只有 perf 是 -gki）
	if [ "$DT_PERF" = 1 ]; then
		DT_KOUT="${DT_KOUT_OVERRIDE:-msm-kernel-bengal_le-gki}"
	else
		DT_KOUT="${DT_KOUT_OVERRIDE:-msm-kernel-bengal_le-consolidate}"
	fi
	export DT_PLATFORM_EFF DT_SOC DT_ROOTFS DT_PERF DT_PERF_SFX DT_MACHINE \
		DT_FW_PATTERN DT_FW_EXCLUDE DT_RD_NAME DT_RD_BASE DT_DRV DT_KOUT \
		DT_KREL_FILE DT_KCONFIG \
		DT_SYSIMG DT_IMAGE DT_DTB_BASE DT_DTBO_BASE DT_TMPRAW
	return 0
}

# ---------------------------------------------------------------------------
# 内核 release（/lib/modules/<release> 那个目录名）—— 它是个【派生态】，不是基线
# ---------------------------------------------------------------------------
# 值完全由基线 ramdisk 里的 lib/modules/<release> 目录名决定：
#     非 perf = 5.15.180-gki-consolidate   (CONFIG_LOCALVERSION="-gki-consolidate")
#     perf    = 5.15.180                   (CONFIG_LOCALVERSION="")
# 所以 prebuilds/kernel[.perf].release 【不随交付包预置】（见 .gitignore）：
#     - buildenv 的 restore_baseline 会从 ./fw/ 的 ramdisk 现推一次并落盘
#     - tools/build-kernel.sh 编完内核后会拿【新内核】的
#       out-kernel/msm-kernel/include/config/kernel.release 覆写它
#       —— 之后它就是构建产物，落盘值即权威（编过内核后不再从基线推）
# 本函数是唯一的推导实现：restore_baseline / verify_* / tools/flash.sh 都走它
# 基线一律从 fw 获取。
# 避免三份算法各写一遍后漂移。
dt_krel_derive() {
	# 仓库根用 _dt_pl_root 兜底：tools/*.sh 手跑时只有 $ROOT，没有 $DT_ROOT
	local rd=${1:-$(_dt_pl_root)/$DT_RD_BASE}
	command -v lz4 >/dev/null 2>&1 || return 1
	command -v cpio >/dev/null 2>&1 || return 1
	[ -f "$rd" ] || return 1
	lz4 -dc "$rd" 2>/dev/null |
		cpio -t --quiet 2>/dev/null |
		sed -n 's|^.*lib/modules/\([^/]*\)/.*$|\1|p' |
		sort -u | head -1
}

# 读 release：落盘值优先，落盘没有才从 ramdisk 派生，两条路都没有则返回空。
# 为什么落盘值优先 —— build-kernel.sh 编完内核后会写入【新内核】的值；此时若去
# 从基线 ramdisk 推，会得到出厂值，而当次构建未必与出厂值相同（例如改了
# CONFIG_LOCALVERSION），拿它去拼 /lib/modules 路径就会错。
dt_krel_get() {
	local f=${1:-$(_dt_pl_root)/$DT_KREL_FILE}
	if [ -s "$f" ]; then
		cat "$f"
		return 0
	fi
	dt_krel_derive
}

# ---------------------------------------------------------------------------
# prebuilds/ 基线归属标记 —— 统一文件名方案的关键
# ---------------------------------------------------------------------------
# 【为什么需要】基线副本名统一成 prebuilds/{Image,ramdisk.cpio.lz4,system.img}
# 之后，"文件存在"就不再能推出"内容属于当前档位"了：
#     带档位后缀时：只有本档位会写那个名字 ⇒ 存在即属于本档位
#     统一名时    ：任何档位都会写同一个名字 ⇒ 存在可能是【任何档位】留下的
# 于是必须另存一个"这份基线是谁的"，否则换档位后会静默拿错基线
# （实测：拿 perf 的 933M system.img 装 debian 档的模块，全程无提示）。
#
# 【格式】prebuilds/baseline.platform，一项一行 key=value：
#     system=200e-debian
#     ramdisk=200e-debian
#     kernel=200e-debian
#     dtb=200e-debian
#     dtbo=200e-debian
# 按项记录（而不是整份一个值），这样 `restore --only system` 这类【部分导出】
# 也能正确：只更新 system 那一行，其余项仍指向它们真正的档位。
#
# 【次序】先写数据、后写标记（标记是提交点）。中途失败 ⇒ 标记不更新 ⇒ 下次
# 重导。这比"导出前先清空"安全：清空后一旦失败，原本可用的基线也没了。
#
# 【fail-safe】标记缺失/读坏 ⇒ 所有项都判定为"不属于本档位" ⇒ 全部重导。
# 方向是安全的。
dt_baseline_mark_file() {
	# 优先 $DT_ROOT（build.sh 里就是仓库根，最准）；tools/*.sh 手跑时通常只有
	# $ROOT，交给 _dt_pl_root 兜底（它自己会试 $ROOT，再退回本文件所在目录的上一级）。
	echo "${DT_ROOT:-$(_dt_pl_root)}/prebuilds/baseline.platform"
}

# 读取某项的归属档位；没有则返回 1
dt_baseline_mark_get() {
	local f v
	f=$(dt_baseline_mark_file)
	[ -f "$f" ] || return 1
	v=$(sed -n "s/^$1=//p" "$f" 2>/dev/null | head -1 | tr -d '[:space:]')
	[ -n "$v" ] || return 1
	echo "$v"
}

# 记录某项的归属档位（默认当前档位）。原子替换，避免写一半留下坏标记。
dt_baseline_mark_set() {
	local f tmp t
	f=$(dt_baseline_mark_file)
	t=${2:-${DT_PLATFORM_EFF:-}}
	[ -n "$t" ] || return 1
	mkdir -p "$(dirname "$f")"
	tmp="$f.tmp.$$"
	if [ -f "$f" ]; then
		# grep -v 无匹配行时返回 1，那是正常情况（本来就没有这一项），故 || true
		grep -v "^$1=" "$f" > "$tmp" 2>/dev/null || true
	else
		: > "$tmp"
	fi
	printf '%s=%s\n' "$1" "$t" >> "$tmp"
	mv -f "$tmp" "$f"
}

# 判断某项基线是否「存在且属于当前档位」：
#   真的条件 = 文件存在 && 标记里那一项 == $DT_PLATFORM_EFF
# 调用方负责再判断"文件在不在"，见 build.sh 的 need_sys 等。
dt_baseline_ok() {
	[ -n "${DT_PLATFORM_EFF:-}" ] || return 1
	[ "$(dt_baseline_mark_get "$1" 2>/dev/null)" = "$DT_PLATFORM_EFF" ]
}

# 删掉「旧命名（带档位后缀）」留下的孤儿基线文件 —— 改名后它们不会再被引用。
# 把删掉的文件名逐行写到 stdout（调用方决定要不要显示），返回 0。
# 只删匹配旧模式的，且显式排除新名字，避免误删。
dt_baseline_prune_legacy() {
	local r f
	r=${DT_ROOT:-$(_dt_pl_root)}
	for f in "$r"/prebuilds/Image.* "$r"/prebuilds/ramdisk.*.cpio.lz4 \
		"$r"/prebuilds/system.*.img "$r"/prebuilds/.system.*.raw; do
		[ -e "$f" ] || continue
		# 保险：万一 glob 命中了新名字，跳过
		case "${f##*/}" in
		Image | ramdisk.cpio.lz4 | system.img | .system.raw) continue ;;
		esac
		rm -f "$f" && echo "${f##*/}"
	done
	return 0
}

# dt_platform_ensure —— 给 tools/*.sh 用。
# 若环境里已有（经 build.sh 的 _dt_step 或 dt_platform_set_env 导出）就直接用；
# 否则（例如直接手跑 tools/build-ramdisk.sh）就地解析一份并导出。
# 调用方需先定义 $ROOT 或 $DT_ROOT（tools/ 下脚本都会先设 ROOT）。
dt_platform_ensure() {
	[ -n "${DT_PLATFORM_EFF:-}" ] && [ -n "${DT_KREL_FILE:-}" ] && return 0
	# 直接调 impl（不要 $(...)），这样 DT_PLATFORM_SRC 也留着
	_dt_platform_resolve_impl || return 1
	dt_platform_set_env "$DT_PLATFORM_EFF"
}

# ---------------------------------------------------------------------------
# 档位解析
# ---------------------------------------------------------------------------
# 需要 $ROOT（仓库根）来读 .tmp/platform 与扫 ./fw/。调用方若没设，
# 用本文件所在目录的上一级兜底（本文件就在 <root>/config/ 下）。
_dt_pl_root() {
	if [ -n "${ROOT:-}" ]; then
		echo "$ROOT"
	else
		(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)
	fi
}

# ./fw/ 下所有【合格】固件包的名字。
# 合格 = 有 rawprogram_unsparse0.xml —— 与 tools/lib/fw_locate.sh 的 fw_is_valid 一致。
# 必须校验：一个 fw 目录下常同时躺着 _debug / _debugimg / _ota 子包，
# 它们没有 rawprogram_unsparse0.xml，若不排除就会被当成"多份固件包"而拒绝自动判断。
_dt_pl_fw_names() {
	local r d
	r=$(_dt_pl_root)
	for d in "$r"/fw/*/; do
		[ -d "$d" ] || continue
		[ -f "$d/rawprogram_unsparse0.xml" ] || continue
		case "$(basename "${d%/}")" in
		QSM200U* | QSM200E*) basename "${d%/}" ;;
		esac
	done
}

# dt_platform_cache_write <档位> —— 把档位记到 <仓库根>/.tmp/platform
# buildenv 探测到 fw 之后调它，这样后面那些【不走 buildenv】的命令
#（buildkernel / tools/flash.sh / verify_*.sh）也能拿到同一档位。
# 失败只告警不报错：缓存写不进去不影响本次构建，下次重新探测一遍而已。
dt_platform_cache_write() {
	local k r
	k=$(dt_platform_norm "${1:-}") || return 1
	dt_platform_valid "$k" || return 1
	r=$(_dt_pl_root)
	if ! mkdir -p "$r/.tmp" 2>/dev/null; then
		echo "WARN: 建不了 $r/.tmp，档位没能缓存" >&2
		return 1
	fi
	if ! printf '%s\n' "$k" > "$r/.tmp/platform" 2>/dev/null; then
		echo "WARN: 写不了 $r/.tmp/platform，档位没能缓存" >&2
		return 1
	fi
	return 0
}

# _dt_platform_resolve_impl -> 解析生效档位，【就地设置】下面三个变量；失败返回 1
#
#   DT_PLATFORM_EFF       生效档位名（如 200e-debian）
#   DT_PLATFORM_SRC       来源（机器可读）：fw | cache | default
#   DT_PLATFORM_SRC_DESC  来源（给人看）："./fw/QSM…" / ".tmp/platform 缓存" / "默认值"
#
# 优先级：
#   ./fw/ 里那份合格固件包 > .tmp/platform 缓存 > 默认档位 $DT_PLATFORM_DEFAULT
#
# ⚠ 必须【在本 shell 直接调用】才拿得到那三个变量。写成 p=$(dt_platform_resolve)
#   会 fork 子 shell，变量全丢 —— 而那正是判断"档位是不是默认兜底"的依据。
#   只想要名字时用下面的 dt_platform_resolve 包装。
#
# ⚠ 没有环境变量入口是有意的，理由见文件头部。环境里残留的 $DT_PLATFORM
#   会被明确 WARN 说明已忽略（静默按另一个档位构建最难查）。
_dt_platform_resolve_impl() {
	local r p="" src="" src_kind=""
	r=$(_dt_pl_root)

	# 老的 $DT_PLATFORM 已不再被读取。它若还留在环境里（旧脚本 / docker --env /
	# 用户照着老文档敲的），必须【明确告知被忽略】—— 否则用户以为指定生效了，
	# 实际按 ./fw/ 里的包构建出另一个档位。
	if [ -n "${DT_PLATFORM:-}" ]; then
		echo "WARN: 环境变量 DT_PLATFORM='$DT_PLATFORM' 已被忽略 —— 档位不再由环境变量决定。" >&2
		echo "      现在只看 ./fw/ 里放的是哪份固件包。要换档位：换包，再跑一次 buildenv。" >&2
	fi

	# 1) 从 ./fw/ 反推 —— fw 是【物理事实】，必须排在缓存前面：
	#    换了 fw 包就该立刻跟着换档位，不能因为还有个旧缓存就继续用别的档位的
	#    MACHINE / DT 清单 / 基线。
	local cache="$r/.tmp/platform"
	local -a names=()
	while IFS= read -r line; do
		[ -n "$line" ] && names+=("$line")
	done < <(_dt_pl_fw_names)

	if [ "${#names[@]}" -eq 1 ]; then
		p=$(dt_platform_of_fw "${names[0]}") || {
			echo "ERROR: ./fw/ 里的 '${names[0]}' 认不出档位。" >&2
			echo "       应形如 QSM200U*BD01*（200u-debian）/ QSM200E*BL01*_perf（200e-linux-perf）等。" >&2
			return 1
		}
		src="./fw/${names[0]}"
		src_kind=fw
	elif [ "${#names[@]}" -gt 1 ]; then
		echo "ERROR: ./fw/ 下有 ${#names[@]} 份合格固件包，无法判断档位：" >&2
		printf '         %s\n' "${names[@]}" >&2
		echo "       本项目约定 ./fw/ 只放一份 —— 把不用的挪出去，只留要构建的那份。" >&2
		return 1
	else
		# 2) ./fw/ 里没有合格固件包 —— 常见于 fw/ 被删/还没放（几 GB 的临时目录）。
		#    这时用 buildenv 之前探测到的缓存，否则 buildkernel /
		#    tools/flash.sh 这些不走 buildenv 的命令会静默落回默认档位。
		#    缓存故意做【容错】：读坏了就忽略（它只是缓存），不像以前的
		#    config/platform 那样直接 ERROR 把整条流水线拦死。
		if [ -f "$cache" ]; then
			local raw
			raw=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$cache" |
				head -1 | tr -d '[:space:]')
			if [ -n "$raw" ] && dt_platform_valid "$(dt_platform_norm "$raw")"; then
				p=$(dt_platform_norm "$raw")
				src=".tmp/platform 缓存"
				src_kind=cache
			elif [ -n "$raw" ]; then
				echo "WARN: 缓存 $cache 里的 '$raw' 不是已知档位，已忽略。" >&2
			fi
		fi
		if [ -z "$p" ]; then
			p=$DT_PLATFORM_DEFAULT
			src="默认值"
			src_kind=default
		fi
	fi

	# 3) 缓存与 fw 不一致时提示（fw 赢，但要让用户知道缓存已被覆盖）
	#
	# 注：这里【没有】以前那个"档位与 fw 包名交叉校验"的告警了 —— 档位现在
	# 就是从 fw 推出来的，不可能对不上；留着只会是永远不触发的死代码。
	if [ -n "$src" ] && [ -f "$cache" ] && [ "${#names[@]}" -eq 1 ]; then
		local c
		c=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$cache" | head -1 | tr -d '[:space:]')
		if [ -n "$c" ] && [ "$(dt_platform_norm "$c")" != "$p" ]; then
			echo "说明: ./fw/ 里的包显示档位是 $p，缓存里记的是 $(dt_platform_norm "$c")。以 fw 为准；" >&2
			echo "      跑一次 buildenv 就会把缓存更新为 $p。" >&2
		fi
	fi

	DT_PLATFORM_EFF=$p
	DT_PLATFORM_SRC=$src_kind
	DT_PLATFORM_SRC_DESC=$src
	export DT_PLATFORM_EFF DT_PLATFORM_SRC DT_PLATFORM_SRC_DESC
	return 0
}

# dt_platform_resolve -> 打印生效档位名（兼容老写法 / 命令替换友好）。
#
# ⚠ 这样调用【拿不到】$DT_PLATFORM_SRC、也拿不到 DT_PLATFORM_EFF ——
#   包装函数在子 shell 里跑，impl 设的变量出不来，能拿到的只有这行回显。
#   需要判断"档位是从 ./fw/ 探测到的，还是默认值兜底"时，请直接调
#   _dt_platform_resolve_impl（且不要放在 $(...) 里）。
dt_platform_resolve() {
	_dt_platform_resolve_impl "$@" || return 1
	echo "$DT_PLATFORM_EFF"
}

# ---------------------------------------------------------------------------
# 实测依据（2026-09-17，三点对照法 —— 同仓库族只改一个轴，隔离因果）
#
#   仓库                                   rootfs   perf   MACHINE
#   gamma_3in1_200e/repo                   debian   0      qcm2290-mtp
#   gamma_3in1_200e_linux/repo             linux    0      qcm2290-mtp     ← 只改 rootfs
#   gamma_3in1_200e_linux_perf/repo        linux    1      qcm2290-mtp     ← 只改 perf
#
#   结论：
#     kernel_dtbs   59 / 59 / 59   —— 与 rootfs、perf 都无关（只随 SoC）
#     tech_dtbs     82 / 82 / 82   —— 公开清单过滤后相同；仍按 rootfs 分开保留
#     Image 版本串  …-gki-consolidate / 同 / 5.15.180   —— 只随 perf
#     config          2347 / 2347 / 2273 项 =y/=m       —— 只随 perf
#                     （perf 关掉 DEBUG_KMEMLEAK/OBJECTS/PAGEALLOC/MUTEXES/RWSEMS/
#                       SPINLOCK/PREEMPT/DYNAMIC_DEBUG 共 8 项，且 CONFIG_LOCALVERSION 为空）
#     system.img    4.6G / 982M（fw 包）                —— 只随 rootfs
#     /opt/quectel  有 / 无                            —— 只随 rootfs
#                   （bbappend 里 deploy_debian_gnome_rootfs() 把 9 类 .ko 搬进 /opt/quectel；
#                     tools/build-system.sh 是【动态扫描镜像】的，所以这里不用改代码）
#
#   内核源码内容：kernel_platform 77200 个文件 md5 **0 差异**
#   （唯一漂移是 defconfig 文件名清单，两边各自都能编过）
#
#   尚未实测的档位（无源码/无出包目录，按上面规律预置，标为「推导」）：
#     200u-linux            推导：tech_dtbs 使用公开过滤后的 82 项清单
#     200u-linux-perf       推导
#     200u-debian-perf      推导
#     200e-debian-perf      推导
#     200e-linux-perf       已实测 ✅
#     200e-linux            已实测 ✅
#     200e-debian           已实测 ✅
#     200u-debian           已实测 ✅
