#!/bin/bash

set -e

# 本脚本在 tools/ 下，仓库根 = 上一级
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
OUT=$ROOT/out-kernel
CFG=$ROOT/kernel/msm-kernel/build.config.msm.bengal.le

# system-only SDK: DTB/DTBO and boot.img generation are intentionally unsupported.
# Keep the existing public-build behavior explicit so Kernel sources never trigger DT builds.
QPI_BUILD_DTBS=0
echo "DT build: disabled (system-only SDK)"
export QPI_BUILD_DTBS

# ---------------------------------------------------------------------------
# Freeze the factory kernel release before starting a new build.
#
# $DT_KREL_FILE is not a build output: buildenv derives it from the current
# profile's factory boot ramdisk.  The public SDK keeps that factory Image, so
# modules built here are deliverable only when their release matches it exactly.
# ---------------------------------------------------------------------------
if [ -z "${DT_KREL_FILE:-}" ]; then
	echo "ERROR: DT_KREL_FILE 未设置，无法确认原厂 kernel release（请通过 build.sh 调用 buildkernel）" >&2
	exit 1
fi
FACTORY_KREL_FILE=$ROOT/$DT_KREL_FILE
if [ ! -s "$FACTORY_KREL_FILE" ]; then
	echo "ERROR: 缺少当前档位的原厂 kernel release 基准: $FACTORY_KREL_FILE" >&2
	echo "       请先执行 buildenv，由 fw 原厂 boot ramdisk 派生该基准。" >&2
	exit 1
fi
FACTORY_KREL=$(tr -d '\r\n' < "$FACTORY_KREL_FILE")
if [ -z "$FACTORY_KREL" ]; then
	echo "ERROR: 原厂 kernel release 基准为空: $FACTORY_KREL_FILE" >&2
	exit 1
fi
echo "factory kernel release: $FACTORY_KREL"

# The upstream config hard-codes ABL_SRC, which would override the
# environment.  Rewrite it to only supply a default so that an empty
# ABL_SRC (the sanctioned way to skip ABL, see build.sh's GKI branch)
# is honoured.  ABL/edk2 is not part of boot.img.
if grep -q '^ABL_SRC=bootable/bootloader/edk2$' "$CFG"; then
	sed -i 's|^ABL_SRC=bootable/bootloader/edk2$|: ${ABL_SRC=bootable/bootloader/edk2}|' "$CFG"
fi

# ---------------------------------------------------------------------------
# Pin the kernel release string (必须！)
#
# 内核源码放在本 git 仓库里，但 msm-kernel 自己不是 git 仓库，于是
# scripts/setlocalversion 会一路往上找到 ~/dt/.git，把
#   "-g<commit>[-dirty]"
# 追加到版本串后面：
#     5.15.180-gki-consolidate-g6a18bca2b7c2-dirty
#
# 这个串会被写进每个 .ko 的 vermagic。而客户机器上运行的内核、以及
# vendor 侧编译的模块(audio/camera/wlan/...)都是
#     5.15.180-gki-consolidate
# 两者不一致 → 模块加载直接报 "version magic mismatch" 拒绝加载。
#
# Yocto 的做法是在内核源码树写一个【空】的 .scmversion，让
# setlocalversion 立刻 return（见 poky/meta/classes/kernel.bbclass
# 的 kernel_do_configure()）。这里照做，把版本串钉死。
# ---------------------------------------------------------------------------
: > $ROOT/kernel/msm-kernel/.scmversion

rm -rf $OUT
mkdir -p $OUT/msm-kernel

# Reuse the Yocto generated kernel config verbatim.
# build.sh runs `make mrproper` unless SKIP_MRPROPER=1 and `make defconfig`
# unless SKIP_DEFCONFIG=1, so both must be set for the injected config to
# survive.  The Kbuild output dir is $OUT/msm-kernel (build.sh derives it as
# ${COMMON_OUT_DIR}/${KERNEL_DIR}), which is where the kernel looks for .config.
cp -f $ROOT/$DT_KCONFIG $OUT/.config
cp -f $ROOT/$DT_KCONFIG $OUT/msm-kernel/.config

