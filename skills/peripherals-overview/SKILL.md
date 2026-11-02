---
name: peripherals-overview
description: "Quectel PI M2（RK3576 / QSM610ZAP-WF 载板）板级外设总览与硬件事实基线：外设→器件→连接器→总线/GPIO 映射、电源使能矩阵、板卡标识、上板自检命令。当用户问「M2 有哪些外设」「M2 引脚怎么分配」「M2 电源怎么使能」「板卡怎么识别」「改 M2 驱动/DTS 从哪开始」时使用。WHEN: M2 peripherals overview, RK3576 board hardware, pin map, power enable matrix, board identify, 外设总览, 硬件基线, 连接器速查, 电源使能. DO NOT USE FOR: 具体外设的适配/排查（用对应 display / audio / camera 等分册），编译烧录（用 sdk-build / sdk-flash）。"
license: MIT
metadata:
  author: Quectel PI M2 外设 SKILL 库
  version: "1.0.0"
  board: Quectel PI M2 (RK3576 / QSM610ZAP-WF)
---

# M2 外设总览 SKILL — Quectel PI M2 (QSM610ZAP-WF / SH603ZA + RK3576)

> 本文件是 **M2 板的外设索引与硬件事实基线**。写/改 M2 驱动、DTS、应用前先读这里，
> 再进对应外设的分册 SKILL。所有引脚、连接器、器件型号均来自 M2 硬件资料，不靠推测。

## 板卡识别（先确认改的是 M2 的文件）

本仓库里还有另一块 RK3576 板的 dts 和一份多板共用的公共 dtsi，硬件与 40Pin 机制都不同：

| 项 | M2 |
|---|---|
| compatible | `quectel,pi-m2-rk3576` |
| model | `Quectel PI M2 RK3576 Board` |
| 板级 DTS | `rk3576-quectel-pi-m2-linux.dts` + `.dtsi` |
| 公共 dtsi | `rk3576-quectel-pi-common.dtsi`（多板共用，动它会影响另一块板） |
| 40Pin 机制 | 功能复用（i2c3/i2c7/spi1/uart1 使能开关；pwm2 直接走 sysfs） |
| 无线模组 | FCS960K（AIC8800 SDIO + UART4 BT） |
| 显示 | DSI + **原生 HDMI**（无 DP/eDP） |
| RTC | AIP8563（= pcf8563）@0x51 |

板级差异只写进 M2 自己的 dtsi；`rk3576-quectel-pi-common.dtsi` 是多板共用文件，改之前先确认对另一块板的影响。

## 板卡标识 / 硬件资料位置

| 项 | 值 |
|---|---|
| 模组 | QUECTEL `SH603ZAAPNA-G61-UNNNA`（U0201，内含 RK3576 SoC） |
| 载板 PCB | `QSM610ZAP-WFPI` V1.1，8L HDI，85×56mm |
| BOM | `QSM610ZAP-WF_V1.1_BOM260624`，产品 P/N `Q1-D1116` |
| Pinmap / BOM / 网表源文件 | **不随本仓库提供**；本文与板级 DTS 已固化用到的位号、型号、引脚 |

原理图分页（可当外设清单参考）：`02-MODULE PART1` / `06-USBHUB` / `07-ETH MAC` /
`09-AUDIO` / `17-FCS960K_or_FC905A`。位号（U/J/D/Q 开头）与模组引脚号以本文表格为准。

## 外设总览（外设 → 器件 → 连接器 → 总线/引脚 → 分册 SKILL）

