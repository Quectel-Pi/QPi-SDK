---
name: simple-h1-pcie
description: "simple-h1 SDK: PCIe0(YT6801 网卡) 与 PCIe1(NGFF 插槽 NVMe/5G) 的 DTS 时序、预置 MHI ko、限速与上电排查"
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [qualcomm, qcs6490, quectel, simple-h1, pcie, nvme, mhi, 5g, yt6801]
    related_skills: [simple-h1-ethernet, simple-h1-usb, simple-h1-build]
---

# simple-h1 PCIe — PCIe0(网卡) + PCIe1(NGFF: NVMe 或 5G)

## 1. 硬件事实

| 控制器 | 用途 | 连接器 | 关键资源 |
|---|---|---|---|
| **PCIe0** | 板载 **YT6801SH 千兆网卡**（不可换） | 内部 | `vdda-supply = rtl8111h_3v3_vreg`（tlmm116）、`perst-gpios = tlmm87`；PHY：`vreg_l10c_0p88` / `vreg_l6b_1p2` |
| **PCIe1** | **NGFF 插槽**：NVMe SSD **或** 5G 模组（二选一） | **`J0901`** | 见下表 |

### PCIe1 全部控制脚

| 功能 | GPIO / 属性 | 说明 |
|---|---|---|
| 3V3 使能 | `pcie1_pwr_en_vreg` → **tlmm 24** | `regulator-fixed` + `enable-active-high`，ramp-delay 10 ms |
| PERST# | `perst-gpios = <&tlmm 2 GPIO_ACTIVE_LOW>` | pinctrl `output-low`，drive-strength 16 |
| PWRKEY（5G） | `pwkey-gpios = <&tlmm 49 GPIO_ACTIVE_LOW>` | pinctrl `output-high`；`pwkey-pulse-ms = <1000>` |
| 电平转换使能 | `pcie1_level_en` → **tlmm 93** | 板上电平转换器使能 |
| DEVICE OE | `device_oe_en` → **tlmm 9** | 输出使能（⚠ 与 40Pin `pin40_en_vreg` 同脚） |
| WAKE# | `pcie1_wake_n` → **tlmm 3** | `bias-pull-up` 输入 |
| CLKREQ# | `pcie1_clkreq_n` | 在 `pinctrl-0` 列表中 |
| 上电延时 / 训练窗口 | `delay-ms = <3000>`、`wait-for-link-ms = <10000>` | 冷启动 5G 模组的时序 |
| **链路速率上限** | **`max-link-speed = <1>`** | ⚠ **Gen1**（注释写明为 5G HAT 限速） |
| SMMU 映射 | `iommu-map = <0x0 &apps_smmu 0x1c80 0x1>, ...` | 9 条 SID |

DTS 依据（`kernel/arch/arm64/boot/dts/qcom/qcs6490-idp-pi.dts`）：
`:1123-1132`（`rtl8111h_3v3_vreg`）、`:1133-1142`（`pcie1_pwr_en_vreg`）、
`:1163-1187`（`&pcie1`，`max-link-speed` 在 `:1174`）、`:1189-1194`（`&pcie1_phy`）、
`:1459-1500`（PCIe1 全部 pinctrl）、`:1753-1757`（`&pcie0`）、`:1759-1763`（`&pcie0_phy`）。

```dts
&pcie1 {
    vdda-supply = <&pcie1_pwr_en_vreg>;
    perst-gpios = <&tlmm 2 GPIO_ACTIVE_LOW>;
    pinctrl-0 = <&pcie1_power_en>, <&pcie1_power_key>, <&device_oe_en>,
                <&pcie1_level_en>, <&pcie1_reset_n>, <&pcie1_wake_n>, <&pcie1_clkreq_n>;
    delay-ms = <3000>;
    pwkey-gpios = <&tlmm 49 GPIO_ACTIVE_LOW>;
    pwkey-pulse-ms = <1000>;
    wait-for-link-ms = <10000>;
    max-link-speed = <1>;              // 改成 <3> 即放开 Gen3
    iommu-map = <...>;
    status = "okay";
};
```

**硬件能力 vs 配置**：插槽是 1-lane PCIe 3.0（8 GT/s），但 DTS 限在 **Gen1**——
这是"规格 vs 实现"的已知差异，放开前先确认下游设备与 FPC 线材。

## 2. 上电/枚举流程（5G 模组）

由 `pcie-qcom` 控制器驱动自动完成，出问题按这个顺序查：

1. tlmm24 拉高（3V3）→ 2. `pwkey` 脉冲 1 s（tlmm49）→ 3. `perst` 释放（tlmm2）→
4. 链路训练（最长 `wait-for-link-ms = 10000`）→ 5. 枚举 → 6. MHI/QRTR 起来。

空槽或 5G 冷启动**不阻塞开机**：控制器在 DTS 带 `wait-for-link-ms` 时把 host bring-up
丢到 workqueue 延后执行（`kernel/drivers/pci/controller/dwc/pcie-qcom.c:1629-1668`，
`schedule_work` 在 `:1831`）。若出现"开机卡在等 PCIe"，先看这段延后逻辑是否被改掉。

## 3. 预置 ko 与内核选项

| ko | 依赖 | 用途 |
|---|---|---|
| `overlay/lib/modules/6.6.116-qli-1.7-ver.1.1/updates/pcie_mhi.ko` | `mhi` | PCIe MHI 主机接口（5G 模组数据通路） |
| `.../updates/qca6490.ko` + `.../updates/cnss2/cnss2.ko` | `cnss2,cnss_nl,...` | PCIe 接口的 WCN6750 Wi-Fi（本板外挂 SDIO 方案不用） |
| `.../updates/sprd_pcie.ko` | — | 展锐 PCIe 控制器，其它形态 |
| `.../updates/tc956x_pcie_eth.ko` | — | TC956x PCIe 转以太网，扩展形态 |