# ---------------------------------------------------------------------------
# ⚠️⚠️ 让配置改动真正生效 —— 这里有个非常隐蔽的坑，务必看懂再改
#
# 【症状】改 $DT_KCONFIG 加一个开关（实测 CONFIG_NULL_TTY=m）后重新
#   构建：不报任何错，但对应 .ko 根本没编出来（模块数停在 270 而不是 271）。
#
# 【根因】build.sh 的配置流程会把 objtree 里的 auto.conf 污染成「合并版
#   defconfig」，而不是我们注入的 .config：
#
#     build.sh  →  PRE_DEFCONFIG_CMDS = "compile_external_dtc && merge_defconfig_fragments"
#                  （见 kernel/msm-kernel/build.config.msm.common）
#        merge_defconfig_fragments() 做两件事：
#          1) merge_config.sh -m -r -y <fragments>
#               把 generic_bengal_defconfig + 各 fragment 合并，
#               并【覆盖写回】 arch/arm64/configs/generic_bengal_defconfig
#          2) KCONFIG_CONFIG=/tmp/tmp.XXXX make O=$OUT_DIR generic_bengal_defconfig
#               注意 KCONFIG_CONFIG 指向 /tmp ⇒ 【不写】$OUT_DIR/.config
#               但【会写】$OUT_DIR/include/config/auto.conf + generated/autoconf.h
#
#     结果：我们拷进去的 .config 活着（含新增开关），
#           auto.conf 却是「合并版 defconfig」的内容，而且 mtime 更新 ⇒
#           之后 `make Image modules dtbs` 时 kbuild 认为缓存有效、跳过
#           syncconfig ⇒ 新增开关全部丢失，且【完全静默】。
#
# 【修法】build.sh 在配置阶段之后、真正 make 之前，有一个分支会执行
#     (cd ${OUT_DIR} && make ... O=${OUT_DIR} olddefconfig)     # build.sh:767
#   而 olddefconfig 是【无条件】重写 .config + auto.conf 的。触发它的开关就是
#   环境变量 LTO（build.sh:736）。
#
#   ⚠️ LTO 必须与 config 里的取值一致，否则 build.sh 会反过来改我们的配置！
#      所以下面从 $DT_KCONFIG 反推，保证严格 no-op：
#        出厂配置 CONFIG_LTO_CLANG_FULL=y
#        build.sh 的 full 分支设的也正是
#            -e LTO_CLANG -d LTO_NONE -d LTO_CLANG_THIN -e LTO_CLANG_FULL -d THINLTO
#        与 config 逐项相同 ⇒ 只触发 olddefconfig，一个配置项都不改。
#
#   注意：这个清理必须在 build.sh 之前做（清掉 build.sh 上一轮可能留下的
#   污染缓存），而真正的重同步由 build.sh 内部的 olddefconfig 完成 ——
#   我们无法插到 merge 和 make 之间，所以只能借 LTO 这个开关。
# ---------------------------------------------------------------------------
rm -f "$OUT/msm-kernel/include/config/auto.conf" \
      "$OUT/msm-kernel/include/config/auto.conf.cmd" \
      "$OUT/msm-kernel/include/config/tristate.conf" \
      "$OUT/msm-kernel/include/generated/autoconf.h" \
      "$OUT/msm-kernel/include/config/auto.conf.d" 2>/dev/null || true

if   grep -q '^CONFIG_LTO_CLANG_FULL=y' "$ROOT/$DT_KCONFIG"; then LTO=full
elif grep -q '^CONFIG_LTO_CLANG_THIN=y' "$ROOT/$DT_KCONFIG"; then LTO=thin
elif grep -q '^CONFIG_LTO_NONE=y'       "$ROOT/$DT_KCONFIG"; then LTO=none
else
	# config 里连 LTO 三个分支都没有（客户把 CONFIG_LTO 整个关掉了）。
	# 用 LTO=none 兜底：语义上就是"不做 LTO"，与该配置一致。
	# 副作用仅 build.sh 的 none 分支会顺带 --set-val FRAME_WARN 0（只放宽
	# 编译告警阈值，不改变生成代码）。
	LTO=none
	echo "WARN: $DT_KCONFIG 里没有 LTO_CLANG_FULL/THIN/NONE，按 LTO=none 处理"
