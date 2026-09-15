#!/usr/bin/env bash
# ============================================================================
# Quectel PI H1 (QCS6490) 文件系统打包脚本 —— 目录级可复现模型
# 命令接口与 QPi-SDK (M2) 的 tools/build-rootfs.sh 兼容
# ============================================================================
# 模型 (可复现, 不挂载修改任何镜像):
#
#   prebuilds/base_rootfs/   ← 基准目录 (从原始 system.img 提取一次, 只读)
#        │  rsync (每次构建)
#        ▼
#   build/rootfs-staging/    ← 工作目录: base + overlay + 删除清单 + hooks
#        │  mkfs.btrfs --rootdir (fakeroot 保属主)
#        ▼
#   build/result/system.img  ← 最终镜像 (全新生成, 内容 = base+overlay 决定)
#
# 免 root 说明:
#   - staging 合成 (rsync/删除/hooks) 全部免 root
#   - 打包用 fakeroot + mkfs.btrfs --rootdir, 免 root (fakeroot 伪装属主)
#   - base_rootfs 提取可用 btrfs restore 免 root (属主归一化) 或
#     sudo mount+rsync 保真 (推荐一次性提取)
#
# 用法:
#   ./tools/build-rootfs.sh check                  # 环境检查
#   ./tools/build-rootfs.sh extract [镜像] [目录]  # 建立 base 目录 (镜像→目录)
#   ./tools/build-rootfs.sh apply [镜像]           # 合成 staging (base+overlay)
#   ./tools/build-rootfs.sh repack [目录] [镜像]   # staging 目录 → system.img
#   ./tools/build-rootfs.sh build                  # = apply + repack (完整打包)
#   ./tools/build-rootfs.sh remove <路径>          # 登记删除 (overlay-remove.list)
#   ./tools/build-rootfs.sh clean                  # 清理 staging/挂载残留
#
# 环境变量:
#   OVERLAY_DIR        overlay 目录 (默认 SDK 根/overlay)
#   BASE_ROOTFS        基准目录 (默认 prebuilds/base_rootfs)
#   SYSTEM_IMG_SIZE    镜像字节数 (默认 = 原始 system.img 大小)
#   SYSTEM_IMG_UUID    镜像 UUID (默认 = 原始 system.img 的 UUID, 保证可复现)
# ============================================================================
set -uo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="$(cd "${TOOLS_DIR}/.." && pwd)"
OVERLAY_DIR="${OVERLAY_DIR:-${SDK_ROOT}/overlay}"
REMOVE_LIST="${OVERLAY_DIR}/overlay-remove.list"
PREBUILDS_DIR="${PREBUILDS_DIR:-${SDK_ROOT}/prebuilds}"
BUILD_DIR="${BUILD_DIR:-${SDK_ROOT}/build}"
OUT_DIR="${OUT_DIR:-${SDK_ROOT}/build/result}"
SRC_IMG="${SRC_IMG:-${PREBUILDS_DIR}/system.img}"
BASE_ROOTFS="${BASE_ROOTFS:-${PREBUILDS_DIR}/base_rootfs}"
STAGING="${STAGING:-${BUILD_DIR}/rootfs-staging}"
OUT_IMG="${OUT_IMG:-${OUT_DIR}/system.img}"
# 非 root 属主文件的容许上限: 原厂 rootfs 仅 /home/pi 等极少几个。
# 组包前后的校验都用这一个阈值 —— 两处必须一致, 否则会出现
# "前置检查跳过、repack 又拒绝" 的自相矛盾。
NONROOT_MAX="${NONROOT_MAX:-1000}"

SUDO="${SUDO:-sudo}"