| 外设 | 器件 / 接口 | 连接器 | 关键引脚（GPIO 别名 = DTS 宏） | 分册 |
|---|---|---|---|---|
| MIPI-DSI 屏 | LCM DSI 4-lane（实用 2 lane） | J1201 | LCM_PEN `GPIO3_C5` | `display/SKILL.md` |
| 触摸 TP | 触摸 IC（挂在 LCM 连接器） | J1201 pin20/21/17/18 | TP I2C0、TP_RST、TP_INT | `display/SKILL.md` |
| HDMI | RK3576 **原生 HDMI TX**（无独立 PHY IC） | J1401 | HDMI_TX_ON_H `GPIO4_C6`、HPD=模组 pin188（无 GPIO 宏） | `display/SKILL.md` |
| 摄像头 Camera1 | MIPI CSI0（DC-PHY0） | J1002 | I2C4、CAM0_RST `GPIO3_D5`、CAM0_PWDN `GPIO3_C7`、CAM0_MCLK | `camera/SKILL.md` |
| 摄像头 Camera2 | MIPI CSI3（DPHY3） | J1001 | I2C5、CAM3_RST `GPIO3_D6`、CAM3_PWDN `GPIO3_D4`、CAM3_MCLK | `camera/SKILL.md` |
| 音频 Codec | ES8389 (U0901) @0x10 | — | I2C2 + SAI1(M0)，CODEC_PWTR_EN `GPIO0_C6` | `audio/SKILL.md` |
| 喇叭功放 | AW8010BFCR (U0903) | J0901 | SPK_SD `GPIO4_B2` | `audio/SKILL.md` |
| 耳机 | 3.5mm jack (J0902) | J0902 | HPH_DET `GPIO2_D6` + SARADC4 | `audio/SKILL.md` |
| 板载 MIC | MEMS MIC (U0902) | — | — | `audio/SKILL.md` |
| BT 音频 | SAI2 (M0) PCM | — | SAI2 | `audio/SKILL.md` |
| 以太网 | YT8531SC-CA (U0702) + GMAC0 | J0701 (RJ45) | ETH_PWR_EN `GPIO3_D0`、GMAC0_RST_N `GPIO0_C3`、GMAC0_INT `GPIO1_D4` | `ethernet/SKILL.md` |
| 第二路以太网 | RGMII1（仅引到 40Pin） | J1501 | ETH1_MDC/MDIO/`RGMII1_*`、ETH1_RST_N `GPIO2_B4` | `ethernet/SKILL.md` |
| Wi-Fi | FCS960K / AIC8800 SDIO (U1702) | 天线 J1702 | WIFI_BT_PWR_EN `GPIO3_A3`、WMOB_PWRKEY_WIFI_EN `GPIO2_B3`、WLAN_WAKE_HOST `GPIO0_D3`、HOST_WAKE_WLAN `GPIO4_A0` | `wireless/SKILL.md` |
| 蓝牙 | FCS960K UART4(M1) 四线 + PCM | 天线 J1701 | BT_WAKE_HOST `GPIO1_C6`(pin13)、HOST_WAKE_BT `GPIO1_C7`(pin14) | `wireless/SKILL.md` |
| USB0 OTG | RK3576 USB3.1 SuperSpeed | J1602（双层 A 的上层） | USB0_PWR_EN `GPIO0_D1`（ETA6280S2F） | `usb/SKILL.md` |
| USB1 Host | CH634M USB3.0 HUB (U0601) | J1601 双层 + J1602 下层 | USB1_PWR_EN `GPIO0_A0` | `usb/SKILL.md` |
| Type-C | 仅 5V 供电 + CC（**无数据**） | J0501 | — | `usb/SKILL.md` |
| TF 卡 | SDMMC0 | J0801 | SD_EN `GPIO0_B6`、无 CD（`broken-cd`） | `storage/SKILL.md` |
| eMMC / UFS | 模组内 | — | — | `storage/SKILL.md` |
| PCIe0 | RK3576 PCIe0 4-lane | J1101 | RST `GPIO0_B4`、WAKE `GPIO0_D2`、CLKREQ `GPIO2_B2`、PWR_EN `GPIO4_B0`；HAT 侧 pwkey `GPIO2_D5` / reset `GPIO2_D4` | `pcie/SKILL.md` |
| RTC | AIP8563MA8 (U1301) @0x51，= pcf8563 | 电池 J1301 | RTC_IRQ_N `GPIO0_A5`（当前 pinmap 标为复用，见分册） | `rtc-keys/SKILL.md` |
| 按键 | PON / PWRKEY / VOL_UP / MASKROM / RESET_N | S0401 S0402 S0403 | 模组 pin 7/8/10/9/12 | `rtc-keys/SKILL.md` |
| 风扇 | PWM1_CH1_M0 → MOS Q0401 | J0401 | PWM1_1V8（`GPIO0_B5`/PWM1） | `fan-thermal/SKILL.md` |
| LED | PWM0_CH0_M0 → 数字三极管 Q0402 → D0407 | — | PWM0_1V8 | `led/SKILL.md` |
| 40Pin 扩展 | I2C3/I2C7/SPI1/UART1/UART8/PWM2/CAN0/RGMII1/SAI4 | J1501 | 见 40Pin 分册 | `40pin/SKILL.md` |
| 调试串口 | DBG UART（经电平转换） | J1502 (3Pin) | DBG_RX/TX | `debug-fct/SKILL.md` |
| 电源/PM | DCDC_EN_3V3 等使能链 + S3 休眠 | — | `GPIO4_A7` 等 | `power-pm/SKILL.md` |

