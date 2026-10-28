#!/usr/bin/env bash
# ============================================================================
# QPi-SDK 内核上游同步工具
# ============================================================================
# 背景:
#   SDK 的 kernel/ 是从完整源码仓库 (RK3576_Linux6.1_BL01_v1.2.0) 的
#   kernel-6.1/ 目录整体提取出来的，提取点记录在 tools/upstream/base.txt。
#   SDK 自身对内核的定制放在 tools/upstream/local/ (镜像 kernel/ 内的路径)。
#
# 用法:
#   ./tools/sync-upstream.sh report            # 只读: 看上游有哪些改动 / 冲突风险
#   ./tools/sync-upstream.sh report --to <ref> # 指定目标提交/分支(默认上游 HEAD)
#   ./tools/sync-upstream.sh snapshot          # 重新抓取“本地定制”快照(改了内核后跑)
#   ./tools/sync-upstream.sh apply [--to ref]  # 真正同步(先做冲突预检, 有冲突则不落盘)
#   ./tools/sync-upstream.sh apply --dry-run   # 只预演: 预检 + 变更清单, 一个字节都不写
#
# 环境变量:
#   UPSTREAM_SRC  上游仓库路径(默认 /home/q/work/linux/RK3576_Linux6.1_BL01_v1.2.0)
#
# 设计原则:
#   1. 只同步上游 “跟踪的源文件”, 不碰 kernel/.config 与任何编译产物
#   2. 本地定制(tools/upstream/local/)用 git merge-file 做三方合并
#      - 能自动合并 → 直接用
#      - 有冲突 → 预检阶段就中止, kernel/ 一个字节都不会被改
#   3. 上游删除的文件会被删除, 但本地定制过的文件保留并告警
# ============================================================================
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/.." && pwd)"
UP_DIR="$TOOLS_DIR/upstream"
KERNEL_DIR="$ROOT_DIR/kernel"
STATE="$UP_DIR/base.txt"
LOCAL_DIR="$UP_DIR/local"
SUBDIR="kernel-6.1"
SRC="${UPSTREAM_SRC:-/home/q/work/linux/RK3576_Linux6.1_BL01_v1.2.0}"
TMP=""   # 全局, 供 trap 清理 (函数内 local 变量在 EXIT trap 时已失效)

# 颜色 (非终端/NO_COLOR 时自动降级为空)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    CYAN=$'\033[36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }
die()  { err "$*"; exit 1; }

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------
# 基础检查
# ---------------------------------------------------------------------------
require_env() {
    git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1 || die "上游仓库不存在: $SRC"
    [ -d "$KERNEL_DIR" ] || die "缺少 SDK 内核目录: $KERNEL_DIR"
    [ -f "$STATE" ] || die "缺少状态文件: $STATE"
}

get_base() {
    local b
    b="$(sed -n 's/^commit=//p' "$STATE" | head -1)"
    [ -n "$b" ] || die "$STATE 中没有 commit= 记录"
    git -C "$SRC" rev-parse --verify "$b^{commit}" >/dev/null 2>&1 \
        || die "基准提交 $b 在上游仓库中不存在(是否换了仓库/被 rebase?)"
    echo "$b"
}

resolve_target() {
    local ref="${1:-HEAD}"
    local target
    target="$(git -C "$SRC" rev-parse --verify "$ref^{commit}" 2>/dev/null)" \
        || die "无法解析目标提交: $ref"
    git -C "$SRC" merge-base --is-ancestor "$BASE" "$target" \
        || die "目标不是当前基准的后继提交，拒绝跨分支/回退同步: $ref"
    echo "$target"
}

# 本地定制文件是否被上游改过 (0=改过)
local_changed_upstream() {
    ! git -C "$SRC" diff --quiet "$BASE" "$TARGET" -- "$SUBDIR/$1"
}

is_local() { [ -f "$LOCAL_DIR/$1" ] || [ -L "$LOCAL_DIR/$1" ]; }

local_files() {
    [ -d "$LOCAL_DIR" ] || return 0
    (cd "$LOCAL_DIR" && find . \( -type f -o -type l \) | sed 's|^\./||' | sort)
}

# 上游“消失”的路径: 删除(D) + 重命名(R) 的旧路径。输出相对 kernel/ 的路径。
upstream_removed_paths() {
    git -C "$SRC" --no-pager diff -M --name-status "$BASE..$TARGET" -- "$SUBDIR" |
    awk -F'\t' -v p="$SUBDIR/" '
        $1 == "D"                { print substr($2, length(p) + 1) }
        substr($1, 1, 1) == "R"  { print substr($2, length(p) + 1) }
    '
}