# ---------------------------------------------------------------------------
# sudo 垫片 (供 VS Code 插件 / CI 等【非交互】场景使用)
# ---------------------------------------------------------------------------
# 问题: 本脚本用 ${SUDO} -n true 检查"凭据是否已缓存"。插件经管道执行时没有
#   tty, sudo 连密码都没法提示, 该检查必然失败 -> 整个 build 以
#   "apply 需要 root" 中止 (手动在终端跑则没事, 因为 sudo 能弹密码提示)。
# 做法: 调用方通过环境变量 QPI_SUDO_PASS 传密码。有密码时把 SUDO 换成同名函数
#   —— bash 里 ${SUDO} xxx 展开出的命令名会查找函数, 于是本脚本全部 27 处
#   ${SUDO} 调用点【无需改动】, 一律改走 sudo -A + SUDO_ASKPASS 提供密码。
# 未传密码时保持原样: 手动运行仍走系统 sudo 正常提示输入。
QPI_SUDO_PASS="${QPI_SUDO_PASS:-}"
_qpi_sudo() {
    local args=("$@")
    # 只丢掉【紧跟在 ${SUDO} 后面】的 -n (脚本用 ${SUDO} -n true 检查凭据是否已缓存;
    # -n 会阻止 sudo 询问密码, 与"已提供密码"冲突)。
    # ★ 绝不能过滤命令自己的 -n: 例如 repack 里的 ${SUDO} mkfs.btrfs -n 4096 ...
    #   那个 -n 是"节点大小", 吃掉它会把 4096 当成设备文件, mkfs 直接失败。
    if [ "${args[0]:-}" = "-n" ]; then
        args=("${args[@]:1}")
    fi

    # 用 sudo -A + SUDO_ASKPASS 提供密码, 而【不是】sudo -S 从 stdin 读。
    # 原因: 本脚本有 `echo "y" | ${SUDO} btrfstune ...` 这种靠 stdin 把确认送给
    #   命令的写法; sudo -S 会把那个 "y" 当成密码吃掉 -> btrfstune 报错。
    #   askpass 则完全不碰 stdin, 原样留给命令。
    # 密码放在 0600 的临时文件里而非环境变量: sudo 默认 env_reset 会清掉自定义
    #   变量, askpass 程序就拿不到了。两个文件都在脚本退出时删除。
    if [ -z "${_QPI_ASKPASS:-}" ]; then
        local _pw
        _QPI_PW_FILE="$(mktemp "${TMPDIR:-/tmp}/.qpi-sudo-pw.XXXXXX")"
        _QPI_ASKPASS="$(mktemp "${TMPDIR:-/tmp}/.qpi-sudo-askpass.XXXXXX")"
        printf '%s\n' "${QPI_SUDO_PASS}" > "${_QPI_PW_FILE}"
        chmod 600 "${_QPI_PW_FILE}"
        printf '#!/bin/sh\ncat %s\n' "${_QPI_PW_FILE}" > "${_QPI_ASKPASS}"
        chmod 700 "${_QPI_ASKPASS}"
        trap 'rm -f "${_QPI_ASKPASS:-}" "${_QPI_PW_FILE:-}"' EXIT
    fi
    SUDO_ASKPASS="${_QPI_ASKPASS}" sudo -A -p '' "${args[@]}"
}

# sudo 可用性检查 (统一入口, 失败时给出与场景相符的提示)
_qpi_sudo_ok() {
    local what="${1:-操作}" reason="${2:-}"
    ${SUDO} -n true 2>/dev/null && return 0
    log_err "${what} 需要 root${reason:+ (${reason})}"
    if [ -n "${QPI_SUDO_PASS}" ]; then
        log_err "  sudo 认证失败: 请确认输入的系统密码正确"
        log_err "  (插件已把密码经环境变量 QPI_SUDO_PASS 传入; 密码错会走到这里)"
    else
        log_err "  请先执行: ${SUDO} -v   (base 属主错误会导致设备无法启动)"
    fi
    return 1
}

if [ -n "${QPI_SUDO_PASS}" ] && [ "$(id -u)" != "0" ] && [ "${SUDO}" = "sudo" ]; then
    SUDO="_qpi_sudo"
fi

