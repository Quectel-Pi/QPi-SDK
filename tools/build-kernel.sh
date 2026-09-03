#!/usr/bin/env bash
# ============================================================================
# Quectel PI M2 (RK3576) Kernel SDK - 一键构建脚本
# ============================================================================
# 功能: 编译内核 → 生成 FIT boot.img → 替换底包 boot 分区 → 重新打包 update.img
#
# 用法:
#   ./tools/build-kernel.sh        # 一键构建完整固件
#   ./tools/build-kernel.sh kernel # 仅编译内核 (产物在 kernel/boot.img)
#   ./tools/build-kernel.sh boot   # 仅生成 FIT boot.img
#   ./tools/build-kernel.sh overlays # 仅编译设备树 overlays (overlay/*.dts)
#   ./tools/build-kernel.sh clean  # 清理构建产物
#
# 产物:
#   build/result/update.img   # 可直接烧录的完整固件 (替换了 boot 分区)
#   build/result/boot.img     # 单独的内核 boot 镜像 (可单独烧 boot 分区)
#   build/overlays/           # 编译的设备树 overlays (.dtbo, 已写入 rootfs /boot/overlays/)
#
# 环境变量:
#   TOOLCHAIN_DIR             # 指定工具链目录 (默认自动检测)
#   JOBS                      # 并行编译数 (默认 nproc)
# ============================================================================
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/.." && pwd)"
KERNEL_DIR="$ROOT_DIR/kernel"
BASE_IMAGE_DIR="$ROOT_DIR/prebuilds/base_image"
PACK_TOOL_DIR="$TOOLS_DIR/pack_tools"
BOOT_DIR="$TOOLS_DIR/boot"
WORK_DIR="$ROOT_DIR/build"
IMAGE_DIR="$WORK_DIR/Image"
RESULT_DIR="$WORK_DIR/result"

# --- 板级常量 (来自 M2 Debian defconfig: rockchip_rk3576_quectel_pi_m2_debian_defconfig) ---
DTS_NAME="rk3576-quectel-pi-m2-linux"          # RK_KERNEL_DTS_NAME
DEFCONFIG="rockchip_linux_defconfig"           # RK_KERNEL_CFG
# 与官方 M2 构建 (mk-kernel.sh do_make_kernel_config) 保持一致:
#   芯片级 fragment (POSSIBLE_FRAGMENTS 机制自动发现) → defconfig 声明 → RT → Panfrost
#   - rk3576.config        芯片级配置 (Mali Bifrost 等)
#   - cma.config / quectel-pwm-fan.config / rockchip-debug.config  RK_KERNEL_CFG_FRAGMENTS
#   - rockchip_rt.config   RT 优化 (关闭温控降频/DMC动态调频/SWAP 等, 官方自动追加)
#   - rockchip_panfrost.config  Debian trixie GNOME-on-Wayland 用主线 Panfrost 替代
#                              libmali 专有驱动 (官方 RK_DEBIAN_TRIXIE 时自动追加),
#                              否则 GNOME 无法用 GBM/KMS 硬件加速 → 界面卡顿
#   - quectel-overlays.config  (当前 SDK 特有: 开启设备树 overlay 运行时加载)
KERNEL_FRAGMENTS_CHIP="rk3576.config"
KERNEL_FRAGMENTS="cma.config quectel-pwm-fan.config rockchip-debug.config quectel-overlays.config"
KERNEL_FRAGMENTS_RT="rockchip_rt.config"
KERNEL_FRAGMENTS_GPU="rockchip_panfrost.config"
# 完整 merge 集合 (顺序与官方一致: 后 merge 的生效)
KERNEL_FRAGMENTS_ALL="$KERNEL_FRAGMENTS_CHIP $KERNEL_FRAGMENTS $KERNEL_FRAGMENTS_RT $KERNEL_FRAGMENTS_GPU"
FIT_ITS="boot-debian.its"                      # RK_BOOT_FIT_ITS_NAME

JOBS="${JOBS:-$(nproc)}"