## 连接器速查（位号来自网表，勿凭印象）

| 位号 | 型号/规格 | 用途 |
|---|---|---|
| J1001 | A050102213M011ARA 22Pin 0.5mm | **Camera2**（CSI3 / I2C5 / CAM1_VCC_3V3） |
| J1002 | HRS TF38-22S-0.5SV 22Pin | **Camera1**（CSI0 / I2C4 / CAM0_VCC_3V3） |
| J1201 | A050102213M011ARA 22Pin 0.5mm | **LCM**（DSI 4lane / TP I2C0 / LCM_RST / LCM_INT） |
| J1101 | KR05VS1613M0101RW 16Pin | **PCIe0**（M.2 / PCIe HAT） |
| J1401 | MUP-H21602-02 | HDMI Type-A |
| J0501 | TCR12-32111601-A1 Type-C 16Pin | Type-C（仅 5V + CC，无 USB 数据） |
| J1601 | 70001W9-018G-0AU35 | USB-A 双层：HUB Port2 + HUB Port3 |
| J1602 | 70001W9-018G-0AU35 | USB-A 双层：上层 USB0(OTG)，下层 HUB Port4 |
| J0701 | D111Q334AB2A1DP（带 LED & POE） | RJ45 |
| J0702 | C2542VD202PTC3PH 2×2 | POE 引出（POE1..POE4） |
| J0801 | MUP-M616-1 | TF 卡座（翻盖式，无热插拔 CD） |
| J1501 | C2542VD220PTC3PH 2×20 | 40Pin 扩展排针 |
| J1502 | C254VD103G01B1PH 1×3 | 调试串口 |
| J1301 | KRC100VS102T011RA | RTC 备份电池（RTC_BAT_P） |
| J0401 | KRC1250RS102T011RA | 风扇（FAN_L，4Pin） |
| J0901 | KRC1250RS102T011RA | 喇叭（VOP/VON） |
| J0902 | PJ35A063-F06G1BR-A | 3.5mm 耳机 |
| J1701 / J1702 | ECT818000500 | 天线：BT / Wi-Fi |

## 电源使能矩阵（改硬件行为前先看这张表）

来自 pinmap `Power使能汇总` sheet，**默认都是低电平断开**：

| 域 | 控制引脚 | GPIO 宏 | 默认 | 备注 |
|---|---|---|---|---|
| 整版 3V3（DCDC 3V3 ALL） | 模组 pin17 | `GPIO4_A7` | 低下拉 | **用 40Pin-3V3 / Wi-FiBT / SD 卡时必须先拉高** |
| USB1 HUB + 下行 A 口 | pin352 | `GPIO0_A0` | 低 | 高=HUB 与 A 口上电 |
| USB0 USB-A 口 | pin25 | `GPIO0_D1` | 低 | 仅模组做 host 时开；内核由 PHY 模式自动管理 |
| 以太网 | pin236 | `GPIO3_D0` | 低 | 高=PHY 上电；复位靠断电再上电（保持 ≥10ms） |
| Codec DVDD | pin40 | `GPIO0_C6` | 低 | 高=Codec DVDD 开；VCC3V3 另由模组 LDO4_3V3 供，需手动开 |
| Camera0 3V3 | pin64 | `GPIO3_C7` | 低(下拉) | 高=3.3V 上电 |
| Camera1 3V3 | pin287 | `GPIO3_D4` | 低(下拉) | 高=3.3V 上电 |
| LCM 3V3 | pin235 | `GPIO3_C5` | 低(下拉) | 高=3.3V 上电 |
| 40PIN 3V3 | pin39 | `GPIO0_C7` | 低(下拉) | M2 DTS 里是 `gpio-hog` output-high |
| Wi-Fi/BT | pin360 | `GPIO3_A3` | 高=开 | — |
| PCIe 3V3 | pin300 | `GPIO4_B0` | 高=开 | — |