# 上游重命名明细: "旧路径 -> 新路径"
upstream_renames() {
    git -C "$SRC" --no-pager diff -M --name-status "$BASE..$TARGET" -- "$SUBDIR" |
    awk -F'\t' -v p="$SUBDIR/" 'substr($1,1,1) == "R" {
        print "  R " substr($2, length(p)+1) "  ->  " substr($3, length(p)+1)
    }'
}

# ---------------------------------------------------------------------------
# 本地漂移校验: kernel/ 中是否有“未被 tools/upstream/local/ 收录”的改动
#   没有这一步, 这些改动会在 apply 覆盖上游源文件时被静默冲掉。
# ---------------------------------------------------------------------------
check_local_sync() {
    local tmpd out rc=0
    tmpd="$(mktemp -d /tmp/qpi-drift.XXXXXX)"
    if ! /usr/bin/python3 "$UP_DIR/scan-local.py" "$SRC" "$SUBDIR" "$BASE" \
            "$KERNEL_DIR" "$tmpd" >"$tmpd.log" 2>&1; then
        cat "$tmpd.log" >&2
        err "本地定制扫描失败，禁止同步"
        rm -rf "$tmpd" "$tmpd.log"; return 1
    fi
    if [ -d "$LOCAL_DIR" ]; then
        out="$(diff -r "$LOCAL_DIR" "$tmpd" 2>&1 || true)"
    else
        out="$(find "$tmpd" -type f | sed "s|^$tmpd/|  + |")"
    fi
    if [ -n "$out" ]; then
        warn "kernel/ 存在未纳入 tools/upstream/local/ 的本地改动 (同步会被覆盖):"
        echo "$out" | head -20 | sed 's/^/    /'
        warn "先执行 ./tools/sync-upstream.sh snapshot 刷新本地定制快照"
        rc=1
    fi
    rm -rf "$tmpd" "$tmpd.log"
    return "$rc"
}

