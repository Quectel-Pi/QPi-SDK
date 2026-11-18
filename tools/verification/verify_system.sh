#!/bin/bash
#
# verify_system.sh —— 权威验证 out-system/system.img 里的模块
#
# ⚠️ 必须在【宿主】上跑（需要 sudo + loop 设备），不能在容器里跑。
#    容器里没有 sudo、也没有 /dev/loopN，只能走 debugfs —— 而 debugfs 恰好
#    不足以发现问题（e2fsprogs 1.45.x 写多块目录会静默丢条目，e2fsck 查不出来）。
#    **必须挂载上来数文件，这才是权威验证。**
#
# 说明：本仓库只重建【内核自带模块】（落在 /lib/modules/<release>/），
#       vendor 外部模块（extra/、kernel/drivers/net/usb/、/opt/quectel/）
#       没有源码与构建逻辑，会一直是出厂原版。
#
# 检查内容：
#   1. e2fsck 只读检查
#   2. 4 处模块位置的数量（与出厂值对照）
#   3. /lib/modules 下的子目录清单是否与基准一致（没有多/少目录）
#   4. 逐个 md5 比对：镜像里哪些模块还是出厂原版（即我们没编出来的）
#   5. 属性/权限是否为 root:root 0644
#   6. 抽查 vermagic
#   7. /opt/quectel 下非 .ko 文件是否被动过
#
# 用法：
#   ./tools/verification/verify_system.sh        # 验证 out-system/system.img
#   KEEP=1 ./tools/verification/verify_system.sh # 保留 raw 与挂载点便于手工排查
#
set -e
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$ROOT"

# 档位（8 个：<SoC>-<rootfs>[-perf]）—— 本脚本要用 DT_KREL_FILE / DT_SYSIMG /
# DT_ROOTFS。调用方（source build.sh 后手跑）通常已 export；直接裸跑本脚本时
# dt_platform_ensure 会就地解析一份。详见 config/platforms.sh。
. "$ROOT/config/platforms.sh"
dt_platform_ensure || { echo "ERROR: 档位未定（见 config/platforms.sh）" >&2; exit 1; }

IMG=${1:-$ROOT/out-system/system.img}
[ -f "$IMG" ] || { echo "ERROR: 找不到 $IMG（先跑 ./build_system.sh）" >&2; exit 1; }

if [ "$(id -u)" != "0" ] && ! sudo -n true 2>/dev/null; then
	echo "ERROR: 需要 root 或免密 sudo（要在宿主上挂载 loop 镜像）" >&2
	exit 1
fi
SUDO=""
[ "$(id -u)" != "0" ] && SUDO="sudo"

for t in simg2img e2fsck debugfs md5sum; do
	command -v "$t" >/dev/null || { echo "ERROR: 缺少 $t" >&2; exit 1; }
done

W=$ROOT/.verify
RAW=$W/system.raw
MNT=$W/mnt
mkdir -p "$MNT"
trap '[ -n "${UNMOUNTED:-}" ] || $SUDO umount "$MNT" 2>/dev/null || true' EXIT

KREL=$(dt_krel_get || true)
[ -n "$KREL" ] || { echo "ERROR: 既没有 $DT_KREL_FILE，也无法从 $DT_RD_BASE 派生（先跑一次 buildenv）" >&2; exit 1; }
KV=$KREL

echo "=== 0/6 展开 sparse ==="
rm -f "$RAW"
simg2img "$IMG" "$RAW"
echo "  raw: $(stat -c%s "$RAW") 字节  ($(du -h "$RAW" | cut -f1))"

echo
echo "=== 1/6 e2fsck 只读检查 ==="
$SUDO e2fsck -fn "$RAW" > "$W/fsck.log" 2>&1 && rc=0 || rc=$?
echo "  exit=$rc  $([ "$rc" = 0 ] && echo '✅ 干净' || echo '⚠️ 有需要修的地方')"
tail -2 "$W/fsck.log" | sed 's/^/  /'

echo
echo "=== 2/6 挂载 ==="
$SUDO mount -o ro,loop "$RAW" "$MNT"
echo "  $RAW -> $MNT"

echo
echo "=== 3/6 各模块目录的数量（逐档位自动对照）==="
# 期望值【不写死】：每个档位的出厂模块数都不同 —— debian 比 linux 多 /opt/quectel，
# 200u 与 200e 的内核模块数也不一样。写死一套数字必然只对一个档位成立。
# 这里直接数【出厂基准镜像】$DT_SYSIMG，它就是出厂原样，最权威。
# 基准计数走 debugfs（只读、不挂载；e2fsprogs 丢目录的老坑只在【写】时触发）。
BASE_RAW=
if [ -f "$ROOT/$DT_SYSIMG" ] && simg2img "$ROOT/$DT_SYSIMG" "$W/base.raw" 2>/dev/null; then
	BASE_RAW=$W/base.raw
fi
base_cnt() {
	[ -n "$BASE_RAW" ] || return 0
	debugfs -R "ls -l $1" "$BASE_RAW" 2>/dev/null | grep -c '\.ko$' || true
}

