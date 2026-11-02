---
name: 40pin
description: "Quectel PI M2 40Pin 扩展口（J1501，RPi 兼容 2×20）：完整引脚表、功能复用法（qpi-config {i2c3,i2c7,spi1,uart1} enable/disable + 重启由 U-Boot 应用 dtbo；pwm2 直接走 sysfs）、第二路以太网/CAN/I2S/SPI 扩展场景与互斥关系。当用户说「M2 40Pin 怎么用」「引脚复用」「开 I2C3/SPI1/UART1/PWM2」「扩展 CAN」「40P 第二路网口」时使用。WHEN: M2 40pin, J1501, pin mux, qpi-config, i2c3 i2c7 spi1 uart1 pwm2, CAN0, RGMII1, SAI4, 扩展口, 引脚表. DO NOT USE FOR: 设备树 overlay 的编译与打包（用 sdk-overlays），普通 GPIO 操作（用 peripherals-overview 的 GPIO 表）。"
license: MIT
metadata:
  author: Quectel PI M2 外设 SKILL 库
  version: "1.0.0"
  board: Quectel PI M2 (RK3576 / QSM610ZAP-WF)
---

# M2 40Pin 扩展口 SKILL — 引脚复用、qpi-config、第二路以太网/CAN/I2S

适用：Quectel PI M2（`quectel,pi-m2-rk3576`）。40Pin 排针 **J1501**（2×20，RPi 兼容布局）。

## 1. 核心机制：M2 的 40Pin 是"功能复用开关"，不是 GPIO MUX

M2 没有 `qpi-config mux <pin> <mode>` 这种按引脚切 GPIO 別名的做法（那是另一块板的方式）。
M2 的做法是：**40Pin 上一批引脚在 SoC 内部本来就复用了两种功能**
（`RGMII1_*` ↔ `SPI1/I2C/UART/PWM`），通过 **编译好的 dtbo + 标记文件 + 重启** 二选一。

```bash
# M2 用法（写入 /etc/qpi-config/<feature>.disabled 标记，重启后由 U-Boot 应用 dtbo）
qpi-config {i2c3|i2c7|spi1|uart1} {enable|disable}
```

> ⚠️ **只有这四个**。本板实测 `qpi-config pwm2 enable` 返回
> `Error: 未知命令 'pwm2'。M2 支持: i2c3/i2c7/spi1/uart1, usb0, wifi, dump, serial_login, switch`。
> 40Pin 的 PWM2_CH3 没有开关，直接走 `/sys/class/pwm`（见 §2/§3）。

对应 overlay 源文件与编译入口（本仓库实际布局）：

| feature | 源文件 | 编译入口 |
|---|---|---|
| i2c3 / i2c7 / spi1 / uart1 | `kernel/arch/arm64/boot/dts/rockchip/rk3576-quectel-pi-m2-<feature>-disable.dts` | 内核内建（该目录 `Makefile` 的 `dtb-+=` 列表），`./tools/build-kernel.sh kernel` |
| can0 | `kernel/arch/arm64/boot/dts/rockchip/rk3576-quectel-pi-m2-can0-enable.dts`（默认不启用，见 §3） | 同上 |
| pwm2 | `overlay/rk3576-quectel-pi-m2-pwm2-disable.dts`（SDK 自有副本，上游已把该文件改名为 can0-enable） | `./tools/build-kernel.sh overlays` |

编好的 dtbo 由 `build-kernel.sh` 的 `build_overlays` 收集，本 SDK 产出并打包进 rootfs `/boot/overlays/`
**6 个**：`pwm2-disable`（来自 `overlay/*.dts`）+ `i2c3/i2c7/spi1/uart1/can0-enable`（来自内核
`Makefile` 声明的 M2 条目；同文件里的 2 个 `smarc-*` 不会被打包）。
板上实测在 `/usr/share/qpi-config/overlays/`，同样是 6 个但组成不同：
`i2c3/i2c7/spi1/uart1/can0-enable/usb0-host`（**没有** `pwm2-disable`）。
用前先 `find / -name 'rk3576-quectel-pi-m2-*.dtbo'` 定位。
`qpi-config` 只写标记文件，U-Boot 启动时按标记应用。

> **为什么 LCD 需要重启**：同一批引脚被两个 controller 申请，只能靠设备树在启动时决定归属，
> 运行期抢不过来。

## 2. 40Pin 引脚表（只列 40Pin 上真正引出的信号，来自 pinmap `40PINS` sheet + 网表）