fi
echo "LTO mode (derived from kernel.config): $LTO"

cd $ROOT/kernel
QPI_DEBIAN_BUILD=1 \
QPI_BUILD_DTBS=$QPI_BUILD_DTBS \
SKIP_MRPROPER=1 \
SKIP_DEFCONFIG=1 \
ABL_SRC= \
LTO=$LTO \
BUILD_CONFIG=./msm-kernel/build.config.msm.bengal.le \
VARIANT=consolidate \
OUT_DIR=$OUT \
./build/build.sh -j$(nproc)

if [ ! -f $OUT/dist/Image ]; then
	echo "ERROR: kernel Image was not produced" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# 校验 $DT_KCONFIG 真的生效了（这个坑太隐蔽，必须结果校验）
#
# 逐项检查 $DT_KCONFIG 里每个 =y/=m 的项。当前源码支持的符号必须以
# 相同值出现在 auto.conf；factory IKCONFIG 中存在、但当前公开源码完全
# 不认识的符号会被 olddefconfig 从 normalized .config 中删除，只告警跳过。
# ---------------------------------------------------------------------------
AC=$OUT/msm-kernel/include/config/auto.conf
NORMALIZED=$OUT/msm-kernel/.config
[ -f "$AC" ] || { echo "ERROR: 找不到 $AC" >&2; exit 1; }
[ -f "$NORMALIZED" ] || { echo "ERROR: 找不到 $NORMALIZED" >&2; exit 1; }

declare -a config_requested=() config_unsupported=() config_hard_failures=()
mapfile -t config_requested < <(
	grep -oE '^CONFIG_[A-Za-z0-9_]+=[ym]$' "$ROOT/$DT_KCONFIG" | sort -u
)
for requested in "${config_requested[@]}"; do
	grep -qxF "$requested" "$AC" && continue
	name=${requested%%=*}
	if grep -qE "^${name}=|^# ${name} is not set$" "$NORMALIZED"; then
		config_hard_failures+=("$requested")
	else
		config_unsupported+=("$requested")
	fi
done

if [ "${#config_unsupported[@]}" -gt 0 ]; then
	echo "WARNING: 以下 factory Kernel 配置项不受当前公开 Kernel 源码支持，已跳过：" >&2
	printf '         %s\n' "${config_unsupported[@]}" >&2
fi

if [ "${#config_hard_failures[@]}" -gt 0 ]; then
	echo "ERROR: 下列配置项没有生效（$DT_KCONFIG 里有，auto.conf 里没有）：" >&2
	printf '       %s\n' "${config_hard_failures[@]}" >&2
	echo >&2
	echo "       原因：build.sh 的 merge_defconfig_fragments 把 auto.conf 写成了" >&2
	echo "       「合并版 defconfig」，而 build.sh 自身没有再跑 syncconfig。" >&2
	echo "       只在 LTO 变量非空时 build.sh 才会执行 olddefconfig 重同步。" >&2
	echo "       请检查上面 'LTO mode (derived from kernel.config)' 那行是否正常。" >&2
	exit 1