# ----------------------------------------------------------------------------
# 颜色输出
# ----------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# ----------------------------------------------------------------------------
# 工具链自动检测
#   优先: $TOOLCHAIN_DIR
#   其次: SDK 内 toolchain/
# ----------------------------------------------------------------------------
find_toolchain() {
    local tc=""
    if [ -n "${TOOLCHAIN_DIR:-}" ]; then
        tc="$TOOLCHAIN_DIR"
    elif [ -d "$ROOT_DIR/toolchains/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu" ]; then
        tc="$ROOT_DIR/toolchains/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu"
    fi

    if [ -z "$tc" ] || [ ! -x "$tc/bin/aarch64-none-linux-gnu-gcc" ]; then
        log_err "未找到 aarch64 交叉编译工具链!"
        echo "  请通过以下任一方式提供:"
        echo "    1. export TOOLCHAIN_DIR=<工具链目录>"
        echo "    2. 将工具链放入 $ROOT_DIR/toolchains/"
        return 1
    fi
    echo "$tc"
}

check_env() {
    [ -d "$KERNEL_DIR" ] || { log_err "缺少内核源码目录: $KERNEL_DIR"; return 1; }
    [ -d "$BASE_IMAGE_DIR" ] || { log_err "缺少底包目录: $BASE_IMAGE_DIR"; return 1; }
    [ -f "$BASE_IMAGE_DIR/package-file" ] || { log_err "缺少 $BASE_IMAGE_DIR/package-file"; return 1; }
    [ -x "$PACK_TOOL_DIR/afptool" ] || { log_err "缺少 $PACK_TOOL_DIR/afptool"; return 1; }
    [ -x "$PACK_TOOL_DIR/rkImageMaker" ] || { log_err "缺少 $PACK_TOOL_DIR/rkImageMaker"; return 1; }
    [ -f "$BOOT_DIR/$FIT_ITS" ] || { log_err "缺少 $BOOT_DIR/$FIT_ITS"; return 1; }
    [ -x "$BOOT_DIR/mkimage" ] || { log_err "缺少 $BOOT_DIR/mkimage (U-Boot FIT 打包工具)"; return 1; }
    return 0
}

# ----------------------------------------------------------------------------
# [1/4] 编译内核: defconfig + fragments → make <dts>.img
#   产物: arch/arm64/boot/Image, resource.img, boot.img(传统格式), zboot.img
# ----------------------------------------------------------------------------
build_kernel() {
    local tc="$1"
    log_info "[1/4] 编译内核 ($DTS_NAME.img, -j$JOBS)"
    log_info "      defconfig: $DEFCONFIG + $KERNEL_FRAGMENTS"

    export ARCH=arm64
    export CROSS_COMPILE="$tc/bin/aarch64-none-linux-gnu-"
    export PATH="$tc/bin:$PATH"

    cd "$KERNEL_DIR"

    # 保留用户定制配置: 已存在 .config 时不覆盖 (menuconfig 修改可保留)
    # 如需强制恢复默认: FORCE_DEFCONFIG=1 ./tools/build-kernel.sh 或 make defconfig
    if [ -f .config ] && [ -z "${FORCE_DEFCONFIG:-}" ]; then
        log_info "检测到现有 .config, 保留定制配置"
        log_info "      (如需恢复默认: FORCE_DEFCONFIG=1 ./tools/build-kernel.sh 或 make defconfig)"
    else
        make "$DEFCONFIG" $KERNEL_FRAGMENTS_ALL
    fi
    make -j"$JOBS" "$DTS_NAME.img"

    # 校验产物
    [ -f "arch/arm64/boot/Image" ] || { log_err "内核编译失败: Image 未生成"; return 1; }
    [ -f "arch/arm64/boot/dts/rockchip/$DTS_NAME.dtb" ] || { log_err "内核编译失败: DTB 未生成"; return 1; }
    [ -f "resource.img" ] || { log_err "内核编译失败: resource.img 未生成"; return 1; }
    log_ok "内核编译完成: Image/Image.lz4/resource.img/dtb 已生成"

    # 编译内建设备树 overlays (dts/rockchip/ 下 Makefile 声明的 *.dtbo)
    local OV_SRC_DIR="$KERNEL_DIR/arch/arm64/boot/dts/rockchip"
    local OV_DTC="$KERNEL_DIR/scripts/dtc/dtc"
    local ov_targets
    ov_targets="$(cd "$OV_SRC_DIR" && grep -h 'dtb-.*+=' Makefile 2>/dev/null | grep -o '[a-z0-9_-]*\.dtbo' | sort -u)"
    if [ -n "$ov_targets" ] && [ -x "$OV_DTC" ]; then
        log_info "编译内建设备树 overlays (dtc)"
        local ov_n=0
        while IFS= read -r dtbo; do
            local dts="${dtbo%.dtbo}.dts"
            if [ -f "$OV_SRC_DIR/$dts" ]; then
                "$OV_DTC" -@ -I dts -O dtb -o "$OV_SRC_DIR/$dtbo" "$OV_SRC_DIR/$dts" \
                    || { log_err "overlay 编译失败: $dts"; return 1; }
                ov_n=$((ov_n+1))
            fi
        done <<< "$ov_targets"
        log_ok "内建设备树 overlays 编译完成: $ov_n 个 .dtbo"
    elif [ -n "$ov_targets" ]; then
        log_warn "内核 dtc 不存在: $OV_DTC (跳过内建 overlays)"
    else
        log_warn "内核 Makefile 未声明任何 .dtbo overlay"
    fi
}

