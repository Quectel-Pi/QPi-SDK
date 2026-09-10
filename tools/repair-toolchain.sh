#!/usr/bin/env bash
set -uo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK="${1:-$(cd "${TOOLS_DIR}/.." && pwd)}"
TC="${SDK}/toolchains/gcc"
UNI="${SDK}/toolchains/uninative-lib"

C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_B='\033[0;36m'; C_N='\033[0m'
info() { echo -e "${C_B}[INFO]${C_N}  $*"; }
ok()   { echo -e "${C_G}[ OK ]${C_N}  $*"; }
warn() { echo -e "${C_Y}[WARN]${C_N}  $*"; }
err()  { echo -e "${C_R}[FAIL]${C_N}  $*"; }

echo "SDK       = $SDK"
echo "toolchain = $TC"
echo "uninative = $UNI"

[ -d "$TC" ]  || { err "缺少工具链目录: $TC"; exit 1; }
[ -d "$UNI" ] || { err "缺少 uninative-lib: $UNI"; exit 1; }

command -v patchelf >/dev/null 2>&1 || {
    err "缺少 patchelf"
    echo "  安装: sudo apt-get install -y patchelf"
    exit 1
}

SYS_LOADER=""
for p in /lib64/ld-linux-x86-64.so.2 \
         /lib/ld-linux-x86-64.so.2 \
         /usr/lib64/ld-linux-x86-64.so.2 \
         /usr/lib/ld-linux-x86-64.so.2; do
    if [ -e "$p" ]; then
        SYS_LOADER="$p"
        break
    fi
done
if [ -z "$SYS_LOADER" ]; then
    SYS_LOADER="$(find /lib64 /lib /usr/lib64 /usr/lib -maxdepth 3 -name 'ld-linux-x86-64.so.2' 2>/dev/null | head -1)"
fi
[ -n "$SYS_LOADER" ] && [ -e "$SYS_LOADER" ] || { err "找不到 ld-linux-x86-64.so.2"; exit 1; }
info "目标解释器: $SYS_LOADER (FHS 标准路径, 跨发行版可移植)"

mapfile -t FILES < <(find "$TC" -type f 2>/dev/null | sort -u)
info "候选文件: ${#FILES[@]}"

FIXED=0
SKIP=0
FAIL=0

for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    hdr="$(head -c4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    [ "$hdr" = "7f454c46" ] || continue

    bindir="$(dirname "$f")"
    rel="$(realpath --relative-to="$bindir" "$TC" 2>/dev/null)"
    [ -n "$rel" ] || continue
    want="\$ORIGIN/$rel/uninative-lib:\$ORIGIN/$rel/lib"

    cur="$(readelf -l "$f" 2>/dev/null | grep -oP '(?<=program interpreter: ).*' | tr -d ']')"
    if [ -n "$cur" ] && [ "$cur" != "$SYS_LOADER" ]; then
        if patchelf --set-interpreter "$SYS_LOADER" "$f" 2>/dev/null; then
            FIXED=$((FIXED+1))
        else
            FAIL=$((FAIL+1)); warn "解释器修复失败: $f"; continue
        fi
    else
        SKIP=$((SKIP+1))
    fi

    oldrp="$(patchelf --print-rpath "$f" 2>/dev/null || true)"
    keep=""
    if [ -n "$oldrp" ]; then
        IFS=':' read -ra parts <<< "$oldrp"
        for p in "${parts[@]}"; do
            case "$p" in
                *uninative-lib*|*/lib) : ;;
                "") : ;;
                *) keep="${keep:+$keep:}$p" ;;
            esac
        done
    fi
    if [ -n "$keep" ]; then
        patchelf --set-rpath "$want:$keep" "$f" 2>/dev/null || true
    else
        patchelf --set-rpath "$want" "$f" 2>/dev/null || true
    fi
done

info "修复解释器: $FIXED   无需修: $SKIP   失败: $FAIL"

echo
info "校验"
GCC="$TC/bin/aarch64-qcom-linux/aarch64-qcom-linux-gcc"
if [ -x "$GCC" ]; then
    "$GCC" --version 2>&1 | head -1
    TMPD="$(mktemp -d)"
    printf 'int probe(void){return 0;}\n' > "$TMPD/p.c"
    if "$GCC" -c "$TMPD/p.c" -o "$TMPD/p.o" 2>/dev/null; then
        ok "交叉编译自检通过: $(file -b "$TMPD/p.o" 2>/dev/null | cut -d, -f1-2)"
    else
        err "交叉编译自检失败"
    fi
    rm -rf "$TMPD"
fi

echo
info "解释器分布"
find "$TC" -type f -exec sh -c '
  h=$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d " \n")
  [ "$h" = "7f454c46" ] || exit 0
  i=$(readelf -l "$1" 2>/dev/null | grep -oP "(?<=program interpreter: ).*" | tr -d "]")
  [ -n "$i" ] && echo "$i"
' _ {} \; 2>/dev/null | sort | uniq -c

LEFTOVER="$(find "$TC" -type f -exec sh -c '
  h=$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d " \n")
  [ "$h" = "7f454c46" ] || exit 0
  i=$(readelf -l "$1" 2>/dev/null | grep -oP "(?<=program interpreter: ).*" | tr -d "]")
  case "$i" in *'/home/'*) echo "$1" ;; esac
' _ {} \; 2>/dev/null | wc -l)"
if [ "$LEFTOVER" = "0" ]; then
    ok "无硬编码解释器路径, 工具链自包含且可重定位"
else
    warn "仍有 $LEFTOVER 个文件指向硬编码路径"
fi