## 一上板就能跑的自检（不依赖 GUI）

```bash
# 板型确认
tr '\0' '\n' < /proc/device-tree/compatible | head -3
# 各类设备
ls /dev/video* /dev/mmcblk* /dev/i2c-* /dev/spidev* /dev/ttyS* /dev/hidraw* 2>/dev/null
cat /proc/device-tree/model
# I2C2（Codec 0x10 + RTC 0x51）
i2cdetect -y 2
# 显示
cat /sys/class/drm/card0-*/status
# 电源使能实际电平（导出 GPIO 后读）
```

## 「文档 vs 实现」不一致 —— **三处都已上板定案（2026-10-10）**

1. **RTC 型号**：早期硬件文档写 M2 用 `RX8130`，但 BOM 位号 U1301 是
   `AIP8563MA8`（I-CORE），M2 DTS 也用 `nxp,pcf8563 @0x51`。以 DTS + 网表为准。
   ✅ **2026-10-10 上板实测通过**：`i2cdetect -y 2` 见 `0x10+0x51`、`/dev/rtc0` 在、跨重启系统时间由 RTC 恢复 —— 详见 `rtc-keys/SKILL.md` §0。
2. **BOOTKEY 通道** → ✅ **已用实测数据定案（原注释是错的）**：
   SARADC **ch4 = 888mV = `BOARD_ID`（pin18/ADC4，分压，非按键）**；
   SARADC **ch1 才是按键线（VOL_UP, pin10，idle 1.8V）**。且 M2 的 `/delete-node/ v_up_key;`
   因节点名是 `v-up-key`（连字符）而**失效**，`boot-key`(KEY_POWER) 与残留的 `v-up-key` 同挂 ch1
   → 按 VOL+ 会同时报两个事件。实测细节见 `rtc-keys/SKILL.md` §4。
3. **LCM 连接器旁注** → ✅ **定案：pinmap 那句是错的**。实测 HDMI 走 SoC 内部
   `2b000000.hdmiphy`（`rockchip-hdptx-phy-hdmi`）+ `27da0000.hdmi`（dw-hdmi），
   **载板上没有独立 HDMI PHY IC**；触摸/背光在 `i2c-0`（gt911@0x14 / waveshare-bl@0x45），
   与 HDMI 无关。详见 `display/SKILL.md`。

## 相关文件

- 板级 DTS：`kernel/arch/arm64/boot/dts/rockchip/rk3576-quectel-pi-m2-linux.dts` + `.dtsi`
- 公共 DTS：`rk3576-quectel-pi-common.dtsi`、`rk3576-quectel-pi-m2-audio.dtsi`
- 显示 DTS：`display/dsi-panel-waveshare-auto-m2.dtsi`（8 寸 C + 4.3 寸 A 两个 profile）、
  `display/rk3576-hdmi-m2.dtsi`
- 40Pin 复用 overlay：内核内建 `rk3576-quectel-pi-m2-{i2c3,i2c7,spi1,uart1}-disable.dts` 与
  `-can0-enable.dts`（`kernel/arch/arm64/boot/dts/rockchip/`）；SDK 自有
  `overlay/rk3576-quectel-pi-m2-pwm2-disable.dts`。由 `tools/build-kernel.sh kernel|overlays` 编成 dtbo，
  打包写入 rootfs `/boot/overlays/`
- 内核配置片段：`kernel/arch/arm64/configs/quectel-{container,exfat,mhi-wwan,joystick,m2-overlay,overlays,pwm-fan}.config`；
  生效清单在 `tools/build-kernel.sh` 的 `KERNEL_FRAGMENTS`（本仓库没有 defconfig，片段清单只在这份脚本）
- 板级工具：`qpi-config`（40Pin/USB0/wi-fi/状态 dump）、`qpi-test`（camera/display/audio 自测）
- 应用/AT（板上）：`/usr/bin/port_bridge`（AT 通道 + FCT）、`/usr/bin/usbdevice`、
  `/usr/bin/disk-helper`、`/usr/bin/bt-tty`、`/usr/bin/quectel-CM`
