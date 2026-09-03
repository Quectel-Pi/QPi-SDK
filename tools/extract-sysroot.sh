#!/usr/bin/env bash
# ============================================================================
# extract-sysroot.sh - 从 rootfs.img (ext4) 完整提取交叉编译 sysroot
# ============================================================================
# 背景: prebuilds/sysroot 其实就是 rootfs.img 解出来的完整根文件系统,
#       但直接 7z 解压会丢失符号链接 (7z 把 symlink 当普通文件解,
#       内容=target 字符串), 导致 13437 个 .so 链接全坏, 交叉编译崩溃。
#
# 本脚本方案 (免 root, 无 sudo 依赖):
#   1. 7z 解压全部文件 (符号链接变成"内容=target"的占位普通文件)
#   2. debugfs 批量枚举镜像中所有目录里的符号链接路径 (mode 以 12 开头)
#   3. 用占位文件内容作为 target, rm + ln -s 重建符号链接
#   4. 清空 /dev (设备节点无法非 root 创建, 交叉编译不需要, 与现有 sysroot 一致)
#   5. 修复权限 (7z 解出的权限受 umask 影响, 统一为 644/755)
#   6. 验证: 符号链接数量 / libc.so 链接脚本 / 关键头文件 / 交叉编译 hello
#
# 用法:
#   ./tools/extract-sysroot.sh                        # 默认: prebuilds/base_image/rootfs.img -> prebuilds/sysroot
#   ./tools/extract-sysroot.sh <rootfs.img> <输出目录>
#   FORCE=1 ./tools/extract-sysroot.sh                # 输出目录已存在时自动备份为 sysroot.bak.<时间戳>
#
# 依赖: p7zip (7z), e2fsprogs (debugfs)   (均为免 root 工具)
# ============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${1:-$ROOT_DIR/prebuilds/base_image/rootfs.img}"
OUT="${2:-$ROOT_DIR/prebuilds/sysroot}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# --- 前置检查 --------------------------------------------------------------
for t in 7z debugfs; do
    command -v "$t" >/dev/null 2>&1 || { log_err "缺少依赖工具: $t (请先安装 p7zip-full 和 e2fsprogs)"; exit 1; }
done
[ -f "$IMG" ] || { log_err "rootfs.img 不存在: $IMG"; exit 1; }

need_mb=$(du -m "$IMG" | cut -f1)
avail_mb=$(df -Pm "$(dirname "$OUT")" | awk 'NR==2{print $4}')
log_info "rootfs.img: $(du -h "$IMG" | cut -f1) (解压后约 ${need_mb}MB), 目标分区可用 ${avail_mb}MB"
if [ "$avail_mb" -lt $((need_mb * 2)) ]; then
    log_err "磁盘空间不足: 需要约 $((need_mb * 2))MB (镜像 + 解压), 可用 ${avail_mb}MB"
    exit 1
fi

# --- 输出目录处理 -----------------------------------------------------------
if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then
    if [ "${FORCE:-0}" = "1" ]; then
        BAK="${OUT}.bak.$(date +%Y%m%d%H%M%S)"
        mv "$OUT" "$BAK"
        log_warn "旧 sysroot 已备份到: $BAK"
    else
        log_err "输出目录已存在且非空: $OUT"
        log_err "请先删除/备份, 或设置 FORCE=1 自动备份"
        exit 1
    fi
fi
mkdir -p "$OUT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 1/5: 7z 解压全部 (设备节点解压失败可忽略) -------------------------------
log_info "[1/5] 7z 解压 rootfs.img → $OUT ..."
7z x -y "$IMG" -o"$OUT" >/dev/null 2>&1 || true
log_ok "解压完成: $(find "$OUT" -type f | wc -l) 个文件"

