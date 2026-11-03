---
name: simple-h1-storage
description: "simple-h1 SDK: UFS 128G 整盘烧录与分区、SD 卡（SD 3.0）、M.2 NVMe 存储的验证与调试"
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [qualcomm, qcs6490, quectel, simple-h1, storage, ufs, sdcard, nvme, btrfs]
    related_skills: [simple-h1-build, simple-h1-flash, simple-h1-pmic-power]
---

# simple-h1 存储

设备树: `kernel/arch/arm64/boot/dts/qcom/qcs6490-idp-pi.dts`（行号以该文件为准）。
硬件出处: 原理图 p11（SD 卡座）、p08（M.2 FPC `J0901`）。

## 1. 硬件事实

| 介质 | 控制器 / 器件 | 连接 | 说明 |
|---|---|---|---|
| **UFS** | `ufs_mem_hc` + `ufs_mem_phy` | 板载（不可拆） | **128 GB UFS**（规格书：8 GB LPDDR4X + 128 GB UFS） |
| **SD 卡** | `sdhc_2` | 卡座（p11） | **SD 3.0，4-bit**；`ESDBVD5V0Y1` 做 ESD |
| **M.2 NVMe SSD** | 走 **PCIe1**（1-lane） | `J0901` FPC（p08） | 与 5G 模组二选一；**链路被限到 Gen1** |
| Wi-Fi SDIO | `sdhc_1` | 板载模组 | `non-removable` / `no-sd`，**不产生块设备** |

**⚠️ SDIO 二选一（物理开关）**：SD 卡功能可由**卡座**或 **2×20-pin SDIO 接口（40Pin）**实现，
板上开关 2 选 1，不能同时用。**软件里没有这个开关**，别去找 GPIO。

### 1.1 UFS / SD 关键节点

```dts
&ufs_mem_hc {                                        /* DTS:1635-1645 */
    reset-gpios = <&tlmm 175 GPIO_ACTIVE_LOW>;
    vcc-supply   = <&vreg_l7b_2p952>;  vcc-max-microamp  = <800000>;
    vccq-supply  = <&vreg_l9b_1p2>;    vccq-max-microamp = <900000>;
    vccq2-supply = <&vreg_l9b_1p2>;    vccq2-max-microamp= <900000>;
    status = "okay";
};
&ufs_mem_phy {                                       /* DTS:1647-1652 */
    vdda-phy-supply = <&vreg_l10c_0p88>;
    vdda-pll-supply = <&vreg_l6b_1p2>;
    status = "okay";
};
&sdhc_2 {                                            /* DTS:1654-1664 */
    status = "okay";
    vmmc-supply  = <&vreg_l9c_2p96>;   /* 2.96 V 卡供电 */
    vqmmc-supply = <&vreg_l6c_2p96>;   /* 2.96 V IO 供电 */
    cd-gpios = <&tlmm 91 GPIO_ACTIVE_LOW>;   /* 卡检测 */
};
```
- `&vreg_l7b_2p952` / `&vreg_l9b_1p2` 在 DTS:1739-1751 被显式
  `regulator-allow-set-load` + `allowed-modes = <LPM HPM>`，并 `/delete-property/` 掉 min/max —
  这是 UFS 吞吐/功耗调节的关键，**不要"补回"**。
- `&sdhc_1`（Wi-Fi SDIO）见 DTS:1402-1417：`non-removable`、`no-sd`、
  `vmmc=<&wifi_3v3_vreg>(tlmm132)`、`vqmmc=<&wifi_1v8_vreg>(tlmm130)`、
  `quec,wifi-en-gpio = <&tlmm 84>`、**`keep-power-in-suspend`**。

> **实测**（同板）：`sda1 512M vfat /efi`、`sda2 30M ext4 /var/persist`、`sda3 115.6G btrfs /`，
> `cat /proc/quec_ufs_size` = `116 GB`，UFS 为 `FORESEE C2G072`（6 个 LUN 对应 sda~sdf），
> `mmc0`/`mmc1` 两个 host 存在。`nvme-cli` **未安装**，M.2 段里 `nvme list` 用不了，改看 `lsblk` + `/sys/class/nvme/`。

## 2. 烧录与镜像格式（本 SDK 侧）

```bash
./scripts/build-all.sh          # 产出 build/result/{efi.bin,dtb.bin,system.img} + 分区表目录
SKIP_KERNEL=1 ./scripts/build-all.sh   # 只重打 system.img（改 overlay 后）
./scripts/flash.sh ufs          # 默认 ufs；./scripts/flash.sh emmc 走 eMMC
```
- **整盘烧录**：`flash.sh` 调用 qdl 依次写入 `partition_ufs/rawprogram{0..5}.xml` 与
  `patch{0..5}.xml`，覆盖 **UFS 的 6 个 LUN**，不增量、不跳过；结束需断电重上电。
- `system.img` 是 **BTRFS**（`tools/build-rootfs.sh` 用 `mkfs.btrfs -b <原镜像大小> -n 4096`
  并对齐 UUID），落到设备上就是根文件系统分区。
- overlay 里已预置 `overlay/lib/modules/6.6.116-qli-1.7-ver.1.1/updates/quec_ufs_size.ko`
  （`description: A module to create /proc/quec_ufs_size`，读 `/sys/block/sda/size`），
  上板 `cat /proc/quec_ufs_size` 可看容量。
- 分区表随底包提供（`prebuilds/` → `build/result/partition_ufs/`），**不要在设备上重写**。

## 3. 设备侧核查

