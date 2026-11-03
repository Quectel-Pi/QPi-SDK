---
name: simple-h1-gpio-40pin
description: "simple-h1 SDK: 40Pin 排针 / GPIO / I2C / SPI / UART / PWM / ADC 的引脚表、DTS 节点与设备侧操作"
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [qualcomm, qcs6490, quectel, simple-h1, gpio, 40pin, i2c, spi, uart, adc, pwm]
    related_skills: [simple-h1-build, simple-h1-fan-thermal, simple-h1-pmic-power]
---

# simple-h1 40Pin / GPIO / ADC

设备树: `kernel/arch/arm64/boot/dts/qcom/qcs6490-idp-pi.dts`（下文行号均以该文件为准）。
硬件出处: 原理图 p07（40Pin + 电平转换 UM3288FQB）。

## 1. 硬件事实

| 项 | 值 |
|---|---|
| 接口 | 标准 40-pin 排针（树莓派兼容），连接器 `J0801`（p07） |
| 电平转换 | **UM3288FQB**（p07），SoC 侧 1.8 V ↔ 排针侧 3.3 V；另有 `SGM6505YTQF24G` |
| 40Pin 1V8 域供电 | `pin40_en_vreg`（`tlmm 9`，`regulator-always-on`，1.8 V），DTS:1930-1940 |
| 能力（规格书） | 6×I2C、1×I2S、4×SPI、4×UART、3×PWM、28×GPIO、1×SDIO（均"与其他接口复用"） |
| SDIO 复用 | SD 卡座 ↔ 2×20 SDIO 由**板上开关二选一**（见 `simple-h1-storage-SKILL.md`） |
| 引脚对照 | pin3/pin5 = I2C0、pin27/pin28 = I2C1、pin8/10 = UART、pin19~26 = SPI、pin33=PWM、pin32=Tach |
| GPIO 字符设备 | **`/dev/gpiochip4`**（40Pin 相关 GPIO 基本都在这块 TLMM 上） |

### 1.1 40Pin 引脚表（权威）

| 引脚 | 名称 | 引脚 | 名称 | 引脚 | 名称 | 引脚 | 名称 |
|---|---|---|---|---|---|---|---|
| 1 | 3V3 | 2 | 5V | 3 | I2C0_SDA | 4 | 5V |
| 5 | I2C0_SCL | 6 | GND | 7 | GPIO_77 | 8 | UART_TXD |
| 9 | GND | 10 | UART_RXD | 11 | GPIO_16 | 12 | GPIO_101 |
| 13 | GPIO_17 | 14 | GND | 15 | GPIO_18 | 16 | GPIO_32 |
| 17 | 3V3 | 18 | GPIO_33 | 19 | SPI_MOSI | 20 | GND |
| 21 | SPI_MISO | 22 | GPIO_19 | 23 | SPI_CLK | 24 | SPI_CE0 |
| 25 | GND | 26 | SPI_CE1 | 27 | I2C1_SDA | 28 | I2C1_SCL |
| 29 | GPIO_49 | 30 | GND | 31 | GPIO_48 | 32 | GPIO_76 |
| 33 | GPIO_78 | 34 | GND | 35 | GPIO_103 | 36 | GPIO_34 |
| 37 | GPIO_35 | 38 | GPIO_104 | 39 | GND | 40 | GPIO_102 |

排针名 ↔ SoC 实例（板级 DTS 注释自证）：

| 排针名 | SoC 实例 | DTS 行 | 设备节点 |
|---|---|---|---|
| I2C0_SDA/SCL（pin3/5） | `i2c9` | 1947（`//PIN5_I2C_SCL`） | `/dev/i2c-9` |
| I2C1_SDA/SCL（pin27/28） | `i2c13` | 1952（`//PIN28_I2C1_SCL`） | `/dev/i2c-13` |
| SPI_*（pin19/21/23/24/26） | `spi10` | 1987 | `/dev/spidev10.0`、`spidev10.1` |
| UART_TXD/RXD（pin8/10） | `uart12` | 1973 | `/dev/ttyHS2`（alias `serial2`，DTS:41） |
| PWM（pin33）／Tach（pin32） | lgpio 软件 PWM | — | `GPIO_78` / `GPIO_76` |

