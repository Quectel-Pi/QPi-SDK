#!/bin/bash
# ============================================================
# simple-h1 system.img 打包脚本 (overlay 机制)
# 功能:
#   1. 解压/挂载原始 system.img
#   2. 应用 overlay/ 目录中的增量文件 (追加/覆盖)
#   3. 执行 overlay-remove.list 中的删除清单 (可选)
#   4. 执行 hooks/*.sh pre-pack 钩子 (可选, chmod/cp/ln 等最后调整)
#   5. 重新打包 system.img
# 用法: ./scripts/pack-system.sh
#   OVERLAY_DIR 环境变量可指定其他 overlay 目录
# ============================================================
set -e
cd "$(dirname "$0")/.."
source scripts/env.sh

SRC_IMG="${PREBUILDS_DIR}/system.img"
OUT_IMG="${OUT_DIR}/system.img"
MNT="${BUILD_DIR}/system-mnt"
REMOVE_LIST="${OVERLAY_DIR}/overlay-remove.list"

# ${SUDO} 支持: 默认 sudo; 可用环境变量 SUDO 覆盖 (如 SUDO="sudo -n")
SUDO="${SUDO:-sudo}"
if ! ${SUDO} -n true 2>/dev/null; then
    echo "[simple-h1] 需要 root 权限, 请先执行: ${SUDO} -v"
    ${SUDO} -v
fi

# 用户可用环境变量指定额外 overlay
EXTRA_OVERLAY="${EXTRA_OVERLAY:-}"

[ -f "${SRC_IMG}" ] || { echo "[ERROR] 原始镜像不存在: ${SRC_IMG}"; exit 1; }

echo "=========================================="
echo "[simple-h1] 打包 system.img"
echo "  原始镜像:  ${SRC_IMG}"
echo "  Overlay:   ${OVERLAY_DIR}"
echo "  输出:      ${OUT_IMG}"
echo "=========================================="

# 1. 复制原始镜像
rm -f "${OUT_IMG}"
cp "${SRC_IMG}" "${OUT_IMG}"

# 2. 挂载
mkdir -p "${MNT}"
echo "[simple-h1] 挂载 ${OUT_IMG} ..."
${SUDO} mount -o loop,rw "${OUT_IMG}" "${MNT}"

# 3. 应用 overlay
if [ -d "${OVERLAY_DIR}" ]; then
    echo "[simple-h1] 应用 overlay: ${OVERLAY_DIR}"
    # 使用 rsync 保留权限/属主/符号链接; 排除删除清单自身
    ${SUDO} rsync -aHAX --numeric-ids \
        --exclude='overlay-remove.list' \
        "${OVERLAY_DIR}/" "${MNT}/"
fi

# 3b. 合并新编译的内核模块 (若存在, 覆盖 system.img 中的旧模块)
MOD_STAGE="${BUILD_DIR}/modules-staging/lib/modules/${KERNEL_RELEASE}"
if [ -d "${MOD_STAGE}" ]; then
    echo "[simple-h1] 合并新编译内核模块: ${MOD_STAGE}"
    ${SUDO} rsync -aHAX --numeric-ids "${MOD_STAGE}/" "${MNT}/lib/modules/${KERNEL_RELEASE}/"
fi

# 4. 额外 overlay
if [ -n "${EXTRA_OVERLAY}" ] && [ -d "${EXTRA_OVERLAY}" ]; then
    echo "[simple-h1] 应用额外 overlay: ${EXTRA_OVERLAY}"
    ${SUDO} rsync -aHAX --numeric-ids "${EXTRA_OVERLAY}/" "${MNT}/"
fi

# 5. 删除清单
if [ -f "${REMOVE_LIST}" ]; then
    echo "[simple-h1] 处理删除清单: ${REMOVE_LIST}"
    while IFS= read -r line; do
        # 忽略注释和空行
        case "$line" in
            ""|\#*) continue ;;
        esac
        # 去掉行内注释和首尾空白
        p="${line%%#*}"
        p="$(echo "$p" | xargs)"
        [ -n "$p" ] || continue
        # 防止路径逃逸
        case "$p" in
            /*) rel="${p#/}" ;;
            *) rel="$p" ;;
        esac
        if [ -e "${MNT}/${rel}" ] || [ -L "${MNT}/${rel}" ]; then
            echo "    rm -rf /${rel}"
            ${SUDO} rm -rf "${MNT}/${rel}"
        fi
    done < "${REMOVE_LIST}"
fi

# 5b. 执行 pre-pack hooks (可选): 打包前对镜像内文件做最后调整
# 用法: 在 ${HOOKS_DIR:-hooks/} 放置 *.sh, 按文件名顺序执行 (root 身份)
# 环境变量: IMG_MNT=挂载点, OUT_IMG=输出镜像, SRC_IMG=原始镜像,
#           OVERLAY_DIR/BUILD_DIR/SDK_ROOT/KERNEL_RELEASE
# 示例: chmod/cp/ln 等操作, 路径必须以 ${IMG_MNT} 为前缀
HOOKS_DIR="${HOOKS_DIR:-${SDK_ROOT}/hooks}"
if [ -d "${HOOKS_DIR}" ]; then
    echo "[simple-h1] 执行 pre-pack hooks: ${HOOKS_DIR}"
    for hook in "${HOOKS_DIR}"/*.sh; do
        [ -f "${hook}" ] || continue
        echo "    >>> 执行 hook: $(basename "${hook}")"
        IMG_MNT="${MNT}" \
        OUT_IMG="${OUT_IMG}" \
        SRC_IMG="${SRC_IMG}" \
        OVERLAY_DIR="${OVERLAY_DIR}" \
        BUILD_DIR="${BUILD_DIR}" \
        SDK_ROOT="${SDK_ROOT}" \
        KERNEL_RELEASE="${KERNEL_RELEASE}" \
        ${SUDO} bash "${hook}"
    done
fi

# 6. 同步并卸载
${SUDO} sync
${SUDO} umount "${MNT}"
rmdir "${MNT}"

echo ""
echo "[simple-h1] system.img 打包完成 ✓"
echo "  输出: ${OUT_IMG} ($(stat -c%s "${OUT_IMG}") bytes)"
