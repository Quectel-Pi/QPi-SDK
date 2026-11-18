#!/bin/bash
#
# flash.sh —— 把 out-system/system.img 烧到指定 A/B 槽
#
# 用法：
#   ./tools/flash.sh            # 烧到【当前未运行】的槽（安全）
#   ./tools/flash.sh b          # 明确指定槽位
#   ./tools/flash.sh b --switch # 烧完自动切到该槽并重启
#   ./tools/flash.sh --dry-run  # 【只做检查并打印计划，不推送不烧写】—— 建议先跑这个
#
# ⛔⛔ 最重要的一条：绝对不能写【正在挂载的根文件系统】的块设备 ⛔⛔
#
#   踩过的坑：设备正跑在目标槽（它的 system 分区正挂载为 / rw）时，
#   直接 dd 8GiB 到 system_b 分区 —— 写完后回读 md5 与源镜像不一致！
#   原因：ext4 对该文件系统有脏页缓存，它会继续把缓存刷回块设备，
#   覆盖掉我们刚写进去的数据；同时块设备回读又受页缓存影响，
#   导致读到的既不是纯新镜像也不是纯旧数据。
#   （那次 dmesg 无任何 IO 错误，所以完全看不出来）
#
#   正确做法：先从【另一个槽】启动，让目标槽处于未挂载状态，再烧。
#   本脚本会强制检查目标槽的挂载状态，不满足就直接退出。
#
# 另一个坑：设备上【没有 simg2img】（只有 busybox img2simg）。
#   所以 system.img（Android sparse）必须在主机上先转成 raw 再推过去。
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

IMG_SYS=$ROOT/out-system/system.img

. "$ROOT/config/platforms.sh"
dt_platform_ensure || true    # 档位定不了也不拦：烧写本身不依赖它，只是模块数校验会跳过

# 内核 release（下面那条模块数提示要用）：落盘值优先，落盘没有就从基线 ramdisk 派生。
# 【没有硬编码兜底值】—— 兜底常量只对非 perf 档成立，perf 档写错路径的下场是
# 提示指向一个不存在的目录，比显式空着更容易误导。推不出来就让 KV 空着。
KV=$(dt_krel_get || true)

ADB=${ADB:-adb}
TMPDIR_HOST=${TMPDIR_HOST:-"$ROOT/.scratch/flash"}

# ---- 参数 ----
SLOT=""
DO_SWITCH=0
DRY_RUN=0
for a in "$@"; do
	case "$a" in
		a|A|0)   SLOT=0 ;;
		b|B|1)   SLOT=1 ;;
		--switch) DO_SWITCH=1 ;;
		--dry-run|-n) DRY_RUN=1 ;;
		-h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "ERROR: 未知参数 $a" >&2; exit 1 ;;
	esac
done

say() { printf '\n=== %s ===\n' "$*"; }
sub() { printf '  %s\n' "$*"; }

# ---- 1. 前置检查 ----
say "1/7 前置检查"
[ -f "$IMG_SYS" ] || { echo "ERROR: 缺少 $IMG_SYS" >&2; exit 1; }
$ADB get-state >/dev/null 2>&1 || { echo "ERROR: 没有 adb 设备" >&2; exit 1; }

# 当前槽
CUR=$($ADB shell /sbin/abctl --boot_slot 2>/dev/null | tr -d '\r' | tr -d ' ')
case "$CUR" in _a) CUR=0 ;; _b) CUR=1 ;; *) echo "ERROR: 无法识别当前槽 '$CUR'" >&2; exit 1 ;; esac
# 分区块设备一律用 by-name 解析，【不要硬编码 mmcblk0p7x】：
# 实测本机 system_a=p28 / system_b=p29 / p78=userdata —— 硬编码既显示错、又会误判挂载。
CUR_SYS=$($ADB shell "readlink -f /dev/block/bootdevice/by-name/system_a 2>/dev/null" | tr -d '\r')
sub "当前运行槽: $([ $CUR -eq 0 ] && echo A || echo B)  (root 设备 ${CUR_SYS##*/})"

# 未指定则选另一个槽
if [ -z "$SLOT" ]; then
	SLOT=$(( 1 - CUR ))
	sub "未指定槽位 -> 自动选择未运行槽 $([ $SLOT -eq 0 ] && echo A || echo B)"
fi

if [ "$SLOT" = "$CUR" ]; then
	echo >&2
	echo "ERROR: 目标槽 $([ $SLOT -eq 0 ] && echo A || echo B) 正是当前运行槽！" >&2
	echo "       写正在挂载的根文件系统会让 ext4 把脏页刷回去，覆盖你刚写的数据，" >&2
	echo "       而且 dmesg 不报任何 IO 错误 —— 这是踩过的坑。" >&2
	echo "       请先切到另一个槽再烧：" >&2
	echo "         adb shell /sbin/abctl --set_active $CUR && adb reboot   # 切到当前槽" >&2
	echo "         # 或者显式指定另一个槽:  ./tools/flash.sh $([ $CUR -eq 0 ] && echo b || echo a)" >&2
	exit 1
