---
name: storage
description: "Quectel PI M2 存储：eMMC/UFS 在模组内（以 lsblk 为准）、TF 卡 UHS-I 翻盖卡座无热插拔、exFAT 支持、自动挂载、NVMe SSD（走 PCIe0）、SD 卡启动。当用户说「M2 SD 卡不识别」「U 盘挂不上」「exFAT 打不开」「自动挂载」「存储控制器是哪个 mmc」「从 TF 卡启动」时使用。WHEN: M2 storage, eMMC, UFS, SD card UHS-I, exFAT, automount, mmc0 mmc1, NVMe, 存储, 挂载. DO NOT USE FOR: NVMe/5G 走 PCIe 的链路问题（用 pcie），U 盘走 USB HUB（用 usb）。"
license: MIT
metadata:
  author: Quectel PI M2 外设 SKILL 库
  version: "1.0.0"
  board: Quectel PI M2 (RK3576 / QSM610ZAP-WF)
---

# M2 存储 SKILL — eMMC / TF 卡(UHS-I) / NVMe / 自动挂载

适用：Quectel PI M2（`quectel,pi-m2-rk3576`）。NVMe 相关细节另见 `pcie/SKILL.md`。

## 0. ★ 存储控制器归属（2026-10-10 上板实测，**别再猜 mmcN**）

| 节点 | DT | 控制器 | 实际是什么 |
|---|---|---|---|
| **`mmc0`** | `2a330000.mmc` | `rockchip,rk3576-dwcmshc`（SDHCI/CQHCI） | **eMMC**（→ `/dev/mmcblk0`） |
| **`mmc1`** | `2a310000.mmc` | `rockchip,rk3576-dw-mshc` | **TF 卡座**（SDMMC0，→ `/dev/mmcblk1`） |
| **`mmc2`** | `2a320000.mmc` | `rockchip,rk3576-dw-mshc` | **SDIO Wi-Fi**（有 `mmc-pwrseq`；不是卡座） |

⇒ **看 TF/SD 卡的 dmesg 要 grep `mmc1`**（不是 mmc0！mmc0 是 eMMC）。
板上未插卡时：`vcc_sd` regulator = `disabled`，`mmc1` 无 card，`/dev/mmcblk1` 不存在。

## 1. 硬件事实

### TF 卡（J0801）

| 信号 | 模组 pin | 说明 |
|---|---|---|
| SD_CLK / CMD / DATA0..3 | 105 / 110 / 106..109 | SDMMC0（`50OHM_SD_*_P1`） |
| **SD_EN**（SDMMC0_PWREN） | 218 | `SD_PWR_EN` → 卡座 3V3 负载开关，**高=供电**（DTS 里 `vcc_sd`, `GPIO0_B6`） |
| SDIO_PU_VDD | 32 | 模组内部输出 1.8/2.95V，给 SD 上拉 |
| SDIO0_DET | 111 | **未用** —— 卡座是翻盖式（NO PUSH），没有卡检测开关 |

- 卡座型号 MUP-M616-1（翻盖），**热插拔不可用**（pinmap 明写"无热拔插功能"）。
- 数据线旁有 TVS（D0801..D0808）。

### eMMC / UFS

- 存储颗粒在模组（SH603ZA）内。`rk3576-quectel-pi-common.dtsi` 把 `&ufs` 置 `status = "okay"`
  并配了 `vcc_ufs_s0` / `vcc1v2_ufs_vccq_s0` / `vcc1v8_ufs_vccq2_s0` 三路供电，
  M2 没有单独关掉它 —— **实际上板以 `lsblk`、`dmesg | grep -iE "mmc0|emmc"` 为准**，
  不要凭 DTS 断言板上有 UFS 颗粒。
- **板上实测是 eMMC，不是 UFS**：`mmcblk0` 58.2G，`device/name=C23E00`、`manfid=0xd6`、`date=10/2025`；
  12 个分区 —— `p1 /persist`(32M ext4)、`p9 /`(41.8G ext4)、`p11 /oem`(128M)、`p12 /userdata`(8G)，
  另有 `mmcblk0boot0/boot1`(4M, RO)。

## 2. DTS 实现（M2 专属）

```dts
&{/} {
    vcc_sd: vcc-sd {                       /* SD_EN = GPIO0_B6 控制卡座 3V3 */
        compatible = "regulator-fixed";
        enable-active-high;
        gpio = <&gpio0 RK_PB6 GPIO_ACTIVE_HIGH>;
        startup-delay-us = <10000>;
        regulator-boot-on;
        vin-supply = <&vcca_3v3_s0>;
    };
};

&sdmmc {
    broken-cd;             /* 翻盖卡座无 CD 开关 */
    sd-uhs-sdr104;         /* UHS-I 1.8V / SDR104 协商 */
    sd-uhs-sdr50;
    vmmc-supply = <&vcc_sd>;   /* SD_3V3 via load switch */
    status = "okay";
};
```

要点：