# ---------------------------------------------------------------------------
# report: 只读报告
# ---------------------------------------------------------------------------
cmd_report() {
    local target_ref="HEAD"
    while [ $# -gt 0 ]; do
        case "$1" in
            --to) target_ref="$2"; shift 2 ;;
            *) die "未知参数: $1" ;;
        esac
    done
    BASE="$(get_base)"; TARGET="$(resolve_target "$target_ref")"

    echo "=================================================================="
    echo " 上游同步预检报告"
    echo "   上游仓库 : $SRC"
    echo "   基准提交 : $(git -C "$SRC" log -1 --format='%h %ad %s' --date=short "$BASE")"
    echo "   目标提交 : $(git -C "$SRC" log -1 --format='%h %ad %s' --date=short "$TARGET")"
    echo "=================================================================="

    local n
    n="$(git -C "$SRC" rev-list --count "$BASE..$TARGET" -- "$SUBDIR")"
    if [ "$BASE" = "$TARGET" ]; then
        check_local_sync || return 1
        ok "已是最新，且本地快照一致"
        return 0
    fi

    echo
    echo "--- 待同步提交 ($n 个) ---"
    git -C "$SRC" --no-pager log --date=short --format='  %h %ad %s' "$BASE..$TARGET" -- "$SUBDIR"

    echo
    echo "--- 变更规模 ---"
    git -C "$SRC" --no-pager diff --shortstat "$BASE..$TARGET" -- "$SUBDIR" | sed 's/^/  /'

    echo
    echo "--- 新增文件 (按目录, Top 15) ---"
    git -C "$SRC" --no-pager diff --diff-filter=A --name-only "$BASE..$TARGET" -- "$SUBDIR" \
        | sed "s|^$SUBDIR/||" | awk -F/ 'NF>1{print $1"/"$2} NF==1{print $1}' \
        | sort | uniq -c | sort -rn | head -15 | sed 's/^/  /'

    echo
    echo "--- 上游删除 / 重命名(旧路径会被移除) ---"
    local dels
    dels="$(upstream_removed_paths)"
    if [ -z "$dels" ]; then
        echo "  (无)"
    else
        local one
        while IFS=$'\t' read -r st a b; do
            case "$st" in
                D*) echo "  D ${a#$SUBDIR/}" ;;
                R*) echo "  R ${a#$SUBDIR/}  ->  ${b#$SUBDIR/}" ;;
                *)  : ;;
            esac
        done < <(git -C "$SRC" --no-pager diff -M --name-status "$BASE..$TARGET" -- "$SUBDIR")
        if echo "$dels" | grep -q '\.dts$'; then
            warn "有设备树源文件被移除: kernel/ 下同名的 .dtbo 构建产物需要手工清理(否则会被打进固件)"
        fi
    fi

    echo
    echo "--- SDK 本地定制 vs 上游改动 (冲突风险) ---"
    local f risky=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if ! git -C "$SRC" cat-file -e "$TARGET:$SUBDIR/$f" 2>/dev/null; then
            warn "上游已删除, 但 SDK 有本地定制: $f"
            risky=$((risky+1))
        elif local_changed_upstream "$f"; then
            warn "上游也改了: $f  (apply 时会做三方合并, 冲突则中止)"
            risky=$((risky+1))
        fi
    done < <(local_files)
    [ "$risky" -eq 0 ] && echo "  (无, 本地定制文件上游均未改动)"

    echo
    echo "--- 本地定制快照一致性 ---"
    if check_local_sync; then
        echo "  (一致: kernel/ 的本地改动都已收录到 tools/upstream/local/)"
    fi

    echo
    echo "--- 新增/变动的内核配置片段 (arch/arm64/configs) ---"
    local cfgs
    cfgs="$(git -C "$SRC" --no-pager diff --diff-filter=A --name-only "$BASE..$TARGET" -- "$SUBDIR/arch/arm64/configs/")"
    if [ -z "$cfgs" ]; then
        echo "  (无)"
    else
        echo "$cfgs" | sed "s|^$SUBDIR/arch/arm64/configs/|  + |"
        warn "请核对这些片段是否已登记到构建入口；新文件不代表功能自动生效"
    fi

    echo
    echo "--- 官方 M2 Debian 构建使用的片段列表 ---"
    local cfgfile="device/rockchip/.chips/rk3576/rockchip_rk3576_quectel_pi_m2_debian_defconfig"
    git -C "$SRC" show "$BASE:$cfgfile" 2>/dev/null | grep -m1 'RK_KERNEL_CFG_FRAGMENTS' | sed 's/^/  base   : /' \
        || echo "  base   : (该文件在基准提交中不存在)"
    git -C "$SRC" show "$TARGET:$cfgfile" 2>/dev/null | grep -m1 'RK_KERNEL_CFG_FRAGMENTS' | sed 's/^/  target : /' \
        || echo "  target : (该文件在目标提交中不存在)"

    echo
    echo "--- SDK 自带(上游没有)的配置片段 ---"
    local k
    for k in "$KERNEL_DIR"/arch/arm64/configs/*.config; do
        [ -f "$k" ] || continue
        local bn; bn="$(basename "$k")"
        git -C "$SRC" cat-file -e "$TARGET:$SUBDIR/arch/arm64/configs/$bn" 2>/dev/null || echo "  * $bn (目标上游没有)"
    done

    echo
    echo "--- 设备树 overlay 列表变动 (dts Makefile) ---"
    git -C "$SRC" --no-pager diff "$BASE..$TARGET" -- "$SUBDIR/arch/arm64/boot/dts/rockchip/Makefile" \
        | grep -E '^[-+].*dtbo' | sed 's/^/  /' || echo "  (无)"

    echo
    echo "------------------------------------------------------------------"
    echo "下一步: ./tools/sync-upstream.sh apply --dry-run   # 预演(不写盘)"
    echo "        ./tools/sync-upstream.sh apply             # 确认后执行"
    echo "------------------------------------------------------------------"
}

# ---------------------------------------------------------------------------
# snapshot: 重新采集本地定制
# ---------------------------------------------------------------------------
cmd_snapshot() {
    BASE="$(get_base)"
    info "扫描 $KERNEL_DIR 相对上游 $BASE 的本地定制 ..."
    /usr/bin/python3 "$UP_DIR/scan-local.py" "$SRC" "$SUBDIR" "$BASE" "$KERNEL_DIR" "$LOCAL_DIR"
    ok "快照已写入 $LOCAL_DIR"
    echo "  后续 apply 会把这些文件自动合并回同步后的内核树。"
}

# ---------------------------------------------------------------------------
# apply: 执行同步
# ---------------------------------------------------------------------------
cmd_apply() {
    local target_ref="HEAD" force=0 dry_run=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --to) target_ref="$2"; shift 2 ;;
            --force) die "不支持 --force：禁止绕过漂移/冲突保护" ;;
            --dry-run|-n) dry_run=1; shift ;;
            *) die "未知参数: $1" ;;
        esac
    done
    BASE="$(get_base)"; TARGET="$(resolve_target "$target_ref")"

    if ! git -C "$SRC" diff --quiet -- "$SUBDIR" || [ -n "$(git -C "$SRC" ls-files -o --exclude-standard -- "$SUBDIR" | head -1)" ]; then
        warn "上游 $SUBDIR 有未提交改动, 同步内容以提交 $TARGET 为准"
    fi
    if [ -n "$(git -C "$SRC" status --porcelain --untracked-files=no -- "$SUBDIR")" ]; then
        warn "上游 $SUBDIR 有未提交的已跟踪改动, 同步内容以提交 $TARGET 为准"
    fi
    if [ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=no -- kernel 2>/dev/null | head -1)" ]; then
        warn "当前 SDK 的 kernel/ 有未提交改动(已跟踪文件); 建议先 git add/commit 以便回滚"
    fi

    info "固定同步目标: $TARGET (源分支: $(git -C "$SRC" branch --show-current))"

    info "[0/5] 校验本地定制快照"
    if ! check_local_sync; then
        if [ "$force" -eq 0 ]; then
            die "已中止 (kernel/ 未做任何修改)。先 snapshot, 或加 --force 强制继续。"
        fi
        warn "--force: 忽略未纳入快照的本地改动"
    else
        ok "  kernel/ 的本地改动均已收录"
    fi

    [ "$BASE" = "$TARGET" ] && { ok "已是最新 ($TARGET)，快照一致"; return 0; }

    TMP="$(mktemp -d /tmp/qpi-sync.XXXXXX)"
    trap 'rm -rf "$TMP"' EXIT

    info "[1/5] 导出上游 $TARGET:$SUBDIR → $TMP/up"
    mkdir -p "$TMP/up"
    git -C "$SRC" archive "$TARGET" "$SUBDIR" | tar -x -C "$TMP/up" --strip-components=1
    [ -f "$TMP/up/Makefile" ] || die "导出上游内核树失败"

    info "[2/5] 冲突预检 (git merge-file, 不落盘)"
    local conflicts=() merges=() f rc
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if ! git -C "$SRC" cat-file -e "$TARGET:$SUBDIR/$f" 2>/dev/null; then
            if git -C "$SRC" cat-file -e "$BASE:$SUBDIR/$f" 2>/dev/null; then
                die "上游删除了本地定制文件，需人工解决删除/改名冲突: $f"
            fi
            info "  SDK 独有文件保持不变: $f"
            continue
        fi
        [ ! -L "$LOCAL_DIR/$f" ] && [ ! -L "$TMP/up/$f" ] \
            || die "不支持对符号链接进行文本三方合并: $f"
        git -C "$SRC" show "$BASE:$SUBDIR/$f" > "$TMP/base.f" 2>/dev/null || : > "$TMP/base.f"
        cp -f "$TMP/up/$f" "$TMP/new.f" 2>/dev/null || : > "$TMP/new.f"
        rc=0
        mkdir -p "$TMP/merged/$(dirname "$f")"
        if cmp -s "$TMP/new.f" "$LOCAL_DIR/$f"; then
            cp -p "$LOCAL_DIR/$f" "$TMP/merged/$f"
        else
            git merge-file -p "$TMP/new.f" "$TMP/base.f" "$LOCAL_DIR/$f" > "$TMP/merged/$f" 2>/dev/null || rc=$?
            chmod --reference="$LOCAL_DIR/$f" "$TMP/merged/$f"
        fi
        if [ "$rc" -ne 0 ]; then
            conflicts+=("$f")
            warn "  冲突: $f"
        else
            merges+=("$f")
            ok "  可自动合并: $f"
        fi
    done < <(local_files)

    if [ ${#conflicts[@]} -gt 0 ] && [ "$force" -eq 0 ]; then
        err "存在 ${#conflicts[@]} 个冲突文件, 已中止 (kernel/ 未做任何修改):"
        printf '    %s\n' "${conflicts[@]}"
        echo "  处理方式: 手动对比 上游新版本 / tools/upstream/local/ 里的本地版本,"
        echo "            改好 tools/upstream/local/ 后重新 apply, 或加 --force 保留本地版本继续。"
        exit 2
    fi

    # --dry-run: 预检通过后只打印变更清单, 不写盘
    if [ "$dry_run" -eq 1 ]; then
        echo
        echo "--- 预演结果 (未写入任何文件) ---"
        local add=0 mod=0 del=0 ren=0 st p
        while IFS=$'\t' read -r st p; do
            case "$st" in
                A*) add=$((add+1)) ;;
                M*) mod=$((mod+1)) ;;
                D*) del=$((del+1)) ;;
                R*) ren=$((ren+1)) ;;
            esac
        done < <(git -C "$SRC" --no-pager diff -M --name-status "$BASE..$TARGET" -- "$SUBDIR" \
                 | sed "s|$SUBDIR/||")
        echo "  新增 $add / 修改 $mod / 删除 $del / 重命名 $ren"
        echo
        echo "  受影响目录 (Top 15):"
        git -C "$SRC" --no-pager diff --name-only "$BASE..$TARGET" -- "$SUBDIR" \
            | sed "s|^$SUBDIR/||" | awk -F/ '{if (NF>2) print $1"/"$2; else if (NF>1) print $1; else print "(根目录)"}' \
            | sort | uniq -c | sort -rn | head -15 | sed 's/^/    /'
        echo
        ok "预检通过: 本地定制 ${#merges[@]} 个可自动合并, ${#conflicts[@]} 个冲突"
        echo "  确认无误后执行: ./tools/sync-upstream.sh apply --to ${target_ref}"
        exit 0
    fi

    info "[3/5] 移除上游已删除/重命名掉的文件"
    local rel d stale=()
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        rel="$d"
        if is_local "$rel"; then
            warn "  跳过(本地有定制): $rel"
            continue
        fi
        if [ -e "$KERNEL_DIR/$rel" ] || [ -L "$KERNEL_DIR/$rel" ]; then
            rm -f "$KERNEL_DIR/$rel"
            echo "  D $rel"
        fi
        case "$rel" in
            *.dts) [ -f "$KERNEL_DIR/${rel%.dts}.dtbo" ] && stale+=("${rel%.dts}.dtbo") ;;
        esac
    done < <(upstream_removed_paths)
    if [ ${#stale[@]} -gt 0 ]; then
        for d in "${stale[@]}"; do
            rm -f "$KERNEL_DIR/$d" && echo "  D $d (残留 dtbo)"
        done
    fi

    info "[4/5] 覆盖上游源文件 (不动 .config / 编译产物)"
    (cd "$TMP/up" && tar -cf - .) | (cd "$KERNEL_DIR" && tar -xf -)

    info "[5/5] 回放本地定制 (三方合并结果)"
    for f in "${merges[@]:-}"; do
        [ -n "${f:-}" ] || continue
        cp -p "$TMP/merged/$f" "$KERNEL_DIR/$f"
        echo "  M $f"
    done
    for f in "${conflicts[@]:-}"; do
        [ -n "${f:-}" ] || continue
        cp -f "$LOCAL_DIR/$f" "$KERNEL_DIR/$f"
        warn "  --force: 用本地版本覆盖: $f"
    done

    local previous_base="$BASE"
    sed -i "s/^commit=.*/commit=$TARGET/" "$STATE"
    BASE="$TARGET"
    /usr/bin/python3 "$UP_DIR/scan-local.py" "$SRC" "$SUBDIR" "$BASE" "$KERNEL_DIR" "$LOCAL_DIR"
    # 源码同步完成后配置必须重建，但先保留用户旧配置作对照。
    if [ -f "$KERNEL_DIR/.config" ]; then
        mv "$KERNEL_DIR/.config" "$KERNEL_DIR/.config.before-sync.$(date +%Y%m%d_%H%M%S)"
    fi
    ok "同步完成: $previous_base → $TARGET (已更新 $(basename "$STATE"))"

    cat <<EOF

==================== 同步后必做 ====================
1) 重新生成内核配置 (旧 .config 不会自动带上新片段):
     FORCE_DEFCONFIG=1 ./tools/build-kernel.sh kernel
2) 如需核对配置差异:
     diff <(grep -v '^#' kernel/.config) <(grep -v '^#' kernel/.config.old)
3) 编译内核 + 打包:
     ./tools/build-kernel.sh all
4) 上板冒烟测试 (见 skills/sdk-board-test)，重点回归:
     WiFi/BT、显示(HDMI/DSI)、摄像头、PCIe(5G/NVMe)、USB0、RTC、休眠唤醒、reboot
5) 核对变更后按团队流程准备提交；脚本不会暂存/提交/推送。
    prebuilds/ 与 demo/ 不属于提交内容。
====================================================
EOF
}

main() {
    local cmd="${1:-report}"; shift || true
    case "$cmd" in
        report)   require_env; cmd_report "$@" ;;
        snapshot) require_env; cmd_snapshot ;;
        apply)    require_env; cmd_apply "$@" ;;
        -h|--help|help) usage ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