fi
n_cfg=${#config_requested[@]}
n_supported=$((n_cfg - ${#config_unsupported[@]}))
echo "config check: $n_supported 个受支持的 =y/=m 项全部已生效，${#config_unsupported[@]} 个不受支持项已跳过 ✅"

# ---------------------------------------------------------------------------
# 校验版本串：必须与原厂镜像一致（不带 git hash）
# 内核模块目录名 / lib/modules/<release>/ 也由它决定
# ---------------------------------------------------------------------------
BUILT_KREL=$(cat $OUT/msm-kernel/include/config/kernel.release)
case "$BUILT_KREL" in
	*-g[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
		echo "ERROR: kernel release '$BUILT_KREL' 带了 git hash，模块会与原厂内核不兼容！" >&2
		echo "       请确认 $ROOT/kernel/msm-kernel/.scmversion 存在且为空。" >&2
		exit 1
		;;
esac
if [ "$BUILT_KREL" != "$FACTORY_KREL" ]; then
	echo "ERROR: 本次构建的 kernel release 与当前 fw 原厂 Kernel 不一致，拒绝交付模块。" >&2
	echo "       FACTORY_KREL=$FACTORY_KREL" >&2
	echo "       BUILT_KREL=$BUILT_KREL" >&2
	echo "       $DT_KREL_FILE 是原厂 release 基准，buildkernel 不会覆盖它。" >&2
	exit 1
fi
echo "kernel release check: FACTORY_KREL=$FACTORY_KREL BUILT_KREL=$BUILT_KREL ✅"

# 注意：这里【不】往 prebuilds/Image 写。它是【出厂基线内核】
# （可从 fw/boot.img 还原，见 build.sh 的 restore_baseline），留着供 build.sh 在
# 不重编内核时回退；新编出来的内核在 out-kernel/dist/Image，build.sh 优先用它。

# ---------------------------------------------------------------------------
# 收集内核自带的模块（.ko 扁平放在 dist/）
#   out-modules/kernel/*.ko
# 后续 stage_modules.sh 会按 modules.list 把它们分成
#   first-stage  -> 打进 initramfs
#   second-stage -> 打进 system.img
# ---------------------------------------------------------------------------
mkdir -p $ROOT/out-modules/kernel
rm -f $ROOT/out-modules/kernel/*.ko
n=0
for ko in $OUT/dist/*.ko; do
	[ -f "$ko" ] || continue
	cp -f "$ko" $ROOT/out-modules/kernel/
	n=$((n + 1))
done
echo "kernel modules staged: $n -> $ROOT/out-modules/kernel"

# ---------------------------------------------------------------------------
# 去掉模块的 debug info (必须！)
#
# 内核构建带 CONFIG_DEBUG_INFO=y，.ko 里塞满了调试段
# (ufs_qcom.ko: 1,744,880 字节，其中 ~1.42MB 是 debug)。
# 出厂镜像里的模块都是剥过的 (同一个模块只有 317,960 字节)，
# Yocto 是靠 package.bbclass 的 split_and_strip_files() 把 debug 拆进
# 单独的 <pkg>-dbg 包，镜像里只装 stripping 后的版本。
#
# 不剥的话 initramfs 会从 19.9MB 涨到 38.7MB，boot.img 逼近 96MiB
# 分区上限，很危险。这里复刻 Yocto 对 kernel module 用的那组参数：
#   --strip-debug --remove-section=.comment --remove-section=.note --preserve-dates
# (见 poky/meta/lib/oe/package.py 的 runstrip())
# ---------------------------------------------------------------------------
STRIP=""
for c in "$ROOT/kernel/prebuilts/clang/host/linux-x86/clang-r450784e/bin/llvm-strip" \
	 "$(command -v aarch64-linux-gnu-strip 2>/dev/null || true)" \
	 "$(command -v aarch64-oe-linux-strip 2>/dev/null || true)" \
	 "$(command -v strip 2>/dev/null || true)"; do
	if [ -n "$c" ] && [ -x "$c" ]; then STRIP=$c; break; fi
done
if [ -z "$STRIP" ]; then
	echo "WARNING: 找不到 strip，模块会带 debug info（initramfs 会变大很多）" >&2
else
	echo "stripping modules with: $STRIP"
	for ko in $ROOT/out-modules/kernel/*.ko; do
		[ -f "$ko" ] || continue
		"$STRIP" --strip-debug --remove-section=.comment --remove-section=.note \
			--preserve-dates "$ko" 2>/dev/null || true
	done
fi
echo "out-modules/kernel: $(du -sh $ROOT/out-modules/kernel | cut -f1)"

echo
echo "Image    -> $OUT/dist/Image ($(du -h $OUT/dist/Image | cut -f1))"
echo "modules  -> $ROOT/out-modules/kernel ($(ls $ROOT/out-modules/kernel/*.ko 2>/dev/null | wc -l) 个)"