fi

SFX=$([ "$SLOT" -eq 0 ] && echo _a || echo _b)
sub "目标槽: $([ "$SLOT" -eq 0 ] && echo A || echo B)  (后缀 $SFX)"

# 目标槽不是当前运行槽（上面已强制），所以当前运行槽保持不动 —— 它就是回滚点。
# 这里只提示，不阻塞：烧未运行槽本来就正是为了保住回滚能力。
CURS="$( [ "$CUR" -eq 0 ] && echo A || echo B )"
sub "⚠️  目标槽 $([ "$SLOT" -eq 0 ] && echo A || echo B) 的内容将被覆盖"
sub "   当前运行槽 $CURS 保持不动，随时可切回（这就是回滚点）"

# 目标槽必须【未挂载】—— 这是本脚本的核心安全检查
# ⚠️ 必须解析 system$SFX 的真实块设备，不能硬编码 mmcblk0p7x：
#   实测 200e 上 p78 = userdata（/data，永远挂载），硬编码查 p78 会把 /data 当目标槽，
#   导致【任何 B 槽烧写都被误拒】（实测踩过）。
SYS_DEV=$($ADB shell "readlink -f /dev/block/bootdevice/by-name/system$SFX 2>/dev/null" | tr -d '\r')
SYS_BASE=${SYS_DEV##*/}
case "$SYS_BASE" in
mmcblk* | sd* | nvme*) ;;
*)
	echo "ERROR: 无法解析 system$SFX 的块设备（readlink -f 返回 '$SYS_DEV'）" >&2
	exit 1
	;;
esac
sub "目标槽 system 设备: $SYS_DEV"
MOUNTED=$($ADB shell "mount | grep -cE '/dev/$SYS_BASE[[:space:]]' || true" | tr -d '\r')
if [ "${MOUNTED:-0}" != "0" ]; then
	echo "ERROR: 目标槽的 system 分区仍在挂载中（$MOUNTED 处），拒绝烧写。" >&2
	exit 1
fi
sub "目标槽 system 分区未挂载 ✅（安全检查通过）"

# system 分区大小
p_sz() { $ADB shell "blockdev --getsize64 /dev/block/bootdevice/by-name/$1 2>/dev/null" | tr -d '\r'; }
SZ_SYS=$(p_sz "system$SFX")
case "$SZ_SYS" in ''|*[!0-9]*) echo "ERROR: 无法读取 system$SFX 分区大小（返回 '$SZ_SYS'）" >&2; exit 1 ;; esac
sub "system$SFX 分区大小: $SZ_SYS 字节"

# 本次要做什么 —— 先把计划打出来，--dry-run 就到此为止
# RAW 在计划前就定好，让「计划」和「实际执行」共用同一变量
# SFX 自带下划线（_a / _b），所以结果为 flash_sys_a.raw / flash_sys_b.raw。
RAW="$TMPDIR_HOST/flash_sys${SFX}.raw"
sub "计划:"
sub "  转换 out-system/system.img -> $RAW"
sub "  推 sys.raw 到设备 /data/local/tmp"
sub "  只写 system$SFX，并回读 md5 校验"
[ "$DO_SWITCH" = 1 ] && sub "  校验通过后切到槽 $([ "$SLOT" -eq 0 ] && echo A || echo B) 并重启"

if [ "$DRY_RUN" = 1 ]; then
	echo
	echo "=== DRY-RUN 结束：只做了前置检查，未推送 / 未烧写 / 未切槽 ==="
	echo "    去掉 --dry-run 即真正执行"
	exit 0
fi

# ---- 2. system.img 转 raw（主机）----
say "2/7 转换 system.img sparse -> raw"
mkdir -p -- "$TMPDIR_HOST" || { echo "ERROR: 无法创建主机临时目录: $TMPDIR_HOST" >&2; exit 1; }
[ -d "$TMPDIR_HOST" ] && [ -w "$TMPDIR_HOST" ] && [ -x "$TMPDIR_HOST" ] || {
	echo "ERROR: 主机临时目录不可写或不可进入: $TMPDIR_HOST" >&2
	exit 1
}
avail=$(df -B1 --output=avail "$TMPDIR_HOST" | tail -1)
[ "$avail" -ge $(( 8589934592 + 1073741824 )) ] || { echo "ERROR: $TMPDIR_HOST 空间不足（需要 ~9GiB）" >&2; exit 1; }
rm -f "$RAW"
if command -v simg2img >/dev/null 2>&1; then
	simg2img "$IMG_SYS" "$RAW"
