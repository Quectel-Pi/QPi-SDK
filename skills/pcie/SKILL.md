---
name: pcie
description: "Quectel PI M2 PCIe0（J1101）：5G 模组 HAT（Quectel MHI 驱动）与 NVMe SSD 二选一、链路训练失败排查、SerDes 与 USB1 共用（combphy1_psu）、从 NVMe 启动。当用户说「M2 插 5G 模组」「插 NVMe」「PCIe 链路训练失败」「MHI 加载不了」「PCIe 没识别」时使用。WHEN: M2 PCIe, PCIe0, NVMe SSD, 5G module HAT, Quectel MHI, link training failure, lspci empty, 模组, 固态硬盘. DO NOT USE FOR: 纯 USB 网卡/存储（用 usb / storage）。"
license: MIT
metadata:
  author: Quectel PI M2 外设 SKILL 库
  version: "1.0.0"
  board: Quectel PI M2 (RK3576 / QSM610ZAP-WF)
---

# M2 PCIe SKILL — PCIe0（J1101）+ 5G 模组 HAT + NVMe SSD

适用：Quectel PI M2（`quectel,pi-m2-rk3576`）。PCIe 相关只涉及 **PCIe0**；M2 不用 PCIe1。

> **M.2 插槽同一时刻只能插一个 PCIe 设备**：NVMe SSD 与 5G 模组二选一。换设备前必须先正常关机断电。

**装机准备**：PCIe 转接线（插 J1101，两侧压固定支架）、**GPIO 转接头 + M.2 HAT+**（HAT 插到 M2 的 **40Pin**）、
尼龙柱/螺钉；5G 另需天线与有效 SIM 卡，首次配置还需 Type-C-to-A USB 线接 PC（给模组发 AT）。

## 1. 硬件事实

### 连接器 J1101（KR05VS1613M0101RW，16Pin）

| pin | 信号 | 说明 |
|---|---|---|
| 6/7 | `90OHM_PCIE0_TX_N/P` | 模组 PCIe0 TX |
| 9/10 | `90OHM_PCIE0_RX_N/P` | 模组 PCIe0 RX |
| 12/13 | `100OHM_PCIE0_REFCLK_N/P` | 参考时钟 |
| 1 | `PCIE0_RST_N_3V3` | 复位（模组 pin201 = **`GPIO0_B4`**），经电平转换 |
| 3 | `PCIE0_WAKE_N_3V3` | 设备唤醒（模组 pin202 = **`GPIO0_D2`**），外部上拉 1V8，低=设备插入 |
| 2 | `PCIE0_CLKREQ_N_3V3` | 时钟请求（模组 pin203 = **`GPIO2_B2`**），低=时钟关闭 |
| 4 | `PCIE0_PWR_EN_3V3` | **外部 PCIe 电源使能**（模组 pin300 = **`GPIO4_B0`**），高=开 |
| 15/16 | `VDD_5V0_SYS` | 5V 供电（与 40Pin pin2/4 同源） |

### 40Pin 上的 M.2/5G HAT 控制脚（M2 特有，复用 RGMII1 的 MDIO/MDC）

| 功能 | 40Pin pin | 网络名 | GPIO |
|---|---|---|---|
| HAT **PWKEY** | 29 | `RGMII1_MDIO_3V3`（≈ RPi GPIO5） | `GPIO2_D5` |
| HAT **RESET** | 31 | `RGMII1_MDC_3V3`（≈ RPi GPIO6） | `GPIO2_D4` |

> ⚠️ 这两脚就是 40Pin 的第二路以太网 MDIO/MDC，**PCIe 5G HAT 与 RGMII1 以太网互斥**。

### 共用 SerDes

- `combphy1_psu` = **USB1 3.0 与 PCIe1 共用**。M2 用 USB1 接 CH634M HUB，
  因此 **PCIe1 在 M2 上不可用**。`&vcc3v3_pcie1` 在 M2 dtsi 里被显式 `disabled`
  且删掉 gpios（因为 `GPIO4_A7` 在 M2 是 `DCDC_EN_3V3`，不是 PCIe1 私有使能）。

## 2. DTS 实现

```dts
/* PCIe0 供电：GPIO4_B0 = PCIE0_PWR_EN_3V3 */
vcc3v3_pcie0_m2: vcc3v3-pcie0-m2 {
    compatible = "regulator-fixed";
    regulator-min-microvolt = <3300000>; regulator-max-microvolt = <3300000>;
    enable-active-high;
    gpio = <&gpio4 RK_PB0 GPIO_ACTIVE_HIGH>;
    startup-delay-us = <5000>;
    regulator-boot-on; regulator-always-on;
    vin-supply = <&vcc_sys>;
};

&pcie0 {
    phy-names = "pcie-phy";
    reset-gpios        = <&gpio0 RK_PB4 GPIO_ACTIVE_HIGH>;
    pwkey-gpios        = <&gpio2 RK_PD5 GPIO_ACTIVE_LOW>;    /* 40Pin pin29 */
    modem-reset-gpios  = <&gpio2 RK_PD4 GPIO_ACTIVE_HIGH>;   /* 40Pin pin31 */
    delay-ms = <3000>;
    modem-pwkey-pulse-ms   = <1000>;
    modem-reset-pulse-ms   = <500>;
    rockchip,perst-inactive-ms = <3000>;
    rockchip,wait-for-link-ms  = <10000>;
    rockchip,skip-scan-in-resume;      /* resume 时不重新扫描，避免 NVMe 掉线/5G 重训练 */
    supports-clkreq;
    pinctrl-names = "default";
    pinctrl-0 = <&pcie0m0_pins &pcie_5g_hat_pwkey &pcie_5g_hat_reset>;
    vpcie3v3-supply = <&vcc3v3_pcie0_m2>;
    status = "okay";
};
```

