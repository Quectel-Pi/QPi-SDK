---
name: simple-h1-ethernet
description: "simple-h1 SDK: 以太网 YT6801(PCIe0) 预置 ko 加载、DTS 供电/复位核对、RJ45 LED 与链路诊断"
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [qualcomm, qcs6490, quectel, simple-h1, ethernet, yt6801, pcie, led]
    related_skills: [simple-h1-pcie, simple-h1-build, simple-h1-wireless]
---

# simple-h1 以太网 — YT6801SH(PCIe0) + RJ45 LED

## 0. 能力边界（先读）

- 板上以太网是 **PCIe0 上的 YT6801SH**，不是 RGMII/MDIO PHY。
- **驱动源码不在本 SDK**（`kernel/` 里没有 `fuxi-gmac-*.c`，也没有 yt6801 目录），
  只有预置 ko：`overlay/lib/modules/6.6.116-qli-1.7-ver.1.1/updates/yt6801.ko`。
- 本 SDK 能做：**改 DTS**（供电/复位/链路）、**改内核选项**、**整文件换 ko**。
- 做不到：改驱动内部逻辑（LED 策略、中断处理、UAF 修复等），那需要厂商驱动源码重编；
  不要再写"改 fuxi-gmac-hw.c 再重编"这类步骤。

## 1. 硬件事实

| 项 | 值 |
|---|---|
| 芯片 | **YT6801SH**（裕太微 Motorcomm FUXI GMAC，QFN32），PCIe 千兆网卡 |
| 总线 | **PCIe0**（根口 `0000:00:00.0`，端点 `0000:01:00.0`，PCI ID `1f0a:6801`） |
| 连接器 | **`J1301`** RJ45，10/100/1000 自适应，带双色 LED |
| 3V3 供电 | `rtl8111h_3v3_vreg`，`gpio = <&tlmm 116>`（**历史命名，实际给 YT6801**） |
| PERST# | `perst-gpios = <&tlmm 87 GPIO_ACTIVE_LOW>` |
| PHY 供电 | `vdda-phy = vreg_l10c_0p88`、`vdda-pll = vreg_l6b_1p2` |
| RJ45 LED | LED0(PIN28)→**绿**、LED1(PIN29)→**未接**、LED2(PIN30)→**黄**（各串 330R） |
| 保护/电平 | `AW39204`、`ESD5304D`，部分 NM 未贴 |

DTS：`kernel/arch/arm64/boot/dts/qcom/qcs6490-idp-pi.dts:1123-1132`（3V3 vreg）、
`:1753-1757`（`&pcie0`）、`:1759-1763`（`&pcie0_phy`）。

```dts
&pcie0 {
    status = "okay";
    vdda-supply = <&rtl8111h_3v3_vreg>;      // tlmm116
    perst-gpios = <&tlmm 87 GPIO_ACTIVE_LOW>;
};
&pcie0_phy {
    status = "okay";
    vdda-phy-supply = <&vreg_l10c_0p88>;
    vdda-pll-supply = <&vreg_l6b_1p2>;
};
```

> **实测**（同板）：`lspci -nn` = `0000:01:00.0 Ethernet controller [0200]: Motorcomm YT6801 [1f0a:6801] (rev 01)`，
> 端点 `max_link_speed` 就是 `2.5 GT/s`（根口 8.0 GT/s），与 §4 结论一致。

## 2. 预置 ko

| ko（`overlay/lib/modules/6.6.116-qli-1.7-ver.1.1/updates/`） | 版本 | 说明 |
|---|---|---|
| `yt6801.ko` | v1.0.27 | 本板网卡，alias `pci:v00001F0Ad00006801` |
| `r8168.ko` | 8.049.02-NAPI | Realtek 8168 系列，换 Realtek 网卡的板型用，本板不用 |
| `tc956x_pcie_eth.ko` / `sprd_pcie.ko` | — | TC956x PCIe 转以太网 / 展锐 PCIe 控制器，属其它形态，别乱加载 |

`modinfo .../updates/yt6801.ko` 可看版本与 alias；`vermagic` 必须是 `6.6.116-qli-1.7-ver.1.1`。

```bash
lspci -nn | grep -i 1f0a        # 先确认端点被枚举
modprobe yt6801                 # depends 为空, 可直接加载
lsmod | grep yt6801 ; ip -br link
echo yt6801 > /etc/modules-load.d/yt6801.conf    # 开机自启 (或写进 overlay 同名路径)
```

`Unknown symbol` / `Invalid module format` = ko 与内核版本不匹配。

## 3. 设备侧诊断

```bash
ip -br link                              # 期望 eth0/eth1 之一 up
ethtool eth0 ; ethtool -i eth0           # driver: yt6801, version 1.0.27
cat /sys/class/net/eth0/carrier ; cat /sys/class/net/eth0/speed
lspci -nn | grep -i 1f0a                 # 先确认端点 (实测 lspci -vv 在本板会 segfault)
cat /sys/bus/pci/devices/0000:01:00.0/{max_link_speed,current_link_speed}  # 速率以此为准
ethtool -S eth0 | head -30               # 丢包/错误计数
dmesg | grep -iE "yt6801|fuxi|fxgmac"
iperf3 -c <host> ; nmcli dev status      # 吞吐 / NetworkManager 视角
```