| 排针 | 模组 pin | 网络名 | 默认功能 | 可复用 |
|---|---|---|---|---|
| 1 / 17 | — | `40PIN_3V3` | 3.3V（受 `GPIO0_C7`/40PIN_3V3_EN 控制，M2 DTS 里 gpio-hog 常开） | — |
| 2 / 4 | — | `VDD_5V0_SYS` | 5V | — |
| 3 / 5 | 310 / 309 | `I2C3_SDA_M0_3V3` / `I2C3_SCL_M0_3V3` | **I2C3** | `qpi-config i2c3` |
| 7 | 215 | `GPIO2_B7`（HS_DET） | GPIO | — |
| 8 / 10 | 297 / 296 | `UART1_TXD_M1_3V3` / `UART1_RXD_M1_3V3` | **UART1** | `qpi-config uart1` |
| 11 / 12 | 214 / 291 | `GPIO2_B6` / `RGMII1_TX1`(GPIO2_C7) | GPIO | 12 可作 ETH1 TX1 |
| 13 / 15 | 217 / 216 | `UART8_TXD` / `UART8_RXD` | **UART8**（默认 GPIO） | 需自行 enable `&uart8` |
| 16 / 18 | 15 / 16 | `CAN0_TX_M2_3V3` / `CAN0_RX_M2_3V3` | **CAN0** | ⚠️ M2 DTS 里 `&can0 = disabled`，见下 |
| 19 / 21 / 23 | 288 / 211 / 213 | `SPI1_MOSI_M1` / `SPI1_MISO_M1` / `SPI1_CLK_M1` | **SPI1** | `qpi-config spi1` |
| 24 / 26 | 212 / 289 | `SPI1_CSN0_M1` / `SPI1_CSN1_M1` | SPI1 CS | 同上（DTS 里有 `spidev@1`） |
| 27 / 28 | 219 / 220 | `I2C7_SDA_M1_3V3` / `I2C7_SCL_M1_3V3` | **I2C7** | `qpi-config i2c7` |
| 29 / 31 | 363 / 364 | `RGMII1_MDIO_3V3` / `RGMII1_MDC_3V3` | GPIO（RPi GPIO5/6） | **PCIe 5G HAT 的 PWKEY/RESET**（`GPIO2_D5`/`GPIO2_D4`） |
| 32 | 350 | `CAM1_RST_3V3` | GPIO（`GPIO2_B5`） | — |
| 33 | 210 | `PWM2_CH3_M2_3V3` | **PWM2_CH3** | 无开关，直接 `/sys/class/pwm`（`2ade3000.pwm`） |
| 35 / 36 / 37 / 38 / 40 | 292 / 209 / 357 / 293 / 290 | `SAI4_TX0 / SAI4_MCLK / RGMII1_MCLK / SAI4_RX / SAI4_TXCTL` | **I2S（SAI4）** 或 RGMII1 信号 | 见下 |
| 22 | 295 | `RGMII1_RST_N_3V3` | GPIO（`GPIO2_B4`） | ETH1 复位 |
| 34 / 39 / 6/9/14/20/25/30 | — | GND | — | — |

> ⚠️ **SAI4 与 RGMII1 在这几个 pin 上互斥**（`SAI4_*` 用的是 `RGMII1_TX0/TXCTL/TXD…` 的等效脚）。
> pinmap 原文标注这些脚"可做 I2S 用"。要用 40Pin 做第二路以太网 **或** I2S 音频，先决定谁是主用途。

## 3. 使用示例

```bash
# ① 用 40Pin 上的 I2C3 / SPI1 / UART1
qpi-config i2c3 enable ; qpi-config spi1 enable ; qpi-config uart1 enable
reboot
# 重启后
i2cdetect -y 3
ls /dev/spidev*            # spi1 → spidev1.0 / spidev1.1
ls /dev/ttyS1

# ①' 40Pin PWM（pin33 = PWM2_CH3）没有开关、不需重启，直接走 sysfs：
#   先按 device 名反查 chip 号（编号随启动变，别按 0/1/2/3 猜）：
for c in /sys/class/pwm/pwmchip*; do echo "$c -> $(readlink -f $c)"; done
#   本板实测：pwmchip3 -> …/2ade3000.pwm（pin33）；pwmchip2 -> …/2add5000.pwm（pin35）
echo 0 > /sys/class/pwm/pwmchip3/export      # 然后写 period → polarity → duty_cycle → enable

# ② 用 40Pin 做第二路以太网（RGMII1）
qpi-config spi1 disable ; reboot      # 必须先让出 SPI1 的脚

# ③ 用 40Pin 外接 PCIe 5G HAT
#    29/31 脚 = PWKEY/RESET，见 pcie/SKILL.md（与 RGMII1 MDIO/MDC 冲突）
```

DTS 里 40Pin 相关现状（`rk3576-quectel-pi-m2-linux.dtsi`）：