以及 `rk3576-quectel-pi-m2-linux.dts` 的：

```dts
chosen {
    /* NVMe 省电掉线导致无法自动挂载的修复 */
    bootargs_ext = "nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off";
};
```

`pwkey-gpios` / `modem-reset-gpios` / `modem-*-pulse-ms` 是 M2 为 5G 模组加的**上电时序**控制
（先 pwkey 脉冲，再 reset 脉冲，具体见 `kernel/drivers/pci/controller/dwc/pcie-dw-rockchip.c`）。

## 3. 使用与诊断

```bash
# PCIe 总线
lspci -nn                        # 期望 00:00.0 RK3576 PCI bridge + 01:00.0 设备
lspci -vvv                       # 看 LnkSta 协商速率/宽度
ls /sys/bus/pci/devices/         # 期望 0000:00:00.0 + 0000:01:00.0
cat /sys/bus/pci/devices/*/current_link_speed
dmesg | grep -iE "pcie|nvme|mhi"
# NVMe（本镜像无 `nvme` CLI，用 lsblk/fdisk）
lsblk ; fdisk -l /dev/nvme0n1 ; ls -l /dev/nvme*
# 5G 模组（Quectel MHI 驱动）
ls /dev/mhi*                     # mhi_BHI/DIAG/DUN/LOOPBACK/QMI0
ls /sys/class/net | grep rmnet   # rmnet_mhi0 / rmnet_mhi0.1
dmesg | grep -i mhi
```

**空槽（未插设备）的正常签名** —— 不是故障：

```
rk-pcie 2a200000.pcie: PCIe Linking... LTSSM is 0x3      ← 反复重试
rk-pcie 2a200000.pcie: PCIe Link Fail, LTSSM is 0x3, hw_retries=1
rk-pcie 2a200000.pcie: failed to initialize host
```

对照（插卡成功后）：`PCIe Link up, LTSSM is 0x130011` + `PCIe Gen.2 x1 link up`。

## 4. 5G 模组 / Quectel MHI

### 4.1 首次配置：把模组设成 PCIe-EP 模式（经模组自带 USB AT 口，在 PC 上做）

PCIe 直通转接卡下模组默认不是 PCIe-EP，不配置则主控根本认不到：

```plaintext
AT+QCFG="data_interface",1,0
AT+QCFG="pcie/mode",0
AT+QCFG="usbnet",2
AT+CFUN=1,1
```

各条返回 `OK` 后等模组重启，拔掉 PC 侧 USB，重新给主控上电。

### 4.2 识别确认

```bash
lspci                            # RK3576 PCI bridge + Qualcomm SDX62 5G
ls /dev/mhi*                     # mhi_BHI/DIAG/DUN/LOOPBACK/QMI0
ls /sys/class/net | grep rmnet   # rmnet_mhi0 / rmnet_mhi0.1
```

dmesg 关键行：`PCIe Link up, LTSSM is 0x130011`、`PCIe Gen.2 x1 link up`、
`mhi_pci_probe ... vendor=17CB`、`Transition to state:MISSION MODE`。

### 4.3 拨号与连通性

```bash
quectel-CM &                     # 板载 /usr/bin/quectel-CM（驱动 pcie_mhi V1.3.7，QMI 模式）
ip -4 addr show dev rmnet_mhi0.1
ping -c 4 -I rmnet_mhi0.1 8.8.8.8
```

日志出现 `SIM_READY`、`PS: Attached`、`DataCap: 5G_SA` 且 udhcpc 拿到 IP 即成功。

### 4.4 内核与驱动

- 内核片段：`kernel/arch/arm64/configs/quectel-mhi-wwan.config`
  —— `CONFIG_PCIE_MHI_QUECTEL=y`，并**关掉**主线 MHI/WWAN/QRTR
  （`CONFIG_MHI_BUS/MHI_WWAN_*/MHI_NET/QRTR` 全 `not set`），用的是 Quectel **out-of-tree pcie_mhi V1.3.7**。
- **这个片段本仓库没有默认启用**：`tools/build-kernel.sh:63` 的 `KERNEL_FRAGMENTS` 里没有它，
  用 5G 模组时自己把 `quectel-mhi-wwan.config` 加进去再重编内核。
