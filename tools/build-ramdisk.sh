#!/bin/bash
#
# build_ramdisk.sh —— 用新编译的「第一段」模块重新打包 initramfs
#
# boot.img 里的 initramfs（qti-ramdisk-image）本身是 Yocto 产出的，里面有
# systemd + 挂载根文件系统所必需的一批 .ko。本脚本不解 Yocto、只做替换：
#
#   解开 baseline cpio.lz4
#     -> 用 stage/first/*.ko 覆盖 lib/modules/<release>/*.ko
#     -> 重新打包成 cpio.lz4（与原镜像同样的 legacy-lz4 -9）
#
# 关键点：
#   * 必须用 fakeroot 解包+打包：否则文件属主会变成当前用户(uid 1000)，
#     设备上 systemd/内核按 root 属主启动会出问题。容器里没有 root，
#     fakeroot 是唯一可行方案（Yocto 也是这么干的）。
#   * 压缩参数必须和 Yocto 一致：lz4 -9 -z -l （legacy 格式）。
#     内核两种都认，但保持一致便于和出场镜像比对。
#
# 输入：
#   prebuilds/qti-ramdisk-image-sm6115-mtp.cpio.lz4   基准镜像(sync 同步)
#   stage/first/*.ko                                 新模块
# 输出：
#   out-ramdisk/qti-ramdisk-image-sm6115-mtp.cpio.lz4
#
set -e
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# 档位（8 个：<SoC>-<rootfs>[-perf]）—— 一般由 build.sh 的 _dt_step export 进来；
# 直接手跑本脚本时 dt_platform_ensure 会就地解析一份。详见 config/platforms.sh。
. "$ROOT/config/platforms.sh"
dt_platform_ensure || { echo "ERROR: 平台未定（见 config/platforms.sh）" >&2; exit 1; }

BASE=$ROOT/$DT_RD_BASE
# 基线缺失时从 fw/boot.img 现取（不必随交付包预置），见 build.sh 的 restore_baseline
if [ ! -f "$BASE" ]; then
	echo ">>> 缺少 baseline initramfs，从 fw/boot.img 还原"
	"$ROOT/build.sh" restore --only ramdisk || exit 1
fi
[ -f "$BASE" ] || { echo "ERROR: 仍缺少 $BASE" >&2; exit 1; }

FIRST=$ROOT/stage/first
if [ ! -d "$FIRST" ] || [ -z "$(ls -A "$FIRST" 2>/dev/null)" ]; then
	echo "ERROR: $FIRST 为空，请先跑 source build.sh && buildkernel && buildstage" >&2
	exit 1
fi

KREL=$(dt_krel_get || true)
if [ -z "$KREL" ]; then
	echo "ERROR: 既没有 $DT_KREL_FILE，也无法从 $DT_RD_BASE 派生" >&2
	echo "       请先跑 source build.sh && buildenv（或 buildkernel）" >&2
	exit 1
fi

WORK=$ROOT/out-ramdisk/work
OUTDIR=$ROOT/out-ramdisk
OUT=$OUTDIR/$DT_RD_NAME

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUTDIR"

# 整个「解包 -> 替换 -> 打包」必须跑在同一个 fakeroot 会话里：
# fakeroot 的属主信息只存在于该会话中，会话一结束就丢了。
FAKE=$OUTDIR/_repack_inner.sh
cat > "$FAKE" <<'EOS'
set -e
BASE=$1; WORK=$2; FIRST=$3; KREL=$4; CPIO=$5

cd "$WORK"

echo "=== 解开 baseline initramfs ==="
lz4 -dc "$BASE" | cpio -idm --quiet
echo "  解出条目: $(find . | wc -l)"

MODDIR="$WORK/lib/modules/$KREL"
if [ ! -d "$MODDIR" ]; then
	echo "ERROR: initramfs 里找不到 lib/modules/$KREL" >&2
	echo "       实际内容:" >&2
	ls "$WORK/lib/modules" >&2
	exit 1
fi

echo
echo "=== 替换 first-stage 模块 ==="
replaced=0
added=0
for ko in "$FIRST"/*.ko; do
	[ -f "$ko" ] || continue
	name=$(basename "$ko")
	if [ -f "$MODDIR/$name" ]; then
		replaced=$((replaced + 1))
	else
		added=$((added + 1))
		echo "  + 新增: $name"
	fi
	cp -f "$ko" "$MODDIR/$name"
done
total=$(find "$MODDIR" -maxdepth 1 -name '*.ko' | wc -l)
echo "  替换 $replaced 个，新增 $added 个；initramfs 现有 $total 个模块"

echo
echo "=== 打包 (newc) ==="
find . | sort | cpio -o -H newc --quiet > "$CPIO"
EOS

echo "=== 重打包 initramfs (fakeroot) ==="
fakeroot -- bash "$FAKE" "$BASE" "$WORK" "$FIRST" "$KREL" "$OUTDIR/ramdisk.cpio"

echo
echo "=== 压缩 (lz4 -9 -z -l, 与 Yocto 一致) ==="
lz4 -f -9 -z -l "$OUTDIR/ramdisk.cpio" "$OUT"
rm -f "$OUTDIR/ramdisk.cpio" "$FAKE"

echo
echo "initramfs -> $OUT"
echo "  新镜像 : $(stat -c%s "$OUT") 字节"
echo "  基准   : $(stat -c%s "$BASE") 字节"
echo "========================= finish ========================="
