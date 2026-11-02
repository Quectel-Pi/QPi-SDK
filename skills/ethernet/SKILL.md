---
name: ethernet
description: "Quectel PI M2 以太网：GMAC0 + YT8531SC PHY（RGMII 直连、RJ45 J0701）+ 40Pin 引出的第二路 RGMII1；DTS、PHY 复位/使能 GPIO、接口名变 enP* 的原因、网口不通与丢包排查、FCT 网口测试。当用户说「M2 网口不通」「加了第二路网口」「接口名 enP」「PHY 没起来」「网口丢包」时使用。WHEN: M2 ethernet, GMAC0, YT8531, RGMII1, PHY reset, enP*, link down, 网口不通, 第二路以太网. DO NOT USE FOR: Wi-Fi/BT（用 wireless），Linux 侧 DNS/路由类问题（用 quectel-network-debugging）。"
license: MIT
metadata:
  author: Quectel PI M2 外设 SKILL 库
  version: "1.0.0"
  board: Quectel PI M2 (RK3576 / QSM610ZAP-WF)
---

# M2 以太网 SKILL — YT8531 + GMAC0 + 40Pin 上的第二路 RGMII1

适用：Quectel PI M2（`quectel,pi-m2-rk3576`）。

## 1. 硬件事实

| 项 | 值 |
|---|---|
| PHY | **YT8531SC-CA**（U0702，Motorcomm，10/100/1000M，48-QFN） |
| MAC | RK3576 **GMAC0**，RGMII 模式（`phy-mode = "rgmii-rxid"`） |
| 时钟 | `ETH_CLK0_25M`（模组 pin314，`RGMII_REFCLKOUT`），DTS `clock_in_out = "output"` |
| 连接器 | **J0701** RJ45（带 LED + POE 触点），对应 POE 引出 **J0702**（2×2，POE1..POE4） |
| PHY 复位 | `GMAC0_RST_N`（模组 pin238 = **`GPIO0_C3`**），经电平转换；DTS 用 `reset-gpios` + `reset-assert-us = 20000` / `reset-deassert-us = 100000` |
| PHY 中断 | `GMAC0_INT`（模组 pin237 = **`GPIO1_D4`**），经电平转换 |
| PHY 上电 | `ETH_PWR_EN`（模组 pin236 = **`GPIO3_D0`**），高=以太网芯片电源开。pinmap 明确：**复位靠断电再上电实现，断电保持 ≥10ms** |
| MDIO | GMAC_MDC/MDIO（模组 pin240/239），MDIO 上 `rgmii_phy0: phy@0`（`reg = <0x0>`） |
| 指示灯 | 黄灯→PHY LED1，绿灯→PHY LED2，**低电平点亮**，工作状态由 PHY 内部寄存器配置 |
| 第二路 ETH | **RGMII1 只引到 40Pin**（J1501 pin 22/29/31/33/35/36/37/38/40…），见 `40pin/SKILL.md` |

> PHY 与 40Pin 复用注意：`RGMII1_*` 与 `SPI1_*` **共用同一批 40Pin 引脚**
> （如 `RGMII1_RXC ↔ SPI1_MOSI_M1`）。做第二路以太网必须先把 SPI1 关掉，
> 反之亦然 —— 这就是 `qpi-config {spi1|i2c3|i2c7|uart1} disable` 存在的原因（只有这四个开关，见 `40pin/SKILL.md`）。

## 2. DTS 实现

公共 `rk3576-quectel-pi-common.dtsi`：

```dts
&mdio0 {
    rgmii_phy0: phy@0 {
        compatible = "ethernet-phy-ieee802.3-c22";
        reg = <0x0>;
        clocks = <&cru REFCLKO25M_GMAC0_OUT>;
    };
};
```

M2 专属 `rk3576-quectel-pi-m2-linux.dtsi`：