- **冷启动链路训练失败**：已修（dtsi +2 行），
  改动 `rk3576-quectel-pi-m2-linux.dtsi`（+2 行）与
  `kernel/drivers/pci/controller/dwc/pcie-dw-rockchip.c`（+13/-1）。
  复现"冷启动不认卡、热重启正常"时先看这一处，别自己加 delay 乱试。
- 上电时序：`PWKEY` 必须在 `PCIE0_PWR_EN_3V3(GPIO4_B0)` 上电后按脉冲发；
  `modem-pwkey-pulse-ms = <1000>`、`modem-reset-pulse-ms = <500>`。
- 模组网络层（QMI/MBIM/rmnet）由板上 `/usr/bin/quectel-qmi-proxy`、`/usr/bin/quectel-mbim-proxy`、
  `/usr/bin/quectel-atc-proxy`、`/usr/bin/quectel-CM` 处理。

## 5. NVMe SSD

- 与 5G 共用 J1101（同一个 PCIe0 口），**同时只能插一个**。

### 5.1 裸盘 → 可用

```bash
# 1) 认设备
lspci -nn                                   # 01:00.0 Non-Volatile memory controller
ls -l /dev/nvme*                            # /dev/nvme0、/dev/nvme0n1（有分区再加 p1）
lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,MOUNTPOINT,FSTYPE,MODEL /dev/nvme0n1
fdisk -l /dev/nvme0n1

# 2) 分区（新盘只有整盘节点时）
fdisk /dev/nvme0n1    # 交互里依次：g（建 GPT）→ n（新分区，默认）→ w（写入）
partprobe /dev/nvme0n1                      # p1 没立刻出现时
ls -l /dev/nvme0n1p1

# 3) 格式化 + 挂载
mkfs.ext4 /dev/nvme0n1p1
mkdir -p /mnt/myssd && mount /dev/nvme0n1p1 /mnt/myssd
findmnt /mnt/myssd ; df -h /mnt/myssd

# 4) 读写测速
dd if=/dev/zero of=/mnt/myssd/testfile bs=1G count=1 oflag=direct
dd if=/mnt/myssd/testfile of=/dev/null bs=1G iflag=direct
rm -f /mnt/myssd/testfile ; sync
```

自动挂载（`/etc/fstab` 末尾，二选一；推荐 UUID 且带 `nofail`）：

```
UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  /mnt/myssd  ext4  defaults,nofail  0  2
```

`blkid /dev/nvme0n1p1` 查 UUID；写完 `mount -a` 验证。拆装前 `sync; umount /mnt/myssd`，再关机断电。
分区/格式化会破坏原数据，非空盘先备份。

### 5.2 省电掉线修复

- 内置支持 `bootargs_ext` 三个参数（见上，只改了 `.dts`）。
- 自动挂载/权限：板上 `/usr/local/sbin/quectel-fix-removable-perm.sh`；
  挂载点要 chown 给活动用户，否则 GNOME 里复制文件到 SSD 会报权限错误。
- 排查"用一会儿 SSD 掉了"：
  ```bash
  dmesg | grep -i nvme                  # 看是否有 controller reset / AER
  cat /sys/module/nvme_core/parameters/default_ps_max_latency_us   # 应为 0
  ```
  如果这个参数不是 0，说明 `bootargs_ext` 没生效（检查 U-Boot cmdline 拼接）。

## 6. 扩展场景

- **PCIe 网卡 / 采集卡**：只要走 PCIe0 且是标准 EP，通常免驱即可；
  注意 `perst-inactive-ms = 3000`、`wait-for-link-ms = 10000` 是给 5G 模组调的，
  某些卡需要单独调这两值。
- **USB + PCIe 同时用**：USB1（HUB）与 PCIe1 共用 `combphy1_psu`，所以只能用 PCIe0 + USB HUB，
  不能同时要 PCIe1。
- **从 NVMe 启动**：需要 uboot 支持，见 `sdk-flash/SKILL.md` / `sdk-build/SKILL.md`。

## 7. 已知坑

1. **`GPIO4_A7` 不是 PCIe1 使能**：M2 上它是 `DCDC_EN_3V3`（整版 3.3V）。
   `&vcc3v3_pcie1` 已被 disable 并删 gpios；照抄基线 `rk3576-evb.dtsi` 会导致整版 3V3 被别人抢。
2. **`GPIO4_B0` = PCIE0_PWR_EN_3V3**：不拉高，5G/NVMe 根本不供电（表现为 lspci 空、无 link）。
3. **40Pin 冲突**：`GPIO2_D4/D5` 同时是 RGMII1_MDC/MDIO，用 PCIe 5G HAT 时别开第二路以太网。
4. **resume 相关**：`rockchip,skip-scan-in-resume` 是刻意加的，别删。
5. **不要用 `sed` 改 dts**；`&pcie0` 的属性来自 `rk3576-evb.dtsi` + M2 dtsi 两层覆盖，改前 grep 全。