**实测结论**：`modprobe yt6801` 后 eth0 在 **1-3 秒**内出现（实测第一次 `ip link` 可能还看不到，别在第 0 秒判定失败）；
未插网线时 `NO-CARRIER`、`speed = -1`。`ethtool` 报
`Speed 1000Mb/s / Full / Link detected: yes`；同网段 ping 开发机 0% 丢包（avg 0.46 ms），
`wget` 拉文件成功。⚠️ 该内网网关不回 ICMP、80/443/53 也不通——"ping 网关不通"不能当故障判据，
要判就用"能否 ping 通同网段真实主机 / 能否拉到文件"。

## 4. 链路速率怎么读（容易误判）

| 设备 | `max_link_speed` | `current_link_speed` | 结论 |
|---|---|---|---|
| `0000:00:00.0`（根口） | 8.0 GT/s | 2.5 GT/s | 根口能力到 Gen3 |
| `0000:01:00.0`（YT6801） | **2.5 GT/s** | 2.5 GT/s | **网卡芯片自身只支持 Gen1** |

`lspci -vv` 的 `LnkSta: Speed 2.5GT/s (downgraded)` 是**端点上限**，不是 DTS 限速；DTS 里真正
限速的只有 PCIe1（`max-link-speed = <1>`，`:1174`，见 `simple-h1-pcie`）。判据：读端点自己的
`/sys/bus/pci/devices/0000:01:00.0/max_link_speed`。

## 5. RJ45 LED（参考实现的实测结论）

LED 由 PHY 扩展寄存器控制（MDIO 0x1E 选地址 / 0x1F 读写）：`LED_CFG=0xA00B`、
`LED0_CFG=0xA00C`（绿）、`LED1_CFG=0xA00D`（未接）、`LED2_CFG=0xA00E`（黄）、`LED_BLINK=0xA00F`。

| 值 | 行为 |
|---|---|
| `0x1800` | 千兆匹配，常亮 |
| `0x2600` | 非千兆（百兆/10M）匹配，常亮 |
| `0x07` | 全速率常亮 + 活动闪（bit0 链路、bit1 活动、bit2 基础位） |
| `0x06` | 纯活动闪（无流量则灭） |
| `0x00` | 关闭 |

**根因（已定位）**：驱动从 eFuse Byte0（`EFUSE_LED_ADDR=0x00`，pos0/len5）取 LED 方案索引；
本板 `eFuse[0x00]=0xaa` → 索引 `0x0A`，既不合法也不等于 0x1F → 落 SOLUTION0
（LED0=0x2600 千兆不亮、LED2=0x00 禁用），表现为**千兆下两灯全灭**。现固件的 ko 已带修复：
link up 时按速率配置（1000M → 绿随数据闪 + 黄常亮；100M/10M → 绿常亮 + 黄随数据闪）。

**换 ko 的注意**：LED 行为写在 ko 里，换 ko 就丢；当前 `yt6801.ko` 已是修好的版本，别为"干净"替换成来源不明的同名 ko。百兆场景未实测。

## 6. 换 ko / 固化（本 SDK 唯一可行路径）

```bash
# 临时验证: 设备侧替换
adb push yt6801.ko /tmp/yt6801.ko.new
adb shell "cp /lib/modules/\$(uname -r)/updates/yt6801.ko /tmp/yt6801.ko.orig"
adb shell "cp /tmp/yt6801.ko.new /lib/modules/\$(uname -r)/updates/yt6801.ko"
adb shell "depmod -a; rmmod yt6801; modprobe yt6801; dmesg | tail -20"

# 固化进镜像: 覆盖 overlay 里的同名 ko, 只重打 system.img
cp yt6801.ko overlay/lib/modules/6.6.116-qli-1.7-ver.1.1/updates/yt6801.ko
SKIP_KERNEL=1 ./scripts/build-all.sh
./scripts/flash.sh
```

## 7. 已知坑

1. **`rtl8111h_3v3_vreg` 是历史命名**，别当 Realtek PHY，也别删——它是 YT6801 的 3V3 使能（tlmm116）。
2. **先查黑名单**：`grep -rs yt6801 /etc/modprobe.d/`。实测 A（Debian/6.6.52）有
   `blacklist-yt6801.conf`，`ip -br link` 里没有 eth0；实测 B（qcom-wayland/6.6.116）没有该文件。
   注意 **`blacklist` 只影响按 alias 自动加载，显式 `modprobe yt6801` 仍会加载** —— 先 modprobe 试一次，
   再决定要不要改黑名单，别把“没网口”直接归因到黑名单。
3. **"没有网口"排查顺序**：`lspci` 有无端点 → 黑名单 → ko 版本 → DTS 供电/复位。
4. **LED 不亮 ≠ 网络不通**：先看 `ethtool` 的 `Link detected` 与 `Speed`，正常才轮到 LED。
5. **改 PCIe0 就是改以太网**：`vdda-supply`/`perst-gpios` 是网卡上电与复位，动完要回归网络。
6. **高频大流量偶发 oops 属驱动内部问题**，本 SDK 无法就地修：先切回已验证的 ko。
7. **`r8168.ko`/`sprd_pcie.ko` 不是 yt6801 的替代**：PCI ID 不匹配，加载也不认卡。

## 8. 扩展

- **第二路网口**：板载只有 1 个 RJ45；用 Type-C → USB 网卡（A 口仅 480 Mbps）。
- **PTP / 网络启动 / POE**：`ethtool -T eth0` 确认时间戳；bootloader 是否枚举 PCIe 未验证；`J1301` 不支持 POE。