# ----------------------------------------------------------------------------
# [2/4] 按 Debian FIT 格式重新打包 boot.img
#   对齐官方 mk-fitimage.sh: mkimage -f boot-debian.its -E -p 0x800 boot.img
# ----------------------------------------------------------------------------
make_fit_boot() {
    log_info "[2/4] 按 Debian FIT 格式重新打包 boot.img"

    cd "$KERNEL_DIR"
    local kernel_img="$(realpath arch/arm64/boot/Image)"
    local kernel_dtb="$(realpath arch/arm64/boot/dts/rockchip/$DTS_NAME.dtb)"
    local resource_img="$(realpath resource.img)"
    local boot_img="$(realpath boot.img)"
    local tmp_its="$(mktemp)"

    cp "$BOOT_DIR/$FIT_ITS" "$tmp_its"
    sed -i -e "s~@KERNEL_DTB@~$kernel_dtb~" \
           -e "s~@KERNEL_IMG@~$kernel_img~" \
           -e "s~@RESOURCE_IMG@~$resource_img~" \
           -e "s~@RAMDISK_IMG@~$resource_img~" "$tmp_its"

    "$BOOT_DIR/mkimage" -f "$tmp_its" -E -p 0x800 "$boot_img"
    rm -f "$tmp_its"

    [ -f "$boot_img" ] || { log_err "FIT 打包失败: boot.img 未生成"; return 1; }
    log_ok "FIT boot.img 生成完成: $boot_img ($(du -h "$boot_img" | cut -f1))"
}