# --- 2/5: debugfs 枚举符号链接 ----------------------------------------------
log_info "[2/5] debugfs 枚举镜像内符号链接 ..."
# 目录 -> debugfs 命令 (根目录=/, 子目录=/usr 等, 不能有双斜杠)
find "$OUT" -type d | sed "s#^$OUT##" | awk '{ if ($0=="") print "ls -l /"; else print "ls -l " $0 }' > "$WORK/dirs.cmd"
sort -u -o "$WORK/dirs.cmd" "$WORK/dirs.cmd"

debugfs -f "$WORK/dirs.cmd" "$IMG" > "$WORK/lsout.txt" 2>/dev/null

# 解析: "debugfs: ls -l /path" 回显行是目录标记; 条目行 mode 以 12 开头 => 符号链接
# (debugfs 条目行行首有空格, inode 在 $1, mode 在 $2, 文件名在 $NF)
# 注意: "debugfs: ls -l " 后接路径, 用 index 取第一个 '/' 避免取到前导空格
awk '
/^debugfs: ls -l / { dir = substr($0, index($0, "/")); next }
$1 ~ /^[0-9]+$/ && $2 ~ /^12/ && $NF != "." && $NF != ".." {
    if (dir == "/") print "/" $NF; else print dir "/" $NF
}
' "$WORK/lsout.txt" > "$WORK/symlinks.txt"

nlinks=$(wc -l < "$WORK/symlinks.txt")
log_info "发现 $nlinks 个符号链接, 开始重建 ..."

