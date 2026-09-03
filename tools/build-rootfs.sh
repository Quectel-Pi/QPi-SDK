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
#   build/output/system.img  ← 最终镜像 (全新生成, 内容 = base+overlay 决定)
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
SRC_IMG="${SDK_ROOT}/prebuilds/system.img"
BASE_ROOTFS="${BASE_ROOTFS:-${SDK_ROOT}/prebuilds/base_rootfs}"
STAGING="${SDK_ROOT}/build/rootfs-staging"
OUT_IMG="${SDK_ROOT}/build/output/system.img"
SUDO="${SUDO:-sudo}"

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
        log_warn "  运行 ./tools/build-rootfs.sh extract 从原始镜像建立"
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
        log_err "无可用基准目录: ${BASE_ROOTFS} 或 prebuilds/sysroot"
        log_err "先运行: ./tools/build-rootfs.sh extract"
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
    if ! ${SUDO} -n true 2>/dev/null; then
        log_err "extract base 需要 root (mount+rsync 保真属主)"
        log_err "请先执行: ${SUDO} -v   (base 属主错误会导致设备无法启动)"
        return 1
    fi

    mkdir -p "${dst}"
    local mnt
    mnt="$(mktemp -d)"
    log_info "mount + rsync 保真提取: ${img} → ${dst} ..."
    ${SUDO} mount -o loop,ro "${img}" "${mnt}" || { log_err "挂载失败"; rmdir "${mnt}"; return 1; }
    ${SUDO} rsync -aHAX --numeric-ids "${mnt}/" "${dst}/"
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
    if ! ${SUDO} -n true 2>/dev/null; then
        log_err "apply 需要 root (保真复制 base 属主)"
        log_err "请先执行: ${SUDO} -v   (base 属主错误会导致设备无法启动)"
        return 1
    fi

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
            BUILD_DIR="${SDK_ROOT}/build" \
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
    if ! ${SUDO} -n true 2>/dev/null; then
        log_err "repack 需要 root (mount loop 填充 staging)"
        log_err "请先执行: ${SUDO} -v   (或 ${SUDO} -n 配置免密)"
        return 1
    fi

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
    ${SUDO} rsync -aHAX --numeric-ids "${src}/" "${mnt}/"
    ${SUDO} sync
    ${SUDO} umount "${mnt}"
    rmdir "${mnt}"

    # 校验: 非 root 属主文件数应远小于总数 (原厂仅 /home/pi 等少量)
    local nonroot
    nonroot="$(${SUDO} find "${src}" -not -user 0 2>/dev/null | wc -l)"
    local total
    total="$(${SUDO} find "${src}" 2>/dev/null | wc -l)"
    log_info "属主校验: 非 root ${nonroot}/${total} 个 (base≈2, overlay 定制文件会少量增加)"
    if [ "${nonroot}" -gt 1000 ]; then
        log_err "非 root 属主文件过多 (${nonroot}), base 可能用 btrfs restore 提取过"
        log_err "请用 sudo 重新 extract (mount+rsync 保真): sudo ./tools/build-rootfs.sh extract"
        return 1
    fi

    log_ok "打包完成: ${img} ($(stat -c%s "${img}") bytes)"
    log_ok "实际占用: $(du -h "${img}" | cut -f1)"
    return 0
}

# ---------------------------------------------------------------------------
# build: apply + repack (完整打包)
# ---------------------------------------------------------------------------
cmd_build() {
    apply_overlay || return 1
    repack_img || return 1
    log_ok "system.img 打包完成: ${OUT_IMG}"
    log_info "烧录: ./scripts/flash.sh (或参考 build/output/ 内 rawprogram xml)"
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