# ---------------------------------------------------------------------------
# 进度上报 (与 fetch-prebuilds.sh / extract-sysroot.sh 同一约定, 由插件消费)
# ---------------------------------------------------------------------------
# mount+rsync 一次要搬十几 GB, 而 rsync 默认【什么都不输出】——不打进度的话整段
# 时间界面完全静止 (用户以为卡死), 插件侧 SSE 也可能因长时间无数据被掐断。
# 这里用"后台 rsync + 每秒轮询目标目录已搬字节数"上报。
# 标记行不会显示在插件终端里 (被转成进度事件); 手工运行时能看到, 属正常现象。
emit_progress() { # <已搬运字节> <估算总字节> <整体百分比> <阶段文案>
    local done="${1:-0}" total="${2:-0}" pct="${3:-0}" label="${4:-}"
    case "${done}"  in ''|*[!0-9]*) done=0 ;; esac
    case "${total}" in ''|*[!0-9]*) total=0 ;; esac
    case "${pct}"   in ''|*[!0-9]*) pct=0 ;; esac
    [ "${pct}" -gt 100 ] && pct=100
    printf '[QPI-PROGRESS] total=%s done=%s pct=%s label=%s\n' \
        "${total}" "${done}" "${pct}" "${label}"
}

# 目录当前字节数。必须经 ${SUDO}: 这些目录里绝大多数是 root 属主文件,
# 普通用户 du 不下去, 会少算导致百分比虚低。
_dir_bytes() {
    local b
    b="$(${SUDO} du -sb "$1" 2>/dev/null | cut -f1)" || true
    case "${b}" in ''|*[!0-9]*) b=0 ;; esac
    echo "${b}"
}

# 带进度的 sudo rsync: sudo_rsync_progress <源目录> <目标目录> <阶段文案>
# 退出码原样透传 rsync 的, 调用处的错误处理不受影响。
sudo_rsync_progress() {
    local src="$1" dst="$2" label="$3"
    local total done pct rc=0 pid
    total="$(_dir_bytes "${src}")"
    ${SUDO} rsync -aHAX --numeric-ids "${src}/" "${dst}/" &
    pid=$!
    while kill -0 "${pid}" 2>/dev/null; do
        done="$(_dir_bytes "${dst}")"
        pct=0
        [ "${total}" -gt 0 ] && pct=$(( done * 100 / total ))
        [ "${pct}" -gt 100 ] && pct=100   # 目标可能已有旧内容, 封顶
        emit_progress "${done}" "${total}" "${pct}" "${label}"
        sleep 1
    done
    wait "${pid}" || rc=$?
    done="$(_dir_bytes "${dst}")"
    pct=0
    [ "${total}" -gt 0 ] && pct=$(( done * 100 / total ))
    [ "${pct}" -gt 100 ] && pct=100
    emit_progress "${done}" "${total}" "${pct}" "${label}"
    return "${rc}"
}

# 保护原版: 新生成的 system.img 必须写到独立路径 (默认 build/result/system.img),
# 绝不允许与厂商原始镜像 (prebuilds/system.img) 是同一个文件, 否则会覆盖原版。
if [ "$(readlink -f "${OUT_IMG}" 2>/dev/null || echo "${OUT_IMG}")" = \
     "$(readlink -f "${SRC_IMG}" 2>/dev/null || echo "${SRC_IMG}")" ]; then
    echo "[ERROR] OUT_IMG 与 SRC_IMG 指向同一文件, 会覆盖厂商原始镜像:" >&2
    echo "        OUT_IMG=${OUT_IMG}" >&2
    echo "        SRC_IMG=${SRC_IMG}" >&2
    echo "        原版必须保留; 请用 OUT_IMG 指定其他路径 (默认 build/result/system.img)" >&2
    exit 1
fi

# 原始镜像属性 (默认值, 保证与分区/烧录兼容)
SRC_SIZE="$(stat -c%s "${SRC_IMG}" 2>/dev/null || echo 13611565056)"
SRC_UUID="$(btrfs inspect-internal dump-super "${SRC_IMG}" 2>/dev/null | awk '/^fsid/{print $2; exit}')"
IMG_SIZE="${SYSTEM_IMG_SIZE:-${SRC_SIZE}}"
IMG_UUID="${SYSTEM_IMG_UUID:-${SRC_UUID:-185a1255-cc28-419f-b6f0-a0374671ac6d}}"