> 排针上的 `I2C0/I2C1` 是**排针侧命名**，实际落到 SoC 的 `i2c9` / `i2c13`，别和 SoC 的 i2c0/i2c1 混淆。

## 2. DTS 默认使能状态（决定了 /dev 里有没有节点）

| 实例 | DTS 行 | 默认 status | 结果 |
|---|---|---|---|
| `i2c9` | 1947 | **okay**，100 kHz | `/dev/i2c-9` |
| `i2c13` | 1952 | **okay**；内部 `lsm6dso@6b` 为 **disabled** | `/dev/i2c-13`（IMU 不猜地址，见 §5） |
| `i2c3` | 1942 | **okay** | ⚠️ **DSI 屏/触摸专用**，别挂第三方器件 |
| `spi10` | 1987 | **okay**，`spidev@0`=`rohm,dh2228fv` 10 MHz；`spidev@1` CS1=`tlmm 80` | `/dev/spidev10.0`（实测板上只有这个；`spidev10.1` 需 CS1 生效后才会出现） |
| `uart12` | 1973 | **okay**（2 线，`qup_uart12_rx/tx` pinctrl 1977/1982） | `/dev/ttyHS2` |
| `uart4` | 1969 | **disabled**（`GPIO16/17/18/19` 四线） | 无节点 |
| 40Pin PWM | — | 无 DTS 节点，由 lgpio 软件 PWM 产生 | — |

> 本 SDK 的板级 DTS 已把 `i2c9`/`i2c13`/`spi10`/`uart12` 默认打开（`uart4` 关闭），
> **不需要**在设备上改配置文件再重启。上板只看 `/dev` 是否符合本表即可。

## 3. 设备侧核查

```bash
adb shell 'ls -l /dev/i2c-* /dev/spidev* /dev/ttyHS* 2>/dev/null'
adb shell 'dmesg | grep -iE "geni|i2c|spi|uart" | tail -20'
adb shell su -c 'cat /sys/kernel/debug/gpio'     # 需 root
```

- **`/sys/kernel/debug/gpio` 上板记录**：本板共 6 个 gpiochip —— `gpiochip0..3` 全是 PMIC
  （`c440000.spmi:pmic@8/@1/@2/@0`）；**`gpiochip4` = `platform/f100000.pinctrl`（TLMM 主控，176 线）**；
  `gpiochip5` = `33c0000.pinctrl`（15 线）。落到第二块的线在 `gpiochip5`，**两块行号不通用**。
- **实测**（同板）：共 6 个 chip（0-3 是 PMIC，4 = `f100000.pinctrl` **547-722 共 176 线**，5 = `33c0000.pinctrl` **723-737 共 15 线**）；
  `/dev/i2c-9`、`/dev/i2c-13`、`/dev/spidev10.0`、`/dev/ttyHS1`（蓝牙）、`/dev/ttyHS2`（40Pin UART）都在，
  ADC label `pm7325_adc0/1/2` 也都存在。**`/dev/spidev10.1` 按镜像/DT 而定**：实测 A 没有，
  实测 B（6.6.116 镜像）有 —— 以 `/sys/bus/spi/devices/` 为准，别按本文当常量。
- 改 DTS 后生效链路：改 `kernel/arch/arm64/boot/dts/qcom/qcs6490-idp-pi.dts`
  → `./scripts/build-all.sh`（dtb 进 `efi.bin`(UKI) 与 `dtb.bin`）→ `./scripts/flash.sh`。
  只改 overlay 不必编内核（`SKIP_KERNEL=1 ./scripts/build-all.sh`）。

## 4. 逐项使用

### GPIO