# --- 3/5: 重建符号链接 (target 取 7z 占位内容, 目录冲突时用 debugfs Fast link dest) ---
rebuilt=0
skipped=0
while IFS= read -r p; do
    f="$OUT$p"
    # 跳过 dev/ 下的 (最后会整体清空)
    case "$p" in /dev/*|/dev) continue ;; esac
    if [ ! -L "$f" ]; then
        # 7z 会把符号链接解成占位文件, 但若该符号链接同时是其他路径的父目录,
        # 7z 会把它解成"空目录" (如 /lib -> usr/lib). 非空目录不可删 (数据保护)
        if [ -d "$f" ] && [ -n "$(ls -A "$f" 2>/dev/null)" ]; then
            log_warn "  跳过非空目录 (疑似符号链接冲突): $p"
            skipped=$((skipped + 1))
            continue
        fi
        # target 优先用 7z 占位文件内容 (已验证正确); 目录/缺失时用 debugfs:
        #   fast link (≤60B) -> stat 的 Fast link dest; 长链接 -> cat (读数据块)
        if [ -f "$f" ]; then
            target=$(tr -d '\n\r' < "$f")
        else
            target=$(debugfs -R "stat $p" "$IMG" 2>/dev/null | sed -n 's/.*Fast link dest: "\(.*\)"/\1/p' | head -1)
            [ -z "$target" ] && target=$(debugfs -R "cat $p" "$IMG" 2>/dev/null | tr -d '\n\r')
        fi
        if [ -z "$target" ]; then
            log_warn "  无法获取 target, 跳过: $p"
            skipped=$((skipped + 1))
            continue
        fi
        rm -rf "$f"
        ln -s "$target" "$f"
        rebuilt=$((rebuilt + 1))
    fi
done < "$WORK/symlinks.txt"
log_ok "符号链接重建完成: $rebuilt 个 (跳过 $skipped)"

# --- 4/5: 清空 /dev + 修复权限 ----------------------------------------------
log_info "[3/5] 处理 /dev 与权限 ..."
rm -rf "$OUT/dev"
mkdir -p "$OUT/dev"

# 7z 解出的权限受 umask 影响, 统一修正 (与现有 sysroot 一致: 目录 755, 文件 644)
find "$OUT" -type d -exec chmod 755 {} +
find "$OUT" -type f -exec chmod 644 {} +
# 可执行目录补 x: rootfs 内的 gcc/clang 及其 libexec/cc1 需要可执行权限
for d in bin sbin usr/bin usr/sbin usr/libexec; do
    [ -d "$OUT/$d" ] && find "$OUT/$d" -type f -exec chmod 755 {} +
done

# --- 5/5: 验证 ---------------------------------------------------------------
log_info "[4/5] 验证解压结果 ..."
ok=1
chk() { # 描述 判断命令
    if eval "$2"; then log_ok "  ✓ $1"; else log_err "  ✗ $1"; ok=0; fi
}
nlink_now=$(find "$OUT" -type l | wc -l)
chk "符号链接数量 ($nlink_now 个, 期望 >13000)" "[ $nlink_now -gt 13000 ]"
chk "libc.so 是链接脚本 (含 GROUP/INPUT)" "grep -q 'GROUP\|INPUT' '$OUT/usr/lib/aarch64-linux-gnu/libc.so'"
chk "libc.so.6 存在" "[ -e '$OUT/usr/lib/aarch64-linux-gnu/libc.so.6' ]"
chk "关键头文件 stdio.h 存在" "[ -f '$OUT/usr/include/stdio.h' ]"
chk "dev/ 为空" "[ -z \"\$(ls -A '$OUT/dev')\" ]"

log_info "[5/5] 交叉编译冒烟测试 ..."
CC=""
NEED_B=0
if [ -x "$ROOT_DIR/toolchains/m2-debian-rootfs-toolchain/bin/aarch64-linux-gnu-gcc" ]; then
    CC="$ROOT_DIR/toolchains/m2-debian-rootfs-toolchain/bin/aarch64-linux-gnu-gcc"
elif command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    CC="aarch64-linux-gnu-gcc"
elif [ -x "$ROOT_DIR/toolchains/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-gcc" ]; then
    CC="$ROOT_DIR/toolchains/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-gcc"
    NEED_B=1
fi
if [ -n "$CC" ]; then
    echo '#include <stdio.h>' > "$WORK/hello.c"
    echo 'int main(void){printf("sysroot ok\\n");return 0;}' >> "$WORK/hello.c"
    if [ "$NEED_B" = "1" ]; then
        EXTRA_LD=( -B"$OUT/usr/lib/aarch64-linux-gnu" )
    else
        EXTRA_LD=()
    fi
    # 与 environment-setup.sh 一致: 需要 multiarch include + 库路径; wrapper 用 QPI_SYSROOT 指向当前 OUT
    if QPI_SYSROOT="$OUT" "$CC" --sysroot="$OUT" \
        -I"$OUT/usr/include" -I"$OUT/usr/include/aarch64-linux-gnu" \
        "${EXTRA_LD[@]}" \
        -L"$OUT/usr/lib/aarch64-linux-gnu" -L"$OUT/lib/aarch64-linux-gnu" \
        -o "$WORK/hello" "$WORK/hello.c" 2>"$WORK/cc.err"; then
        if file "$WORK/hello" | grep -q 'aarch64'; then
            log_ok "  ✓ 交叉编译成功: $(file -b "$WORK/hello" | cut -c1-60)"
        else
            log_err "  ✗ 产物不是 aarch64 ELF"; ok=0
        fi
    else
        if grep -q 'relr\|unknown type' "$WORK/cc.err"; then
            log_warn "  ✗ 交叉编译链接失败: 新解压的 rootfs glibc 版本较新"
            log_warn "    (当前链接器不支持 .relr.dyn, 见 cc.err 摘要):"
        else
            log_err "  ✗ 交叉编译失败:"
        fi
        head -5 "$WORK/cc.err" | sed 's/^/    /'
    fi
else
    log_warn "  未找到交叉 gcc, 跳过编译验证"
fi

echo
if [ "$ok" = "1" ]; then
    log_ok "sysroot 提取完成且验证通过: $OUT"
    echo "  文件数: $(find "$OUT" -type f | wc -l)  目录: $(find "$OUT" -type d | wc -l)  符号链接: $nlink_now"
else
    log_err "sysroot 提取完成但有验证未通过, 请检查上方 ✗ 项"
    exit 1
fi