else
	[ -x "$ROOT/docker_env/build.sh" ] || {
		echo "ERROR: Host 缺少 simg2img，且找不到 Docker 构建入口: $ROOT/docker_env/build.sh" >&2
		exit 1
	}
	ROOT_REAL=$(realpath -- "$ROOT") || { echo "ERROR: 无法解析 SDK ROOT: $ROOT" >&2; exit 1; }
	TMPDIR_REAL=$(realpath -- "$TMPDIR_HOST") || { echo "ERROR: 无法解析主机临时目录: $TMPDIR_HOST" >&2; exit 1; }
	case "$TMPDIR_REAL" in
	"$ROOT_REAL" | "$ROOT_REAL"/*) ;;
	*)
		echo "ERROR: Host 缺少 simg2img，但 TMPDIR_HOST 位于 SDK ROOT 外，现有 Docker 无法安全写入: $TMPDIR_HOST" >&2
		echo "       请使用默认目录 $ROOT/.scratch/flash，或在 Host 提供 simg2img。" >&2
		exit 1
		;;
	esac
	echo "Host 缺少 simg2img，自动转入 Docker 执行 sparse -> raw..."
	printf -v SIMG2IMG_CMD 'simg2img %q %q' "$IMG_SYS" "$RAW"
	"$ROOT/docker_env/build.sh" "$SIMG2IMG_CMD" || {
		echo "ERROR: Docker 内 simg2img 转换失败" >&2
		exit 1
	}
fi
[ -s "$RAW" ] || { echo "ERROR: sparse -> raw 未生成有效文件: $RAW" >&2; exit 1; }
RAW_SIZE=$(stat -c%s "$RAW")
[ "$RAW_SIZE" = "$SZ_SYS" ] || {
	echo "ERROR: system raw 大小与 system$SFX 分区不一致，拒绝烧写。" >&2
	echo "       raw=$RAW_SIZE  partition=$SZ_SYS" >&2
	exit 1
}
sub "raw: $RAW_SIZE 字节 -> $RAW（与 system$SFX 分区大小一致）"
EXP_SYS=$(md5sum "$RAW" | cut -d' ' -f1)
sub "raw md5: $EXP_SYS"

# ---- 3. 推送 ----
say "3/7 推送到设备 /data/local/tmp"
# /data 是共享的 userdata 分区，两个槽都能访问，所以从另一个槽启动时也能用
#
# ⚠️ adb push 自己那行只打【本地源路径】（格式：`<源>: 1 file pushed, ...`），
#    所以下面每行先打印「目标」，免得把主机临时路径误当成设备路径。
ADB_TMP=/data/local/tmp
sub "$(basename "$RAW")  -> 设备 $ADB_TMP/sys.raw"
$ADB push "$RAW"      "$ADB_TMP/sys.raw"  | tail -1 | sed 's/^/    /'

# ---- 4. 校验推送完整性 ----
say "4/7 校验推送完整性"
GOT=$($ADB shell 'md5sum /data/local/tmp/sys.raw' | tr -d '\r' | awk '{print $1}')
[ "$GOT" = "$EXP_SYS" ] || { echo "ERROR: sys.raw 传输损坏 ($GOT != $EXP_SYS)" >&2; exit 1; }
sub "sys.raw md5 一致 ✅"

# ---- 5. 烧写 system ----
say "5/7 烧写 system$SFX（8GiB，约 90 秒）"
$ADB shell 'dd if=/data/local/tmp/sys.raw of=/dev/block/bootdevice/by-name/system'"$SFX"' bs=4M 2>&1; sync; sync' \
	| tr -d '\r' | tail -1 | sed 's/^/  /'

# ---- 6. 回读校验 ----
say "6/7 回读校验"
got=$($ADB exec-out "dd if=/dev/block/bootdevice/by-name/system$SFX bs=4M 2>/dev/null | md5sum" | tr -d '\r' | awk '{print $1}')
if [ "$got" = "$EXP_SYS" ]; then sub "system$SFX ✅ $got"
else
	sub "system$SFX ❌ 期望 $EXP_SYS 实际 $got"
	echo "ERROR: 回读校验失败，**不要切槽**！请重新烧写。" >&2
	exit 1
fi

# ---- 7. 收尾 ----
say "7/7 收尾"
$ADB shell 'rm -f /data/local/tmp/sys.raw' >/dev/null
rm -f "$RAW"
sub "设备与主机临时文件已清理"

if [ "$DO_SWITCH" = 1 ]; then
	sub "切到槽 $([ $SLOT -eq 0 ] && echo A || echo B) 并重启..."
	$ADB shell "/sbin/abctl --set_active $SLOT" >/dev/null
	$ADB reboot
	echo
	echo "已切槽并重启。启动后验证："
	echo "  adb shell /sbin/abctl --boot_slot                     # 应为 $SFX"
	echo "  adb shell 'ls /lib/modules/$KV/*.ko | wc -l'          # 模块数"
	echo "  adb shell 'modprobe ttynull && lsmod | grep ttynull'  # 新模块可加载"
else
	echo
	echo "烧写完成（未切槽）。切换命令："
	echo "  adb shell /sbin/abctl --set_active $SLOT && adb reboot"
	echo
	echo "回滚（随时可用，无需重刷）："
	echo "  adb shell /sbin/abctl --set_active $(( 1 - SLOT )) && adb reboot"
fi