# 颜色输出 (与 M2 风格一致)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# ---------------------------------------------------------------------------
# 环境检查
# ---------------------------------------------------------------------------
check_env() {
    local ok=1
    [ -d "${OVERLAY_DIR}" ] || { log_err "缺少 overlay 目录: ${OVERLAY_DIR}"; ok=0; }
    command -v rsync >/dev/null 2>&1 || { log_err "未找到 rsync"; ok=0; }
    command -v btrfs >/dev/null 2>&1 || { log_err "未找到 btrfs-progs"; ok=0; }
    command -v fakeroot >/dev/null 2>&1 || { log_warn "未找到 fakeroot (repack 属主将不保真)"; }
    if [ ! -d "${BASE_ROOTFS}" ]; then
        log_warn "基准目录不存在: ${BASE_ROOTFS}"
        if [ ! -f "${SRC_IMG}" ]; then
            log_warn "  原始镜像也缺失: ${SRC_IMG}"
            log_info "  1) 先获取固件底包: ./tools/fetch-prebuilds.sh fetch"
            log_info "  2) 再运行: ./tools/build-rootfs.sh extract"
        else
            log_warn "  运行 ./tools/build-rootfs.sh extract 从原始镜像建立"
        fi
        if [ -d "${SDK_ROOT}/prebuilds/sysroot" ]; then
            log_info "  (检测到 prebuilds/sysroot, 将自动作为 base 源)"
        fi
    fi
    [ "${ok}" = "1" ] || { log_err "环境检查未通过"; return 1; }
    log_ok "环境检查通过"
    log_info "  overlay:     ${OVERLAY_DIR}"
    log_info "  base:        ${BASE_ROOTFS}"
    log_info "  staging:     ${STAGING}"
    log_info "  镜像大小:    $(( IMG_SIZE / 1024 / 1024 / 1024 )) GiB ($(( IMG_SIZE / 1024 / 1024 )) MiB)"
    log_info "  镜像 UUID:   ${IMG_UUID}"
    return 0
}

# 选择 base 源目录 (base_rootfs 优先, 否则 sysroot, 否则报错)
base_source() {
    if [ -d "${BASE_ROOTFS}" ]; then
        echo "${BASE_ROOTFS}"
    elif [ -d "${SDK_ROOT}/prebuilds/sysroot" ]; then
        echo "${SDK_ROOT}/prebuilds/sysroot"
    else
        # 注意: 本函数的结果经 $( ) 捕获为目录路径, 所以诊断信息必须走 stderr,
        # 否则会被调用方当成路径使用 (base_source 的返回值语义是"目录")。
        log_err "无可用基准目录: ${BASE_ROOTFS} 或 prebuilds/sysroot" >&2
        if [ ! -f "${SRC_IMG}" ]; then
            log_err "原始镜像也缺失: ${SRC_IMG}" >&2
            log_err "  1) 先获取固件底包: ./tools/fetch-prebuilds.sh fetch" >&2
            log_err "  2) 再建立基准目录: ./tools/build-rootfs.sh extract" >&2
        else
            log_err "原始镜像已就绪, 请先建立基准目录: ./tools/build-rootfs.sh extract" >&2
        fi
        return 1
    fi
}

