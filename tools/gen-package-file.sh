#!/usr/bin/env bash
# ============================================================================
# 生成 Rockchip 固件打包清单 package-file
# ============================================================================
# 背景:
#   afptool -pack 依赖 package-file 决定“哪些文件打进 update.img、落到哪个分区”。
#   从 update.img 解包时它不一定被一起拷出来（extract-base.sh 缺文件时会漏），
#   缺了它 buildall/`build-kernel.sh all` 就会在 check_env 阶段直接失败。
#
# 本脚本按 parameter.txt 的 mtdparts 分区顺序生成清单，规则与官方一致:
#   - persist / nvdata / nvdata1 / nvdata2  是保留区，不写行（不打进 update.img）
#   - backup / ota_bak                     写 RESERVED
#   - 其余分区: <name>.img 存在则写文件行, 不存在写 RESERVED 并告警
#
# 用法:
#   ./tools/gen-package-file.sh                 # 生成到 prebuilds/base_image/
#   ./tools/gen-package-file.sh --force         # 已存在也重新生成
#   ./tools/gen-package-file.sh --dir <目录>    # 指定固件目录(含 parameter.txt)
#   ./tools/gen-package-file.sh --print         # 只打印内容, 不写文件
#
# 退出码:
#   0  已存在且内容一致 / 已生成
#   1  生成失败（缺参数文件且无可用的内置默认）
#   2  核心分区镜像缺失（已生成, 但打包会不完整）—— 见末尾告警
# ============================================================================
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/.." && pwd)"

DIR="$ROOT_DIR/prebuilds/base_image"
FORCE=0
PRINT_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)   DIR="$2"; shift 2 ;;
        --force|-f) FORCE=1; shift ;;
        --print|-p) PRINT_ONLY=1; shift ;;
        -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

[ -d "$DIR" ] || { echo "目录不存在: $DIR" >&2; exit 1; }

PARAM="$DIR/parameter.txt"
OUT="$DIR/package-file"

# --- 分区顺序: 优先解析 parameter.txt 的 mtdparts, 否则用官方默认顺序 ---
DEFAULT_PARTS="persist nvdata1 nvdata2 uboot misc boot recovery backup rootfs ota_bak oem userdata"

parts=""
if [ -f "$PARAM" ]; then
    parts="$(grep -m1 '^CMDLINE:' "$PARAM" 2>/dev/null \
             | grep -oE '\([A-Za-z0-9_]+\)' \
             | tr -d '()' | tr '\n' ' ' || true)"
fi
if [ -z "${parts// /}" ]; then
    echo "[WARN] 未能从 $PARAM 解析分区, 使用内置默认顺序" >&2
    parts="$DEFAULT_PARTS"
fi

# --- 生成内容 ---
# 头部固定三行: package-file 自身 / 分区表 / 引导加载器
content="# NAME	PATH
package-file	package-file
parameter	parameter.txt
bootloader	MiniLoaderAll.bin"

# 不打包的保留区（官方也不出现在清单里）
is_skipped() {
    case "$1" in
        persist|nvdata|nvdata1|nvdata2) return 0 ;;
        *) return 1 ;;
    esac
}

# 默认为 RESERVED 的分区（即使有镜像也按官方写法保留）
is_reserved() {
    case "$1" in
        backup|ota_bak) return 0 ;;
        *) return 1 ;;
    esac
}

missing=""
for p in $parts; do
    is_skipped "$p" && continue
    if is_reserved "$p"; then
        content="$content
$p	RESERVED"
        continue
    fi
    if [ -f "$DIR/$p.img" ]; then
        content="$content
$p	$p.img"
    else
        content="$content
$p	RESERVED"
        missing="$missing $p"
    fi
done

if [ "$PRINT_ONLY" -eq 1 ]; then
    printf '%s\n' "$content"
    exit 0
fi

# --- 写入（幂等） ---
if [ -f "$OUT" ] && [ "$FORCE" -eq 0 ]; then
    if [ "$(cat "$OUT")" = "$content" ]; then
        echo "[OK] $OUT 已存在且内容一致, 跳过"
        exit 0
    fi
    echo "[INFO] $OUT 已存在但与参数表不一致, 更新内容"
fi

printf '%s\n' "$content" > "$OUT"
echo "[OK] 已生成 $OUT"
echo "     ($(grep -cve '^\s*$' "$OUT") 行, 依据 $( [ -f "$PARAM" ] && echo "$PARAM" || echo "内置默认" ))"

if [ -n "$missing" ]; then
    echo "[WARN] 以下分区缺少镜像文件, 已写 RESERVED:$missing" >&2
    echo "[WARN] 完整打包请补齐:$(for p in $missing; do printf ' %s.img' "$p"; done)" >&2
    exit 2
fi
exit 0