# ----------------------------------------------------------------------------
# [3/4] 组装 Image 目录 (替换 boot 分区)
#   对齐官方 mk-updateimg.sh: ln -rsf 底包 → 替换 boot.img
# ----------------------------------------------------------------------------
assemble_image_dir() {
    log_info "[3/5] 组装 Image 目录 (替换 boot 分区)"

    rm -rf "$IMAGE_DIR" "$RESULT_DIR"
    mkdir -p "$IMAGE_DIR" "$RESULT_DIR"
    cd "$IMAGE_DIR"

    # 底包全量链接进来 (符号链接, 不拷贝 6GB rootfs)
    ln -rsf "$BASE_IMAGE_DIR"/* .
    rm -f update.img update.raw.img boot.img

    # 替换为刚编译的 FIT boot.img
    cp -f "$KERNEL_DIR/boot.img" boot.img
    log_ok "Image 目录就绪: boot.img 已替换 ($(du -h boot.img | cut -f1))"

    # ------------------------------------------------------------------
    # [新增] 应用层 overlay 文件 (overlay/ 下非 .dts/.dtbo/README 的文件)
    #   如 overlay/etc/xxx.conf → /etc/xxx.conf; overlay/opt/app → /opt/app
    #   由 build-rootfs.sh apply 写入 rootfs 工作副本 (跳过 .dts/.dtbo/README)
    # ------------------------------------------------------------------
    local app_files=()
    if [ -d "$ROOT_DIR/overlay" ]; then
        while IFS= read -r f; do
            local rel="${f#"$ROOT_DIR/overlay"/}"
            case "$rel" in
                README.md|*.dts|*.dtbo) continue ;;
            esac
            app_files+=("$f")
        done < <(find "$ROOT_DIR/overlay" -type f 2>/dev/null | sort)
    fi

    if [ "${#app_files[@]}" -gt 0 ]; then
        command -v debugfs >/dev/null 2>&1 || { log_err "需要 debugfs 才能写入应用层 overlay"; return 1; }
        log_info "检测到 ${#app_files[@]} 个应用层 overlay 文件, 调用 build-rootfs.sh apply ..."
        if ! "$TOOLS_DIR/build-rootfs.sh" apply; then
            log_err "应用层 overlay 写入失败"
            return 1
        fi
        # build-rootfs.sh 产物 build/rootfs-overlay.img 已含应用层文件, 替换回 Image 目录
        cp -f "$WORK_DIR/rootfs-overlay.img" rootfs.img
        log_ok "应用层 overlay 已写入 rootfs (底包未污染)"
    else
        log_info "跳过应用层 overlay (overlay/ 下无应用文件, 仅有 .dts/.dtbo/README)"
    fi

    # 写入 overlays 到 rootfs /boot/overlays/ (工作副本, 不污染底包)
    local ov_src="$WORK_DIR/overlays"
    if [ -d "$ov_src" ] && ls "$ov_src"/*.dtbo >/dev/null 2>&1; then
        command -v debugfs >/dev/null 2>&1 || { log_err "需要 debugfs 才能写入 overlays"; return 1; }
        # 复制 rootfs 工作副本 (已含应用层 overlay)
        cp --reflink=auto -f rootfs.img "$WORK_DIR/rootfs-overlay.img" 2>/dev/null || cp -f rootfs.img "$WORK_DIR/rootfs-overlay.img"
        # 创建 /boot/overlays 目录
        debugfs -w -R "mkdir /boot" "$WORK_DIR/rootfs-overlay.img" < /dev/null > /dev/null 2>&1 || true
        debugfs -w -R "mkdir /boot/overlays" "$WORK_DIR/rootfs-overlay.img" < /dev/null > /dev/null 2>&1 || true
        for dtbo in "$ov_src"/*.dtbo; do
            debugfs -w -R "write $dtbo /boot/overlays/$(basename "$dtbo")" "$WORK_DIR/rootfs-overlay.img" < /dev/null > /dev/null 2>&1 \
                && log_info "  overlay 已写入 rootfs: /boot/overlays/$(basename "$dtbo")" \
                || log_warn "  overlay 写入失败: $(basename "$dtbo")"
        done
        local rc=0
        e2fsck -f -y "$WORK_DIR/rootfs-overlay.img" > /dev/null 2>&1 || rc=$?
        [ "$rc" -lt 4 ] || log_warn "e2fsck 发现未修复错误 ($rc)"
        rm -f rootfs.img
        cp -f "$WORK_DIR/rootfs-overlay.img" rootfs.img
        log_ok "overlays 已写入 rootfs /boot/overlays/ (底包未污染)"
    else
        log_info "跳过 overlays 写入 (无 .dtbo 产物)"
    fi
}

# ----------------------------------------------------------------------------
# [4/5] 重新打包 update.img
#   对齐官方 mk-updateimg.sh: afptool -pack → rkImageMaker -RK3576
# ----------------------------------------------------------------------------
pack_update_img() {
    log_info "[4/5] 重新打包 update.img"

    cd "$IMAGE_DIR"
    local tag="RK$(dd if=MiniLoaderAll.bin bs=1 count=4 skip=21 status=none | rev)"
    log_info "      TAG=$tag, afptool -pack ..."

    "$PACK_TOOL_DIR/afptool" -pack ./ "$RESULT_DIR/update.raw.img"
    "$PACK_TOOL_DIR/rkImageMaker" "-$tag" MiniLoaderAll.bin \
        "$RESULT_DIR/update.raw.img" "$RESULT_DIR/update.img" \
        -os_type:androidos

    [ -f "$RESULT_DIR/update.img" ] || { log_err "打包失败: update.img 未生成"; return 1; }
    cp -f boot.img "$RESULT_DIR/boot.img"

    log_ok "打包完成!"
    echo
    echo "======================================================"
    echo " 产物:"
    echo "   $RESULT_DIR/update.img  完整固件 ($(du -h "$RESULT_DIR/update.img" | cut -f1))"
    echo "   $RESULT_DIR/boot.img    单独内核镜像 ($(du -h "$RESULT_DIR/boot.img" | cut -f1))"
    echo "======================================================"
}

# ----------------------------------------------------------------------------
# [3/5] 编译设备树 overlays
#   来源: overlay/*.dts (一级目录) + kernel overlay 目录
#   产物: build/result/overlays/*.dtbo (打包时写入 rootfs /boot/overlays/)
# ----------------------------------------------------------------------------
build_overlays() {
    log_info "[3/5] 编译设备树 overlays"

    local SRC_DIR="$ROOT_DIR/overlay"
    local KERNEL_OV_DIR="$KERNEL_DIR/arch/arm64/boot/dts/rockchip"
    # 独立输出目录 (不被 assemble_image_dir 的 rm -rf RESULT_DIR 影响)
    local OUT_DIR="$WORK_DIR/overlays"
    mkdir -p "$OUT_DIR"
    rm -f "$OUT_DIR"/*.dtbo 2>/dev/null || true

    local n=0

    # 1) overlay/ 下的 .dts
    if [ -d "$SRC_DIR" ]; then
        for dts in "$SRC_DIR"/*.dts; do
            [ -f "$dts" ] || continue
            local base
            base="$(basename "$dts" .dts)"
            log_info "  overlay: $base.dts"
            # 用 dtc 编译 (先检查系统 dtc, 否则用内核 scripts/dtc)
            local dtc_bin
            dtc_bin="$(command -v dtc || true)"
            if [ -z "$dtc_bin" ] && [ -x "$KERNEL_DIR/scripts/dtc/dtc" ]; then
                dtc_bin="$KERNEL_DIR/scripts/dtc/dtc"
            fi
            if [ -z "$dtc_bin" ]; then
                log_err "未找到 dtc (device tree compiler)。安装: sudo apt install device-tree-compiler"
                return 1
            fi
            "$dtc_bin" -@ -I dts -O dtb -o "$OUT_DIR/$base.dtbo" "$dts" \
                || { log_err "overlay 编译失败: $dts"; return 1; }
            n=$((n+1))
        done
    fi

    # 2) 内核内建 overlay 编译产物 (Makefile 声明过的 *.dtbo)
    if [ -d "$KERNEL_OV_DIR" ]; then
        for dtbo in "$KERNEL_OV_DIR"/*.dtbo; do
            [ -f "$dtbo" ] || continue
            cp -f "$dtbo" "$OUT_DIR/"
            n=$((n+1))
        done
    fi

    if [ "$n" -eq 0 ]; then
        log_warn "没有可编译的 overlays (overlay/*.dts 为空, 内核无 .dtbo 产物)"
    else
        log_ok "overlays 编译完成: $OUT_DIR ($n 个 .dtbo)"
    fi
}

cmd_menuconfig() {
    local tc="$(find_toolchain)" || exit 1
    export ARCH=arm64
    export CROSS_COMPILE="$tc/bin/aarch64-none-linux-gnu-"
    export PATH="$tc/bin:$PATH"

    cd "$KERNEL_DIR"
    # 首次进入自动加载默认配置 (与官方 M2 一致的完整 fragment 集合)
    [ -f .config ] || make "$DEFCONFIG" $KERNEL_FRAGMENTS_ALL
    make menuconfig

    log_ok "menuconfig 配置已保存到 kernel/.config"
    echo "  下次 ./tools/build-kernel.sh 或 make 会保留此配置 (增量编译)"
    echo "  固化修改: make savedefconfig 生成精简 defconfig"
}

cmd_clean() {
    log_info "清理构建产物..."
    rm -rf "$WORK_DIR"
    [ -d "$KERNEL_DIR" ] && { cd "$KERNEL_DIR" && make ARCH=arm64 distclean >/dev/null 2>&1 || true; }
    log_ok "清理完成"
}

main() {
    local mode="${1:-all}"
    check_env || exit 1

    case "$mode" in
        check)
            local tc="$(find_toolchain)" || exit 1
            log_ok "工具链: $tc"
            log_ok "环境检查通过 (内核源码/底包/打包工具/FIT工具 均就绪)"
            ;;
        menuconfig)
            cmd_menuconfig
            ;;
        kernel)
            local tc="$(find_toolchain)" || exit 1
            build_kernel "$tc"
            ;;
        boot)
            make_fit_boot
            ;;
        overlays)
            build_overlays
            ;;
        all)
            local tc="$(find_toolchain)" || exit 1
            build_kernel "$tc"
            make_fit_boot
            build_overlays
            assemble_image_dir
            pack_update_img
            ;;
        clean)
            cmd_clean
            ;;
        *)
            log_err "未知命令: $mode (支持: all | check | menuconfig | kernel | boot | overlays | clean)"
            exit 1
            ;;
    esac
}

main "$@"