# /opt/quectel 只在 debian 档存在（linux 档的 rootfs 不含 meta-quectel-debian 那套配方）
DIRS=("/lib/modules/$KV/" "/lib/modules/$KV/extra/"
      "/lib/modules/$KV/kernel/drivers/net/usb/")
[ "$DT_ROOTFS" = debian ] && DIRS+=("/opt/quectel/")

total=0
for k in "${DIRS[@]}"; do
	n=$(ls "$MNT$k"/*.ko 2>/dev/null | wc -l)
	total=$((total + n))
	if [ -z "$BASE_RAW" ]; then
		mark="（无基准镜像，只报数）"
	else
		e=$(base_cnt "$k")
		if [ "$n" -ge "$e" ]; then mark="✅ 基准 $e"
		else mark="⚠️ 基准 $e，少了 $((e - n))"; fi
	fi
	printf '  %-46s %3s  %s\n' "$k" "$n" "$mark"
done
echo "  ────────────────────────────────────────────────────────"
printf '  %-46s %3s\n' "合计" "$total"
echo "  （基准 = 出厂镜像 $DT_SYSIMG；只增不减才对）"

echo
echo "=== 4/6 /lib/modules 子目录清单（应与基准一致）==="
$SUDO find "$MNT/lib/modules/$KV" -mindepth 1 -maxdepth 1 -type d \
	| sed 's|.*/||' | sort | tr '\n' ' '; echo

echo
echo "=== 5/6 哪些模块仍是出厂原版（用 md5 比对）==="
MINEMD5=$W/mine.md5
IMGD5=$W/img.md5
: > "$MINEMD5"
for d in "$ROOT/stage/second" "$ROOT"/out-modules/kernel; do
	[ -d "$d" ] || continue
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		echo "$(basename "$f") $(md5sum "$f" | cut -d' ' -f1)" >> "$MINEMD5"
	done < <(find "$d" -maxdepth 1 -name '*.ko' -type f 2>/dev/null)
done
sort -u "$MINEMD5" -o "$MINEMD5"

: > "$IMGD5"
while IFS= read -r f; do
	[ -n "$f" ] || continue
	echo "$(basename "$f") $($SUDO md5sum "$f" | cut -d' ' -f1)" >> "$IMGD5"
SCAN=("$MNT/lib/modules/$KV")
[ -d "$MNT/opt/quectel" ] && SCAN+=("$MNT/opt/quectel")
done < <($SUDO find "${SCAN[@]}" -name '*.ko' -type f 2>/dev/null)
sort -u "$IMGD5" -o "$IMGD5"

n_mine=$(wc -l < "$MINEMD5")
n_img=$(wc -l < "$IMGD5")
rebuilt=$(join -j1 "$IMGD5" "$MINEMD5" 2>/dev/null | awk '$2==$3' | wc -l)
stale=$(join -j1 "$IMGD5" "$MINEMD5" 2>/dev/null | awk '$2!=$3' | wc -l)
stale_list=$(comm -23 <(cut -d' ' -f1 "$IMGD5") <(cut -d' ' -f1 "$MINEMD5"))

echo "  我方产物      : $n_mine 个"
echo "  镜像内模块    : $n_img 个"
echo "  已换成我方版本: $rebuilt 个"
echo "  已构建但 md5 不同（异常，需查）: $stale 个"
[ "$stale" -gt 0 ] && join -j1 "$IMGD5" "$MINEMD5" | awk '$2!=$3 {print "     ❌ "$1}'
echo "  我方编不出来的（保持出厂原版）:"
if [ -n "$stale_list" ]; then echo "$stale_list" | sed 's/^/     ⚪ /'; else echo "     （无）"; fi

echo
echo "=== 6/6 属性/权限 + vermagic 抽查 ==="
for f in "$MNT/opt/quectel/msm_drm.ko" "$MNT/lib/modules/$KV/extra/wcd_core_dlkm.ko" \
         "$MNT/lib/modules/$KV/kernel/drivers/net/usb/GobiNet.ko"; do
	[ -f "$f" ] || continue
	printf '  %-42s %s\n' "${f#$MNT}" "$($SUDO stat -c '%A %U:%G' "$f")"
done
echo "  --- vermagic ---"
for f in "$MNT/opt/quectel/msm.ko" "$MNT/opt/quectel/msm_drm.ko" "$MNT/lib/modules/$KV/wlan.ko"; do
	[ -f "$f" ] || continue
	printf '  %-24s %s\n' "$(basename "$f")" "$(modinfo -F vermagic "$f" 2>/dev/null || strings "$f" | grep -m1 vermagic=)"
done

if [ -d "$MNT/opt/quectel" ]; then
	echo
	echo "=== /opt/quectel 非 .ko 文件（应与出厂一致）==="
	$SUDO ls "$MNT/opt/quectel" | grep -v '\.ko$' | tr '\n' ' '; echo
fi

$SUDO umount "$MNT"
UNMOUNTED=1
if [ "${KEEP:-0}" != "1" ]; then
	rm -rf "$W"
else
	echo
	echo "  已保留 $W （KEEP=1）"
fi

echo
echo "========================= verify done ========================="