# ---------------------------------------------------------------------------
# extract: 从镜像建立 base 目录 (镜像 → 目录)
#   ★ 必须 sudo mount + rsync 保真 (属主/权限/符号链接), 这是 rootfs 打包前提:
#     btrfs restore 会把属主归一为当前用户 → 设备 init/systemd 权限错 → 起不来
#   (提取 sysroot 用 tools/extract-sysroot.sh, 那个允许 btrfs restore 免 root,
#    因为交叉编译不依赖属主)
# ---------------------------------------------------------------------------
cmd_extract() {
    local img="${1:-${SRC_IMG}}"
    local dst="${2:-${BASE_ROOTFS}}"
    [ -f "${img}" ] || { log_err "镜像不存在: ${img}"; return 1; }
    if [ -d "${dst}" ] && [ -n "$(ls -A "${dst}" 2>/dev/null)" ]; then
        log_err "目标目录已存在且非空: ${dst} (先删除或指定其他目录)"
        return 1
    fi

    # sudo 检查 (保真提取必须 root)
    _qpi_sudo_ok "extract base" "mount+rsync 保真属主" || return 1

    mkdir -p "${dst}"
    local mnt
    mnt="$(mktemp -d)"
    log_info "mount + rsync 保真提取: ${img} → ${dst} ..."
    ${SUDO} mount -o loop,ro "${img}" "${mnt}" || { log_err "挂载失败"; rmdir "${mnt}"; return 1; }
    sudo_rsync_progress "${mnt}" "${dst}" "正在保真提取 base"
    ${SUDO} umount "${mnt}"
    rmdir "${mnt}"

    local nonroot
    nonroot="$(${SUDO} find "${dst}" -not -user 0 2>/dev/null | wc -l)"
    log_ok "提取完成: ${dst}"
    log_info "非 root 属主: ${nonroot} 个 (原厂≈2, /home/pi 等)"
    return 0
}