```bash
adb shell 'cat /proc/partitions'
adb shell 'lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT'
adb shell 'df -hT / ; df -h'
adb shell 'cat /proc/quec_ufs_size'
adb shell 'dmesg | grep -iE "ufs|ufshcd|scsi" | tail -20'
adb shell 'cat /sys/class/scsi_host/host*/proc_name 2>/dev/null'
adb shell 'for b in /sys/block/*; do echo "$b $(cat $b/size)"; done'
adb shell 'ls /usr/bin /usr/sbin 2>/dev/null | grep -i ufs'   # ufs-utils 是否存在先确认
```
> 上板记录：UFS 身份 **FORESEE `C2G072`**（`ufshcd-qcom 1d84000.ufs` →
> `scsi 0:0:0:0: Direct-Access FORESEE C2G072 0016`），243449856 扇区 ≈ **116.1 GiB（标称 128 GB）**；
> 根文件系统在 **`/dev/sda3`**（`/`，115.6 G），`sda2` 30 M 挂 `/var/persist`，`sda1` 512 M；
> `zram0` 约 5.3 G 作 swap。板上还枚举出 `sdb`/`sdc`/`sdd`/`sde`(3 G，51 个分区)/`sdf` —
> 都是同一个 UFS 的其他 LUN / 模组侧分区，**用途未确认，不要当可用空间**。
> 推论：`sda`~`sdf` 被占满，**插 U 盘会拿到 `/dev/sdg`**，测 USB 存储别盯 `sda`。

### SD 卡

```bash
adb shell 'dmesg | grep -iE "mmc0|mmc1|sdhc|sdhci" | tail'
adb shell 'ls /sys/class/mmc_host/'
# 上板记录：mmc0 = 7c4000.mmc = Wi-Fi SDIO（无块设备）；mmc1 = 8804000.mmc = 卡座
adb shell 'ls -l /dev/mmcblk*'          # 插卡后是 /dev/mmcblk1p1，不是 mmcblk0
adb shell 'mkdir -p /mnt/sdcard && mount /dev/mmcblk1p1 /mnt/sdcard'
```

### M.2 NVMe

```bash
adb shell 'lspci -nn | head; lsblk'     # 期望 /dev/nvme0n1
adb shell 'dmesg | grep -iE "nvme|pcie" | tail -20'
# 分区/格式化（设备侧原生工具，镜像里没有就 apt 装）
fdisk /dev/nvme0n1            # g 建 GPT → n 建分区 → w
mkfs.ext4 /dev/nvme0n1p1
mkdir -p /mnt/myssd && mount /dev/nvme0n1p1 /mnt/myssd
# 开机自动挂：/etc/fstab 追加 /dev/nvme0n1p1  /mnt/myssd  ext4  defaults  0  2
# 顺序读写粗测（direct IO，绕页缓存）
dd if=/mnt/myssd/f of=/dev/null bs=1M count=1024 iflag=direct
dd if=/dev/zero of=/mnt/myssd/f bs=1M count=1024 oflag=direct
```
- NVMe 走 PCIe1：`perst-gpios = <&tlmm 2>`、`pwkey-gpios = <&tlmm 49>`、
  `max-link-speed = <1>`（**DTS:1174，限 Gen1**，SSD 速度会明显低于标称），
  `delay-ms = <3000>`；供电 `pcie1_pwr_en_vreg`（`tlmm 24`，DTS:1133-1142）。
- `CONFIG_BLK_DEV_NVME=m`（`scripts/kernel-config:2032`，`qcom_defconfig:203` 同值），
  没枚举出盘先 `lsmod | grep nvme` / `modprobe nvme`。

## 4. 扩展场景

- **扩根分区**：`system.img` 大小在打包时按原镜像尺寸固定（`mkfs.btrfs -b`），
  要改根分区大小必须动分区表并重新整盘烧录；BTRFS 在线 `resize` 仅在该分区本身已变大后才有意义。
- **数据盘**：优先用 M.2 NVMe 或 SD 卡挂 `/mnt/*`，别动 UFS 上用途未确认的 LUN。
- **文件系统**：根是 BTRFS；`ext4` 靠 `mkfs.ext4`（e2fsprogs）。exFAT/NTFS 是否可用需实测，
  不要假设已内置。
- **热插拔**：SD 卡支持（有 `cd-gpios`）；**NVMe 走 PCIe，不支持热插拔**，
  插拔 M.2 后应断电重启（空槽不阻塞开机，但热插有风险）。

## 5. 已知坑

1. **SD 卡与 40Pin SDIO 是物理二选一**：同时接会出现"两边都不工作"。
2. **`cd-gpios` 是 `tlmm 91` 且 `GPIO_ACTIVE_LOW`**：极性改错 → 卡检测反转；
   改 `sd_cd` pinctrl 的 `bias-pull-up` 同样影响检测电平。
3. **SD 节点是 `/dev/mmcblk1p1`**（mmc0 被 Wi-Fi SDIO 占着，没有 mmcblk0）。
4. **UFS 两个 regulator 的 `allow-set-load` 是故意的**：改 min/max 或 allowed-modes
   会导致 UFS 初始化失败或性能骤降（DTS:1739-1751）。
5. **插 U 盘会变成 `/dev/sdg`**：`sda`~`sdf` 已被 UFS 的 6 个 LUN 占用。
6. **NVMe 被限 Gen1**：`max-link-speed = <1>` 是为兼容 5G HAT 刻意设的，
   别期待全速；改它要连同 PCIe1 的 5G 模组一起验证。
7. **整盘烧录会覆盖全部 6 个 LUN**：包括模组侧分区，设备上的临时改动一律丢失，
   要保留的数据先取出来。
8. **`/proc/quec_ufs_size` 依赖预置 ko**：读不到就先
   `lsmod | grep quec_ufs_size`，再 `modprobe quec_ufs_size`。
9. **不要对量产机器做 UFS provision / 整片擦除**：会重写 UFS 配置与出厂数据。