```dts
vcc_eth_phy: vcc-eth-phy {                 /* GPIO3_D0：以太网芯片电源使能 */
    compatible = "regulator-fixed";
    enable-active-high;
    gpio = <&gpio3 RK_PD0 GPIO_ACTIVE_HIGH>;
    startup-delay-us = <10000>;
    regulator-boot-on; regulator-always-on;
    vin-supply = <&vcc_3v3_s0>;
};

&gmac0 {
    phy-mode = "rgmii-rxid";
    clock_in_out = "output";
    reset-gpios = <&gpio0 RK_PC3 GPIO_ACTIVE_HIGH>;
    reset-assert-us = <20000>;
    reset-deassert-us = <100000>;
    pinctrl-0 = <&eth0m0_miim &eth0m0_tx_bus2 &eth0m0_rx_bus2
                 &eth0m0_rgmii_clk &eth0m0_rgmii_bus
                 &ethm0_clk0_25m_out &eth_phy_rst>;
    tx_delay = <0x20>;
    /* rx_delay = <0x3f>; */               /* 需要时打开微调 */
    phy-handle = <&rgmii_phy0>;
    phy-supply = <&vcc_eth_phy>;
    status = "okay";
};

&pinctrl { eth_phy { eth_phy_rst: eth-phy-rst {
    rockchip,pins = <0 RK_PC3 RK_FUNC_GPIO &pcfg_pull_none>; }; }; }
```

`tx_delay` 是板级 RGMII 时序；换线长/换 PHY 时重点调它，其次 `rx_delay` 与 `phy-mode`
（`rgmii` / `rgmii-id` / `rgmii-rxid` / `rgmii-txid`）。

## 3. 使用与诊断

```bash
ip -br link                        # 期望看到 eth0（不是 enP4p65s0 之类）
ethtool eth0                       # Speed/Duplex/Link detected
ethtool -S eth0 | head             # YT8531 统计
cat /sys/class/net/eth0/carrier
iperf3 -c <host>
mii-tool / mdio-tool（若在 rootfs 中）
```

- **接口名固定回 eth0**：systemd 可预测命名已禁用。
  如果看到 `enP...`/`end...` 命名，说明可预测命名又回来了，改 systemd/udev 策略。
- **FCT 网口测试**：端口与 AT 指令见 `debug-fct/SKILL.md`；
  注意：SN 丢失会让 FCT 网口测试失败，先确认 `persist` 里的 SN。

## 4. 适配要点 / 扩展场景

### 4.1 换 PHY 或换 PHY 地址

- `reg = <0x0>` 必须与硬件 PHY 的 strap 地址一致（YT8531 strap 由引脚上下拉决定）。
  读不到 PHY 的现象：`mdio` 全 0xffff、`ethtool` 报 "no PHY"。
- 若 PHY 需要额外寄存器初始化（YT8531 的 RGMII delay、LED 极性），用
  `phy-handle` 节点里的 `motorcomm,*` 属性或 PHY driver 的固定配置，别在 MAC 节点上乱加。

### 4.2 第二路以太网（RGMII1）

1. 关掉占用的 40Pin 功能：`qpi-config spi1 disable`（必要时再 `i2c3`/`i2c7`/`uart1`），**重启**。
2. 在板级 DTS 里打开 `&gmac1`，`pinctrl` 用 `eth1m*` 系列，复位脚 `ETH1_RST_N = GPIO2_B4`，
   MDC/MDIO 用 `GPIO2_D4`/`GPIO2_D5`（默认是 GPIO 功能，需切 mux）。
3. 注意 `RGMII1_MCLK`(GPIO2_D7) 与 `RGMII1_RST_N`(GPIO2_B4) 等脚在 pinmap 里默认都是 **GPIO 功能**，
   要显式复用。
4. 40Pin 上的 `ETH1_MDC/MDIO` 在 DTS 里被用作 **PCIe 5G HAT 的 pwkey/reset**（见 `pcie/SKILL.md`），
   **两件事冲突**，二选一。

### 4.3 POE

J0701 带 POE 触点，J0702 把 POE1..POE4 引出。板卡只做**电气引出**，
POE 供电由外部注入模块决定，软件侧没有 POE 控制器。

## 5. 已知坑

1. **PHY 断电没保持 ≥10ms** → 复位不生效。DTS 已经用 `reset-assert-us = 20000` 覆盖，
   但如果你改用 PHY driver 的 `snps,reset-gpio` 风格属性，注意 M2 用的是**标准 `reset-gpios`**。
2. **`GPIO3_D0` 与 40Pin/其它功能混用**：它是 `ETH_PWR_EN`，不是普通 GPIO；被别人占了以太网直接不工作。
3. **`qpi-config` 的 40Pin 开关重启才生效**（标记文件 + U-Boot 应用 dtbo），
   当场改了不重启会以为"没效果"。
4. **link 上但丢包/协商到 100M**：先看 `tx_delay`，再看网线/PHY strap。
5. 不要在 M2 上找 `SATA`/`PCIE1` 的以太网复用；M2 DTS 里 `&sata0` 是 **disabled**（common 里 okay，
   M2 关掉是因为组合 PHY 在 S3 恢复时会 external abort）。