```bash
rgs -h                    # 子命令是**大写**：GO/GR/GSO/GW/GSF/GC/GIL
rgs c 1 GO 4              # 打开 /dev/gpiochip4，返回句柄（实测 0）
rgs c 1 GIL 0 36          # 查 line 36 信息（实测: 36 65536 "" ""）
rgs c 1 GR 0 36           # 读电平（实测返回 1）
rgs c 1 GSO 0 36          # claim 为输出
rgs c 1 GW 0 36 1         # 写高
rgs c 1 GSF 0 36 ; rgs c 1 GC 0   # 释放 + 关设备
```
```python
from periphery import GPIO   # pip3 install python-periphery --break-system-packages
GPIO("/dev/gpiochip4", 36, "out").write(True)    # pin3 = gpio36
print(GPIO("/dev/gpiochip4", 37, "in").read())   # pin5 = gpio37
```
- C/C++ 用 **lgpio**：`gcc x.c -llgpio`，`lgGpiochipOpen(4)`（**镜像里没有 liblgpio**，要先自己编/装）。
- 镜像**未装** libgpiod 工具包（`gpiodetect/gpioget/gpioset`）与 python `gpiod` 模块，
  别照 Linux 手册直接调。

### I2C / SPI / UART（`/dev/i2c-9`、`/dev/spidev10.*`、`/dev/ttyHS2`）

```bash
ls /dev/i2c-* /dev/spidev* /dev/ttyHS*
cat /sys/bus/i2c/devices/*/name     # 无 i2cdetect 时用它枚举器件（比 i2cdetect 直观）
# I2C 例：BME280 @0x76
# SPI 回环：短接 pin19(MOSI)/pin21(MISO)，10 MHz
# UART 回环：短接 pin8/pin10，115200
```
> 镜像未带 `i2c-tools`、`spidev_test`；要用得先解决 apt 源再装（`i2c-tools`），SPI 回环可用 python `spidev` 自写。

### PWM（pin33 = `GPIO_78`，Tach = pin32 = `GPIO_76`）

```bash
# 4pin 风扇：VCC→pin2/4(5V)，PWM→pin33，GND→GND，Tach→pin32
# C: lgGpiochipOpen(4) + lgTxPwm(h, 78, 1000, 50, 0, 0)   // 1 kHz / 50 %
gcc pwm.c -o pwm -llgpio && sudo ./pwm
```
> 板载风扇（PM8350C PWM3 + TACH）是另一套，见 `simple-h1-fan-thermal-SKILL.md`，不要混。

### ADC（3 路，**最大 1.8 V**）

```bash
cat /sys/bus/iio/devices/iio:device*/in_voltage_pm7325_adc0_input
cat /sys/bus/iio/devices/iio:device*/in_voltage_pm7325_adc1_input
cat /sys/bus/iio/devices/iio:device*/in_voltage_pm7325_adc2_input
# 实测 B: 没有 *_scale 文件, 直接读 raw (adc0/1/2 = 25432 / 21669 / 129)
# 换算：常见口径 raw 0..65535 ↔ 0..1.8 V，用万用表比对一次再套公式
```
- 通道 label 见 DTS:1087/1095/1103（`pm7325_adc0/1/2`，`ratiometric`，`pre-scaling <1 1>`）。

## 5. 已知坑

1. **`i2c3` 是 DSI 屏 + 触摸专用**，往上挂设备会和触摸冲突。
2. **`pin40_en_vreg` 是 `always-on`（tlmm9）**：40Pin 电平域无法软件断电，只能整机断电。
3. **ADC 上限 1.8 V**：超压打坏 PMIC 通道，输入必须分压。
4. **`uart4` 默认 disabled 且四线**：其注释里的 `GPIO16/17/18/19` 与 40Pin 的
   pin11/13/15/22 是同一批脚，启用前先确认没被别的功能占用。
5. **GPIO 编号是 chip 内 line 号**（`GPIO36/37/76/78`），不是全局编号；
   用 `gpiochip4` 打开时直接传 line 号，代码里别做全局换算。
6. **Level shift 不提供 5 V 容忍**：排针侧只有 3.3 V 逻辑，5 V 器件必须自己转换。
7. **`lsm6dso@6b` 默认 disabled，且节点名写作 `@6a`**（DTS:1956-1966）：要启用 IMU 时
   地址按 `reg = <0x6b>` 写，`interrupts-extended = <&tlmm 48 ...>`，pinctrl `lsm6dso_int_default`。
8. **I2S 已被占用**：Primary MI2S 给了 LT9611 HDMI 音频（`&msm_stub_codec`，DTS:2248），
   外接 I2S 设备前先确认可用实例。