内核内建（`scripts/kernel-config`）：`CONFIG_PCI=y`、`CONFIG_PCIE_QCOM=y`、
`CONFIG_PCIE_DW_PLAT_HOST=y`、`CONFIG_PHY_QCOM_QMP_PCIE=y`；模块：
`CONFIG_MHI_BUS=m`、`CONFIG_MHI_BUS_PCI_GENERIC=m`、`CONFIG_MHI_NET=m`、`CONFIG_QRTR_MHI=m`。

源码位置：`kernel/drivers/pci/controller/dwc/pcie-qcom.c`（控制器）、
`kernel/drivers/phy/qualcomm/phy-qcom-qmp-pcie.c`（PHY）、
`kernel/drivers/bus/mhi/host/pci_generic.c`（MHI 枚举表）。

> **实测**（同板）：`0000:00:00.0` 根口 `max_link_speed = 8.0 GT/s`，`0000:01:00.0`（YT6801）
> **`2.5 GT/s`**（端点自身 Gen1-only），`0001:00:00.0`（PCIe1 根口）`2.5 GT/s`（DTS `max-link-speed=<1>`）。

## 4. 设备侧诊断

```bash
lspci -nn                                  # 期望: 01:00.0 网卡; 插槽设备另一 BDF
lspci -nn | head                            # 实测 A 的 lspci -vv 会 segfault; 实测 B 正常, 仍建议用 sysfs
cat /sys/bus/pci/devices/*/max_link_speed   # 协商速率看 sysfs 更稳
ls /sys/bus/pci/devices/                   # 看设备是否被枚举
# NVMe
lsblk ; cat /sys/class/nvme/nvme0/model 2>/dev/null ; nvme list
# 5G（MHI / QRTR）
lsmod | grep -iE "mhi|qrtr" ; ls /dev/mhi* ; ls /dev/qrtr* 2>/dev/null
dmesg | grep -iE "pcie|msm_pcie|phy|link up|mhi"
```

**速率判读**：`lspci` 对 YT6801 常打印 `LnkSta: Speed 2.5GT/s (downgraded)`，
但该端点 `max_link_speed` 本身就是 2.5 GT/s（Gen1-only 芯片），根口是 8.0 GT/s。
判据是端点自己的 `/sys/bus/pci/devices/<BDF>/max_link_speed`，**不是**降速字样。

## 5. 改 DTS 后的构建路径

```bash
# 只改设备树
./scripts/build-kernel.sh          # 重编 Image + dtb
./scripts/pack-dtb.sh              # dtb.bin 里的 combined-dtb.dtb
./scripts/pack-efi.sh              # UKI 里也带 dtb, 必须一起重打
./scripts/flash.sh

# 或一条命令
./scripts/build-all.sh
```

只跑 `pack-dtb.sh` 而不跑 `pack-efi.sh`，启动用的 UKI 里还是旧 dtb。

## 6. 已知坑

1. **`max-link-speed = <1>` 把 NVMe 限到 Gen1**（约 1 GB/s 量级）；要满速改 `:1174`
   为 `<3>` 或删掉，然后回归 SSD 稳定性。
2. **`pcie1_pwr_en_vreg` 不使能 → 插槽完全没电**（`lspci` 空、无 link）。
   它是 `regulator-fixed` + `enable-active-high`，量 tlmm24 实际电平，别只看 DTS。
3. **`pwkey-pulse-ms=1000` 与 `delay-ms=3000` 是按 5G 模组调的**；换模组要重标定，
   否则典型症状是"冷启动不认卡、热重启正常"。
4. **别删 `iommu-map`**：5G 模组/网卡依赖 SMMU SID 映射，删了会 DMA 失败（或直接不枚举）。
5. **`rtl8111h_3v3_vreg` 名字是历史遗留**，实际是 PCIe0 上 YT6801 的 3V3，别删别改名。
6. **`device_oe_en` 用 tlmm9，与 40Pin `pin40_en_vreg` 撞脚**（`:1930-1940`）；
   两处同时使能会互相覆盖，改 PCIe1 时留意。
7. **不支持热插拔**：空槽不阻塞开机，但插拔后请重启再验。
8. **PCIe1 只引了 PCIe，没有 USB**：USB 型 Wi-Fi 卡插上不会枚举；只能接 PCIe 设备。
9. **PCIe1 只有 1 lane**，不要挂 PCIe 交换机（带宽和供电都不够）。
10. **`&swr2` 被禁用是让给 PCIe1**（`:1354` `//for PCIE1`），插着 PCIe1 设备时别指望
    WSA 功放；反之启用 swr2 前先确认 PCIe1 不用。
11. **动完 PCIe 要回归 USB3/Type-C**：PCIe/USB3/DP 在 SoC 层共享部分 SerDes 与时钟。

## 7. 扩展

- **换 NVMe 要满速**：改 `max-link-speed` + 换好线材 + 量 3V3 压降。
- **5G 模组**：`pcie_mhi.ko` 起来后按 `ls /dev/mhi*`、`dmesg | grep mhi` 查通道；
  QRTR 依赖 `CONFIG_QRTR_MHI`。
- **空槽排查**：先确认 `lspci` 有没有根口（`00:00.0`），再确认插槽供电，最后看 link 训练日志。
- **PCIe 网卡形态**：`tc956x_pcie_eth.ko` / `sprd_pcie.ko` 属其它硬件形态，本板不要加载。
