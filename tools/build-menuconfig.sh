#!/bin/bash

set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/config/platforms.sh"
dt_platform_ensure || { echo "ERROR: 档位未定（见 config/platforms.sh）" >&2; exit 1; }

if [ "${DT_PLATFORM_SRC:-default}" = default ]; then
	echo "ERROR: 档位未能确认，拒绝编辑默认档位对应的内核配置。" >&2
	echo "       请先放入目标档位固件包并执行 buildenv，再运行 buildmenuconfig。" >&2
	exit 1
fi

if [ ! -t 0 ] || [ ! -t 1 ]; then
	echo "ERROR: buildmenuconfig 需要前台终端 TTY，不能在后台或非交互环境运行。" >&2
	exit 1
fi

CONFIG="$ROOT/$DT_KCONFIG"
OUT="$ROOT/out-kernel"
WORK_CONFIG="$OUT/msm-kernel/.config"
TMP_CONFIG=""

cleanup() {
	[ -z "$TMP_CONFIG" ] || rm -f "$TMP_CONFIG"
}
trap cleanup EXIT HUP INT TERM

[ -f "$CONFIG" ] || { echo "ERROR: 缺少内核配置 $CONFIG" >&2; exit 1; }
[ -r "$CONFIG" ] || { echo "ERROR: 内核配置不可读: $CONFIG" >&2; exit 1; }
[ -w "$CONFIG" ] || { echo "ERROR: 内核配置不可写: $CONFIG" >&2; exit 1; }

# menuconfig 的 ncurses 编译与交互统一放进现有 Docker 环境。docker.run 会设置
# WORKDIR；保留该判断是为了兼容用户已经通过 docker_env/build.sh --interactive
# 进入容器后再调用 buildmenuconfig 的用法，避免嵌套启动 Docker。
if [ "${QPI_MENUCONFIG_IN_DOCKER:-}" != 1 ] && [ "${WORKDIR:-}" != "$ROOT" ]; then
	printf -v SCRIPT_Q '%q' "$ROOT/tools/build-menuconfig.sh"
	"$ROOT/docker_env/build.sh" --interactive \
		"QPI_MENUCONFIG_IN_DOCKER=1 $SCRIPT_Q"
	exit $?
fi

rm -rf "$OUT"
mkdir -p "$OUT/msm-kernel"
cp -f "$CONFIG" "$OUT/.config"
cp -f "$CONFIG" "$WORK_CONFIG"

echo "平台: $DT_PLATFORM_EFF（来源: $DT_PLATFORM_SRC_DESC）"
echo "配置: $DT_KCONFIG"

cd "$ROOT/kernel"
QPI_DEBIAN_BUILD=1 \
FULL_CONFIG_MODE=1 \
BUILD_CONFIG=./msm-kernel/build.config.msm.bengal.le \
VARIANT=consolidate \
OUT_DIR="$OUT" \
./build/kernel/config.sh menuconfig
cd "$ROOT"

[ -s "$WORK_CONFIG" ] || { echo "ERROR: menuconfig 未生成有效的完整 .config" >&2; exit 1; }
grep -q '^CONFIG_ARM64=y$' "$WORK_CONFIG" || {
	echo "ERROR: menuconfig 结果缺少 CONFIG_ARM64=y，不写回 $DT_KCONFIG" >&2
	exit 1
}

TMP_CONFIG=$(mktemp "$(dirname "$CONFIG")/.$(basename "$CONFIG").tmp.XXXXXX")
cp -f "$WORK_CONFIG" "$TMP_CONFIG"
chmod --reference="$CONFIG" "$TMP_CONFIG"

if cmp -s "$CONFIG" "$TMP_CONFIG"; then
	echo "内核配置未发生变化: $DT_KCONFIG"
	exit 0
fi

mv -f "$TMP_CONFIG" "$CONFIG"
TMP_CONFIG=""
echo "内核配置已保存: $DT_KCONFIG"