```dts
&can0        { status = "disabled"; };                  /* ⚠️ 40Pin 引出了 CAN0，但 DTS 关着 */
&i2c3        { status = "okay"; };
&pwm2_8ch_3  { pinctrl-0 = <&pwm2m2_ch3>; status = "okay"; };
&spi1 { pinctrl-0 = <&spi1m1_csn0 &spi1m1_csn1 &spi1m1_pins>; status = "okay";
        spidev@1 { compatible = "rockchip,spidev"; reg = <1>; spi-max-frequency = <12000000>; }; };
&uart1       { pinctrl-0 = <&uart1m1_xfer>; status = "okay"; };
&gpio0 { header_3v3_enable_hog: header-3v3-enable-hog {
            gpio-hog; gpios = <RK_PC7 GPIO_ACTIVE_HIGH>; output-high;
            line-name = "40pin-3v3-enable"; }; };
```

### CAN0：运行期动态 overlay（本仓库已有内建 dtbo）

40Pin pin16 = `CAN0_TX_M2`、pin18 = `CAN0_RX_M2`，用 `can0m2_pins`。基础 DTS 保持
`&can0 { status = "disabled"; }`（common 里是 okay，M2 关掉）。**不用改 dtsi、不用重启**：
本仓库 `quectel-m2-overlay.config` 打开了 `CONFIG_OF_CONFIGFS`，内核内建
`rk3576-quectel-pi-m2-can0-enable.dtbo`，运行期挂到 configfs 即可。

```bash
# dtbo 位置两处都可能：本 SDK 打包在 /boot/overlays/，板上在 /usr/share/qpi-config/overlays/
find / -name 'rk3576-quectel-pi-m2-can0-enable.dtbo' 2>/dev/null
mkdir -p /sys/kernel/config/device-tree/overlays/m2-can0
cat /usr/share/qpi-config/overlays/rk3576-quectel-pi-m2-can0-enable.dtbo \
    > /sys/kernel/config/device-tree/overlays/m2-can0/dtbo
ip -details link show can0
ip link set can0 type can bitrate 500000 dbitrate 1000000 fd on   # 按对端参数
ip link set can0 up
# 卸载：接口先 down，再写 remove=1，最后删目录
ip link set can0 down
echo 1 > /sys/kernel/config/device-tree/overlays/m2-can0/remove
rmdir /sys/kernel/config/device-tree/overlays/m2-can0
```

注意：
- `qpi-config` **没有** can0 子命令（本板实测只认 i2c3/i2c7/spi1/uart1）。
- 驱动默认开 CAN FD，起接口前要同时给 `dbitrate`，否则 `ip link set up` 报参数错。
- 内部回环要在驱动里同时开 `MODE_LBACK | MODE_RXSTX`，只开 `MODE_LBACK` 会 TX 增、RX 为 0；
  回环不验证外部引脚。外部总线要配电平匹配的 CAN 收发器，TX/RX 不能直接接 CANH/CANL。

## 4. 扩展场景

- **RPi HAT 兼容性**：`40PINS引脚对应分布` sheet 有完整的"树莓派功能名称 ↔ SH603 Pin ↔ AF0..AF10"对照表，
  挂 HAT 前先查这张表确认每个脚的真实复用能力（不是所有脚都能当 GPIO）。
- **CAN 总线**：内核 `quectel-m2-overlay.config` 里已含 `CONFIG_CAN=y`、`CONFIG_CANFD_RK3576=y`。
- **I2S 音频扩展**：40Pin 上的 SAI4 可以做第二路 I2S 输出（`&sai4`）。
- **UART 扩展**：`UART1`(pin8/10) 与 `UART8`(pin13/15) 都在排针上；UART8 默认没在 DTS 里 enable。
- **PWM 调光/电机**：`PWM2_CH3`(pin33)。
- **GPIO 中断唤醒**：pinmap 标注 40Pin 大部分脚 **支持 WakeUp**（表里 `WakeUP` 列为 √）。

## 5. 已知坑

1. **`qpi-config` 的 40Pin 开关都要重启**（标记文件 + U-Boot 应用 dtbo），当场验证看不到效果。
2. **SPI1 与第二路以太网互斥**；`spidev@1` 与 `spidev@0` 在 common dtsi 里各自声明过一次
   （common 里 `spidev@0`，M2 里 `spidev@1`），改之前 grep 全部。
3. **首次用 40Pin-3V3 前必须确保 `GPIO4_A7`(DCDC_EN_3V3) 与 `GPIO0_C7`(40PIN_3V3_EN) 都为高**；
   M2 DTS 已经把 40PIN_3V3_EN hog 成常开，但 DCDC_EN_3V3 是整版 3V3，别被别的功能关掉。
4. **不要用 `sed` 改 overlay dts**；这些文件很短，直接 `patch` 精确改。
5. **`qpi-config` 子命令按板型不同**：M2 只有 `i2c3/i2c7/spi1/uart1`（40Pin）与 `usb0/wifi/dump/serial_login/switch`，没有 `mux`；别把另一块板的子命令套过来。