# ---------------------------------------------------------------------------
# 合成 staging: rsync base → staging, 应用 overlay/删除清单/hooks (免 root)
# ---------------------------------------------------------------------------
apply_overlay() {
    local src
    src="$(base_source)" || return 1
    [ -d "${OVERLAY_DIR}" ] || { log_err "overlay 目录不存在: ${OVERLAY_DIR}"; return 1; }

    log_info "合成 staging: ${src} → ${STAGING}"
    ${SUDO} rm -rf "${STAGING}"
    ${SUDO} mkdir -p "${STAGING}"

    # sudo 检查 (保真复制需要 root 保留属主; 普通 cp -a 会把 root 属主变自己)
    _qpi_sudo_ok "apply" "保真复制 base 属主" || return 1

    # 1. base → staging (reflink 优先, 快且省空间; sudo 保留属主)
    ${SUDO} cp -a --reflink=auto "${src}/." "${STAGING}/" 2>/dev/null \
        || ${SUDO} rsync -aHAX --numeric-ids "${src}/" "${STAGING}/"

    # 2. overlay → staging: 用 cp --parents 逐文件复制
    #    ★ 不用 rsync: rsync 会更新已存在父目录的属性 (如 /lib 777→755),
    #      污染 base 目录权限 → 设备启动失败
    #    cp --parents 只复制文件本身, 不碰已存在的父目录; 新目录自动创建
    log_info "应用 overlay: ${OVERLAY_DIR}"
    (cd "${OVERLAY_DIR}" && find . -type f ! -name 'overlay-remove.list' | \
        while IFS= read -r f; do
            rel="${f#./}"
            ${SUDO} cp -a --parents "${rel}" "${STAGING}/" 2>/dev/null \
                || ${SUDO} install -D -m 755 "${rel}" "${STAGING}/${rel}"
        done)

    # 3. 额外 overlay (同上)
    if [ -n "${EXTRA_OVERLAY:-}" ] && [ -d "${EXTRA_OVERLAY}" ]; then
        log_info "应用额外 overlay: ${EXTRA_OVERLAY}"
        (cd "${EXTRA_OVERLAY}" && find . -type f | \
            while IFS= read -r f; do
                rel="${f#./}"
                ${SUDO} cp -a --parents "${rel}" "${STAGING}/" 2>/dev/null \
                    || ${SUDO} install -D -m 755 "${rel}" "${STAGING}/${rel}"
            done)
    fi

    # 4. 删除清单
    if [ -f "${REMOVE_LIST}" ]; then
        log_info "处理删除清单: ${REMOVE_LIST}"
        while IFS= read -r line; do
            case "${line}" in
                ""|\#*) continue ;;
            esac
            p="${line%%#*}"
            p="$(echo "${p}" | xargs)"
            [ -n "${p}" ] || continue
            case "${p}" in
                /*) rel="${p#/}" ;;
                *) rel="${p}" ;;
            esac
            if [ -e "${STAGING}/${rel}" ] || [ -L "${STAGING}/${rel}" ]; then
                echo "    rm -rf /${rel}"
                rm -rf "${STAGING}/${rel}"
            fi
        done < "${REMOVE_LIST}"
    fi

    # 5. hooks (目录级执行, 免 root; IMG_MNT=staging 兼容原 hook 接口)
    HOOKS_DIR="${HOOKS_DIR:-${SDK_ROOT}/hooks}"
    if [ -d "${HOOKS_DIR}" ]; then
        log_info "执行 pre-pack hooks: ${HOOKS_DIR}"
        for hook in "${HOOKS_DIR}"/*.sh; do
            [ -f "${hook}" ] || continue
            echo "    >>> 执行 hook: $(basename "${hook}")"
            IMG_MNT="${STAGING}" \
            OUT_IMG="${OUT_IMG}" \
            SRC_IMG="${SRC_IMG}" \
            OVERLAY_DIR="${OVERLAY_DIR}" \
            BUILD_DIR="${BUILD_DIR}" \
            SDK_ROOT="${SDK_ROOT}" \
            KERNEL_RELEASE="${KERNEL_RELEASE:-}" \
            bash "${hook}"
        done
    fi

    log_ok "staging 合成完成: ${STAGING}"
    echo "  文件数: $(find "${STAGING}" -type f | wc -l)  大小: $(du -sh "${STAGING}" | cut -f1)"
    return 0
}

# ---------------------------------------------------------------------------
# repack: staging 目录 → BTRFS 镜像 (确定性固定大小, 可复现)
#   流程: mkfs -b <原镜像大小> 空 BTRFS → tune UUID → 挂载 → rsync 填充 staging
#   注意: 不用 --rootdir (btrfs-progs 5.16 对大目录忽略 -b 自动扩展,
#         产出 17.9GB 超 GPT system 分区 → 烧录后内核挂 rootfs 失败重启)
#   依赖: sudo (挂载), rsync
# ---------------------------------------------------------------------------
repack_img() {
    local src="${1:-${STAGING}}"
    local img="${2:-${OUT_IMG}}"
    [ -d "${src}" ] || { log_err "目录不存在: ${src} (先 apply)"; return 1; }
    command -v btrfs >/dev/null 2>&1 || { log_err "缺少 btrfs-progs (mkfs.btrfs)"; return 1; }
    command -v rsync >/dev/null 2>&1 || { log_err "缺少 rsync"; return 1; }

    # sudo 检查 (挂载填充需要)
    _qpi_sudo_ok "repack" "mount loop 填充 staging" || return 1

    local size_mb=$(( IMG_SIZE / 1024 / 1024 ))
    log_info "打包: ${src} → ${img}"
    log_info "  大小: ${size_mb} MiB (固定, 与原镜像一致)   UUID: ${IMG_UUID}"

    mkdir -p "$(dirname "${img}")"
    rm -f "${img}"

    # 1. 先 truncate 创建固定大小文件 (mkfs 要求目标存在, 否则 mount-check 误报)
    log_info "[1/3] 创建 ${IMG_SIZE} bytes 镜像文件 ..."
    rm -f "${img}"
    truncate -s "${IMG_SIZE}" "${img}"

    # 2. mkfs 固定大小 BTRFS, 参数与原厂镜像一致
    #    -n 4096: 原厂 nodesize=4096 (默认 16384 会开 BIG_METADATA, 与原厂 0x341 不符)
    log_info "[2/3] mkfs.btrfs -b ${IMG_SIZE} -n 4096 ..."
    if ! ${SUDO} mkfs.btrfs -f -b "${IMG_SIZE}" -n 4096 "${img}"; then
        log_err "mkfs.btrfs 失败"
        return 1
    fi

    # 3. tune UUID 为原镜像 UUID (可复现: 每次产物 UUID 一致)
    #    btrfstune 需交互确认, 用 yes 管道自动应答; 若系统已占用该 UUID 会失败
    log_info "[3/3] btrfstune UUID → ${IMG_UUID} ..."
    if ! echo "y" | ${SUDO} btrfstune -U "${IMG_UUID}" "${img}" 2>/dev/null; then
        log_warn "btrfstune 失败 (UUID 被占用或系统已有同 UUID 挂载)"
        log_warn "  提示: 检查 lsblk/findmnt 是否有同 UUID 的已挂载 BTRFS, 卸载后重试"
        log_warn "  或设置 SYSTEM_IMG_UUID=random 跳过固定 (用随机 UUID)"
        return 1
    fi

    # 4. 挂载 + rsync 填充 staging (属主已由保真 base 决定, 不做 chown)
    #    注意: base 必须用 sudo mount+rsync 保真提取 (见 extract 命令);
    #          btrfs restore 提取会把属主归一为当前用户 → 设备起不来
    log_info "[4/4] 挂载填充 staging ..."
    local mnt
    mnt="$(mktemp -d)"
    if ! ${SUDO} mount -o loop "${img}" "${mnt}"; then
        log_err "挂载失败"
        rmdir "${mnt}"
        return 1
    fi
    sudo_rsync_progress "${src}" "${mnt}" "正在写入 system.img"
    ${SUDO} sync
    ${SUDO} umount "${mnt}"
    rmdir "${mnt}"

    # 校验: 非 root 属主文件数应远小于总数 (原厂仅 /home/pi 等少量)
    local nonroot
    nonroot="$(${SUDO} find "${src}" -not -user 0 2>/dev/null | wc -l)"
    local total
    total="$(${SUDO} find "${src}" 2>/dev/null | wc -l)"
    log_info "属主校验: 非 root ${nonroot}/${total} 个 (base≈2, overlay 定制文件会少量增加)"
    if [ "${nonroot}" -gt "${NONROOT_MAX}" ]; then
        log_err "非 root 属主文件过多 (${nonroot}), base 可能用 btrfs restore 提取过"
        log_err "请用 sudo 重新 extract (mount+rsync 保真): sudo ./tools/build-rootfs.sh extract"
        return 1
    fi

    log_ok "打包完成: ${img} ($(stat -c%s "${img}") bytes)"
    log_ok "实际占用: $(du -h "${img}" | cut -f1)"
    return 0
}

# ---------------------------------------------------------------------------
# 保真 base 保障: 打包 system.img 前, 必须有一个"属主正确"的 base 目录
# ---------------------------------------------------------------------------
# 背景: 组包要求 base 内绝大多数文件属主为 root (设备 init/systemd 依赖属主)。
#   - prebuilds/sysroot      由 extract-sysroot.sh 用 btrfs restore 【免 root】解出,
#                            属主会被归一为当前用户; 它只用于【交叉编译】, 不能打包
#   - prebuilds/base_rootfs  由 `extract` 用 sudo mount+rsync 【保真】提取, 打包用它
# 若 base_rootfs 缺失而直接 build, 会一路跑到最后 repack 的属主校验才失败, 提示
# "请用 sudo 重新 extract"。而插件的 build all 没有入口去单独执行 extract, 用户就
# 卡死在这里 —— 所以这里在 build 之前自动补上这一步。
# 单独跑 apply/repack 时行为不变 (仍由 repack 的校验兜底并给出原提示)。
ensure_faithful_base() {
    if [ -d "${BASE_ROOTFS}" ]; then
        return 0
    fi
    local src="${SDK_ROOT}/prebuilds/sysroot"
    if [ -d "${src}" ]; then
        local nonroot
        nonroot="$(find "${src}" -not -user 0 2>/dev/null | wc -l)"
        if [ "${nonroot}" -le "${NONROOT_MAX}" ]; then
            # 属主本来就是对的 (如用户手工保真提取过), 不必多跑一次 13GB 复制
            log_info "现有 base 属主正常 (非 root ${nonroot} 个), 无需保真提取"
            return 0
        fi
        log_warn "现有 base 属主不保真: ${src} 有 ${nonroot} 个非 root 文件"
        log_warn "  该目录是 btrfs restore 免 root 解出的, 只能用于交叉编译。"
        log_info "打包需要属主为 root 的 base, 现在自动执行保真提取 (mount+rsync)..."
    else
        log_info "缺少打包基准目录, 现在执行保真提取: ${BASE_ROOTFS} ..."
    fi
    cmd_extract || {
        log_err "保真提取失败, 无法打包 system.img"
        log_err "  可手工重试: sudo ./tools/build-rootfs.sh extract"
        return 1
    }
    return 0
}

# ---------------------------------------------------------------------------
# build: apply + repack (完整打包)
# ---------------------------------------------------------------------------
cmd_build() {
    ensure_faithful_base || return 1
    apply_overlay || return 1
    repack_img || return 1
    log_ok "system.img 打包完成: ${OUT_IMG}"
    log_info "烧录: ./scripts/flash.sh (或参考 build/result/ 内 rawprogram xml)"
    return 0
}

# ---------------------------------------------------------------------------
# remove: 登记删除路径到 overlay-remove.list (声明式, 下次打包生效)
# ---------------------------------------------------------------------------
cmd_remove() {
    local target="${1:-}"
    [ -n "${target}" ] || { log_err "用法: $0 remove <路径>"; return 1; }
    mkdir -p "${OVERLAY_DIR}"

    local rel
    case "${target}" in
        /*) rel="${target#/}" ;;
        *)  rel="${target}" ;;
    esac

    if [ -f "${REMOVE_LIST}" ] && grep -qxF "${rel}" "${REMOVE_LIST}" 2>/dev/null; then
        log_warn "已在删除清单中: /${rel}"
    else
        echo "${rel}" >> "${REMOVE_LIST}"
        log_ok "已登记删除: /${rel} → ${REMOVE_LIST}"
    fi
    log_info "下次打包生效: ./tools/build-rootfs.sh build"
}

# ---------------------------------------------------------------------------
# clean: 清理 staging 与挂载残留
# ---------------------------------------------------------------------------
cmd_clean() {
    local mnt
    for mnt in "${SDK_ROOT}/build/system-mnt" "${SDK_ROOT}/build/efi-mnt" "${SDK_ROOT}/build/dtb-mnt"; do
        if mountpoint -q "${mnt}" 2>/dev/null; then
            log_info "卸载残留挂载: ${mnt}"
            ${SUDO} umount "${mnt}" 2>/dev/null || log_warn "卸载失败: ${mnt}"
        fi
        [ -d "${mnt}" ] && rmdir "${mnt}" 2>/dev/null
    done
    rm -rf "${STAGING}"
    log_ok "清理完成"
}

usage() {
    echo "用法: $0 <命令>"
    echo "  check                     环境检查"
    echo "  extract [镜像] [目录]     建立 base 目录 (默认 prebuilds/base_rootfs)"
    echo "  apply                     合成 staging (base + overlay + hooks)"
    echo "  repack [目录] [镜像]      staging → system.img (mkfs.btrfs, fakeroot)"
    echo "  build                     完整打包 (= apply + repack)"
    echo "  remove <路径>             登记删除 (overlay-remove.list)"
    echo "  clean                     清理 staging/挂载残留"
    echo ""
    echo "模型: base目录 + overlay → staging → mkfs 全新生成 system.img (可复现, 不挂载修改)"
    echo "环境变量: OVERLAY_DIR, BASE_ROOTFS, SYSTEM_IMG_SIZE, SYSTEM_IMG_UUID, EXTRA_OVERLAY"
}

main() {
    local cmd="${1:-help}"
    case "${cmd}" in
        check)   check_env ;;
        extract) cmd_extract "${2:-}" "${3:-}" ;;
        apply)   apply_overlay ;;
        repack)  repack_img "${2:-}" "${3:-}" ;;
        build)   cmd_build ;;
        remove)  cmd_remove "${2:-}" ;;
        clean)   cmd_clean ;;
        help|*)  usage ;;
    esac
}

main "$@"
