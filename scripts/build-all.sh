#!/bin/bash
# ============================================================
# simple-h1 全量打包脚本
# 功能: 编译内核 -> 打包 efi.bin -> 打包 system.img (overlay) -> 打包 dtb.bin
#       输出到 build/output/
# 用法: ./scripts/build-all.sh [clean]
#   仅应用层改动时, 可以跳过内核编译:
#     SKIP_KERNEL=1 ./scripts/build-all.sh
# ============================================================
set -e
cd "$(dirname "$0")/.."
source scripts/env.sh

echo "=========================================="
echo "[simple-h1] 全量打包开始"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

# 1. 编译内核 (可跳过)
if [ "${SKIP_KERNEL:-0}" != "1" ]; then
    echo ""
    echo "########## [1/4] 编译内核 ##########"
    ./scripts/build-kernel.sh "$@"
else
    echo "[simple-h1] SKIP_KERNEL=1, 跳过内核编译"
fi

# 2. 打包 efi.bin
echo ""
echo "########## [2/4] 打包 efi.bin ##########"
./scripts/pack-efi.sh

# 3. 打包 dtb.bin
echo ""
echo "########## [3/4] 打包 dtb.bin ##########"
./scripts/pack-dtb.sh

# 4. 打包 system.img
echo ""
echo "########## [4/4] 打包 system.img ##########"
./scripts/pack-system.sh

# 5. 复制烧录所需基础文件到输出目录
echo ""
echo "########## 复制烧录基础文件 ##########"
for f in prog_firehose_Qcm6490_ddr.elf partition_ufs partition_emmc \
         gpt_main*.bin gpt_backup*.bin gpt_empty*.bin \
         xbl.elf xbl_config*.elf XblRamdump.elf zeros_*.bin \
         aop.mbn cpucp.elf devcfg.mbn hypvm.mbn imagefv.elf logfs_ufs_8mb.bin \
         multi_image.mbn qupv3fw.elf shrm.elf tz.mbn uefi.elf uefi_sec.mbn tools.fv \
         el2-dtb.bin rawprogram*.xml patch*.xml; do
    if [ -e "${PREBUILDS_DIR}/${f}" ] && [ ! -e "${OUT_DIR}/${f}" ]; then
        cp -a "${PREBUILDS_DIR}/${f}" "${OUT_DIR}/" 2>/dev/null || true
    fi
done
# zeros_33sectorS.bin (WIPE xml 引用, 与 zeros_33sectors.bin 同内容)
[ -e "${OUT_DIR}/zeros_33sectors.bin" ] && [ ! -e "${OUT_DIR}/zeros_33sectorS.bin" ] && \
    cp "${OUT_DIR}/zeros_33sectors.bin" "${OUT_DIR}/zeros_33sectorS.bin"

echo ""
echo "=========================================="
echo "[simple-h1] 全量打包完成 ✓"
echo "  输出目录: ${OUT_DIR}"
ls -la "${OUT_DIR}" | grep -E "efi.bin|dtb.bin|system.img"
echo "=========================================="
echo ""
echo "烧录方法: ./scripts/flash.sh  (USB EDL 模式)"