- **`broken-cd` 是必须的**（不是可选项）。没有它，内核等一个永远不来的 CD 中断，卡永远不枚举。
- UHS-I 需要 `vqmmc` 能切到 1.8V。M2 的 `vqmmc` 走模组内部 `SDIO_PU_VDD`，
  DTS 里的 `sd-uhs-sdr104/sdr50` 是"强制加回 UHS 属性、验证 vqmmc 能否切 1.8V"的产物。
  如果换了卡座/改了供电，UHS 可能协商失败并回落 HS（30MB/s 级），用
  **`dmesg | grep -i "mmc1"`**（★ TF 卡是 mmc1）看是否报 `1.8V signalling` 失败。

## 3. 使用与诊断

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
dmesg | grep -iE "mmc1|sdhci|mmc0"        # ★ TF=mmc1；mmc0 是 eMMC，别混
cat /sys/block/mmcblk0/device/{name,type,manfid}   # eMMC 身份（实测 C23E00 / 0xd6）
# 速度（TF 卡看 mmc1）
cat /sys/kernel/debug/mmc1/ios            # bus speed / timing
# 手动挂载（插卡后）
mount /dev/mmcblk1p1 /mnt
```

### 文件系统支持（内核片段）

- **exFAT**：`kernel/arch/arm64/configs/quectel-exfat.config`
  （`CONFIG_EXFAT_FS=y`、`CONFIG_EXFAT_DEFAULT_IOCHARSET="cp936"`）。
  **本仓库已启用**：`tools/build-kernel.sh:63` 的 `KERNEL_FRAGMENTS` 里就含 `quectel-exfat.config`
  （连同 `quectel-container.config`）。本仓库没有 defconfig，片段清单只在这份脚本和
  `tools/VERSION.txt` 的 `FRAGMENTS` 行；要加新片段就加进 `KERNEL_FRAGMENTS`，否则不进内核配置。
  - **板上实测已生效**：`/proc/filesystems` 里有 `vfat / exfat / ntfs`（Debian 镜像）✓
  - ⚠️ **关于"内核静态编译"**：**板上 `/lib/modules` 不是空的**（有 `aic8800_bsp.ko`/`aic8800_btlpm.ko`/`aic8800_fdrv.ko`，
    Wi-Fi/BT 模块）。所以准确说法是"**以静态编译为主**"——新增 `=m` 时，`.ko` 必须进 rootfs 的 `/lib/modules` 且有加载机制；
    但对 rootfs 关键功能（存储/文件系统）**照旧用 `=y` 最稳**。
- 背景：GNOME Files 里 exFAT 卡显示 "unsupported format"，
  FAT32(vfat) / NTFS(ntfs-3g) 正常；本仓库已静态启用 exFAT。

## 4. 应用层：自动挂载

- **可移动存储插卡自动挂载**：
  相关脚本（板上）：
  - `/usr/bin/disk-helper` —— 通用挂载辅助（解析 fstab 行、blkid 找设备、按 fstype 选工具，
    内建 BUSYBOX / NTFS-3G 的 mount opts 白名单）
  - `/usr/bin/mount-helper` —— 开机挂载 fstab 里的内部分区（`/tmp/mount-all.log`）
  - `/usr/local/sbin/quectel-fix-removable-perm.sh` —— 修可移动介质权限
  - `/usr/bin/resize-helper`、`/usr/local/bin/resize-rootfs.sh` —— 首次启动扩根
- **板上实测**：`udisks2` active；`/media`、`/mnt` 均为空（无移动介质插入）。
- **rootfs 挂载自愈**：额外分区 fstab 已加超时兜底 + 开机自愈挂载 —— 别手改 fstab 去掉超时参数。

## 5. 扩展场景

- **NVMe SSD**：走 PCIe0（J1101），见 `pcie/SKILL.md`；`bootargs_ext` 里已加
  `nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off` 解决省电掉线。
  （板上 `lspci` 无输出、`/sys/bus/pci/devices` 空 → 当前没插 PCIe 设备。）
- **U 盘**：走 USB HUB（`usb/SKILL.md`），exFAT/vfat/ntfs 都支持。
- **OTA 分区**：`update_bak` 是黄金包 —— 只写一次，之后固件不得重写（分区表见 `sdk-flash/SKILL.md`）。
- **SD 卡启动**：见 `sdk-flash/SKILL.md`。

## 6. 已知坑

1. **`mmc0` 是 eMMC，`mmc1` 才是 TF 卡**（实测）。诊断 SD 问题时 grep 错设备号会白查半天。
2. **U 盘/SD 卡插上没反应**：先确认 `SD_EN(GPIO0_B6)` 电平与 `vcc_sd` 是否使能
   （`cat /sys/class/regulator/*/name` 找到 `vcc_sd` 看 `state`）；
   再看是否整版 3V3（`GPIO4_A7`）没开（pinmap 明写"使用 SD 卡时必须打开 DCDC_EN_3V3"）。
3. **卡座没有热插拔**：插/拔卡必须在断电或至少重新枚举后生效，别用 `udevadm trigger` 硬撑。
4. **exFAT 不识别但 FAT32 正常** → 就是片段没进 `tools/build-kernel.sh` 的 `KERNEL_FRAGMENTS`（本仓库已含 exfat）。
5. **别把"内核全静态"当铁律**：板上确实有 3 个 `.ko`（见 §3），表述要说清适用条件。
6. **不要用 `sed` 改 fstab / 内核片段**。
