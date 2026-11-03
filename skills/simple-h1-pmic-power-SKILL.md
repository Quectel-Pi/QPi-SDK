---
name: simple-h1-pmic-power
description: "simple-h1 SDK: PM7250B/PM7325/PM8350C/PMK8350 供电轨、按键/LED/RTC/ADC、BCL 与休眠"
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [qualcomm, qcs6490, quectel, simple-h1, pmic, regulator, rtc, bcl, power]
    related_skills: [simple-h1-build, simple-h1-fan-thermal, simple-h1-gpio-40pin, simple-h1-storage]
---

# simple-h1 电源 / PMIC

设备树: `kernel/arch/arm64/boot/dts/qcom/qcs6490-idp-pi.dts`（行号以该文件为准）。
硬件出处: 原理图 p13 / p21 / p22。

## 1. PMIC 组成与职责

| PMIC | SPMI 地址 | 职责（DTS 证据） |
|---|---|---|
| **PM7250B** | **SID8 / SID9**（`#define PM7250B_SID 8`，DTS:9-10） | 充电/USB、**BCL 电池电流限制**（`bcl@1d00`，DTS:2098）、振动马达 |
| **PM7325** | `qcom,pmic-id = "b"`（DTS:360） | **主 SMPS/LDO**（S1B~S8B、L1B~L19B）+ **VADC（ADC0-2 给 40Pin）** + temp alarm |
| **PM8350C** | `qcom,pmic-id = "c"`（DTS:512） | SMPS/LDO（S1C~S10C、L1C~L13C）+ **BOB 3.296 V**（MIC BIAS）+ **三色 LED / 风扇 PWM3** |
| **PMK8350** | SID 0（`pmk8350.dtsi:13`） | **PON（PWRKEY/RESIN）**、**RTC**、`adc_tm` 热管理、VADC |

外部电源器件（p13/p21）：`ETA1656D2G`、`ETA1753FSG`（升压/充电）。

## 2. 关键供电轨（改外设先看这张表）

| 轨 | DTS 行 | 电压 | 用途 |
|---|---|---|---|
| `vreg_l6b_1p2` | 418 | 1.14–1.26 V | DSI、UFS PHY、PCIe0/1 PHY、USB3 QMP vdda-phy |
| `vreg_l7b_2p952` | 425 | 2.96 V（固定） | **UFS VCC**（allow-set-load） |
| `vreg_l9b_1p2` | 439 | 1.08–1.304 V | **UFS VCCQ/VCCQ2**（allow-set-load） |
| `vreg_l10c_0p88` | 611 | 0.88–1.05 V | DSI PHY、UFS PHY、PCIe0/1 PHY、USB vdda-phy |
| `vreg_l17b_1p7` | 488 | 1.7 V | **WCD9370 vdd-buck**、LT9611 1V2 的源（DTS:1150） |
| `vreg_l18b_1p8` | 495 | 1.8–2.0 V | WCD9370 rxtx/px、传感器、DSI `vddio_i2c` |
| `vreg_l1c_1p8` | 548 | 1.8 V | USB HS PHY vdda18 |
| `vreg_l2b_3p072` | 393 | 3.072 V | USB HS PHY vdda33 |
| `vreg_l9c_2p96` / `l6c_2p96` | 604 / 583 | 2.96 V / 1.8–2.95 V | **SD 卡 vmmc / vqmmc** |
| `vreg_bob_3p296` | 639 | 3.008–3.96 V | **WCD9370 vdd-mic-bias**（MICBIAS） |

外设专属 regulator（`regulator-fixed`，不是 PMIC 内部轨）：

| 名字 | 控制脚 | DTS 行 | 用途 |
|---|---|---|---|
| `wifi_3v3_vreg` / `wifi_1v8_vreg` | `tlmm 132` / `tlmm 130` | 1382 / 1391 | Wi-Fi SDIO 供电 |
| `lt9611_1v2_vreg` / `lt9611_3v3_vreg` | `tlmm 121` / `tlmm 46` | 1143 / 1153 | LT9611 HDMI 桥 |
| `pcie1_pwr_en_vreg` | `tlmm 24` | 1133 | PCIe1 / M.2 / 5G 3V3 |
| `rtl8111h_3v3_vreg` | `tlmm 116` | 1123 | **YT6801 以太网**（名字是历史遗留） |
| `pin40_en_vreg` | `tlmm 9`（`always-on`） | 1930 | 40Pin 1V8 电平域 |

设备侧查看：

```bash
for r in /sys/class/regulator/regulator.*; do
    printf "%-34s %-8s %s\n" "$(cat $r/name)" "$(cat $r/state)" "$(cat $r/microvolts 2>/dev/null)"
done
```

> **实测**（同板）：`vreg_l7b_2p952` / `vreg_l9b_1p2` 是 `enabled` 但**读不到 microvolts**（正是
> `/delete-property/` 掉 min/max 的结果，符合 §2 的说明）；`lt9611_3v3_vreg`/`rtl8111h_3v3_vreg`/
> `pcie1_pwr_en_vreg`/`wifi_3v3_vreg`/`wifi_1v8_vreg`/`pin40_en_vreg` 全部 `enabled`。
> LED：`red`/`green`/`blue` 存在，`green` 默认 `heartbeat`、其余 `none`；RTC 为 `rtc-pm8xxx`，读回 1970。

## 3. 按键 / LED / RTC / ADC / 热管理

### 按键

| 按键 | 实现 | 事件 |
|---|---|---|
| **PWRKEY** | PMK8350 `pon_pwrkey`（DTS:1113） | 开关机；长按行为由 PMIC 硬件决定 |
| **KEY2（RESIN）** | `pon_resin`（DTS:1117） | `KEY_VOLUMEDOWN` |
| **KEY1（VOL_UP）** | `gpio-keys`（DTS:327-343），`&pm7325_gpios 6` | `KEY_VOLUMEUP`，`wakeup-source` |
| **USB_BOOT** | 硬件 | 强制进下载模式 → EDL（见 `simple-h1-flash-SKILL.md`） |

- 枚举：`cat /proc/bus/input/devices | grep -A3 -iE "pwrkey|resin|gpio-keys"`；有 `evtest` 也可直接测。

### 三色 LED（PM8350C PWM，DTS:986-1008）

```bash
ls /sys/class/leds/                      # red / green / blue
cat /sys/class/leds/red/trigger
echo none > /sys/class/leds/red/trigger  # 先退出 trigger，亮度才可见
echo 200 > /sys/class/leds/red/brightness
echo heartbeat > /sys/class/leds/green/trigger
```
- `&pm8350c_pwm` 只登记 `led@1/2/3`（红/绿/蓝），**没有** `fanfan` 节点，风扇走 hwmon。
- **亮度只在 `trigger = none` 时有效**：trigger 非 none 时亮度由 trigger 接管，写进去读回仍是 0。

### RTC（PMK8350，不是外置 RTC 芯片）

```bash
cat /sys/class/rtc/rtc0/time ; cat /sys/class/rtc/rtc0/since_epoch
hwclock -r ; hwclock -w ; timedatectl
echo +60 > /sys/class/rtc/rtc0/wakealarm      # 定时唤醒（配合休眠）
```
> 上板记录：`/dev/rtc0`、`/dev/rtc` 都在，但读回 **1970-01-01**（板上无电池、未初始化），
> 系统墙钟同为 1970。判"电池没电"还是"晶振问题"：`hwclock -w` → 断电几分钟 → 上电复读。

### ADC / 温度

```bash
# 40Pin 三路 ADC（1.8 V 满量程，label 见 DTS:1087/1095/1103）
cat /sys/bus/iio/devices/iio:device*/in_voltage_pm7325_adc0_input
cat /sys/bus/iio/devices/iio:device*/in_voltage_pm7325_adc1_input
cat /sys/bus/iio/devices/iio:device*/in_voltage_pm7325_adc2_input
# 热区
for z in /sys/class/thermal/thermal_zone*; do echo "$(cat $z/type): $(cat $z/temp)"; done
```
- `&pmk8350_adc_tm`（DTS:1010-1031）把通道分给 `xo-therm@0`/`quiet-therm@1`/`sdm-skin@3`；
  VADC label 另有 `pm7325_quiet_therm`、`pm7325_die_temp`、`pmk8350_die_temp`。

### BCL（PM7250B，DTS:2098-2240）

| 热区 | 传感器 | trip | 联动 |
|---|---|---|---|
| `pm7250b-ibat-lvl0` | `bcl 0` | **6000 mA** | — |
| `pm7250b-ibat-lvl1` | `bcl 1` | **7500 mA** | — |
| `pm7250b-bcl-lvl0` | `bcl 5` | 1 | CPU4-7 idle、cdsp、modem_pa、modem_tj |
| `pm7250b-bcl-lvl1` | `bcl 6` | 1 | **msm_gpu**、cdsp、modem_tj |
| `pm7250b-bcl-lvl2` | `bcl 7` | 1 | cdsp |

> 本板 DTS:98 有 **`qcom,battery-absent`**（无电池）。电池节点是否存在**按镜像而定**：
> 实测 A（Debian/6.6.52）仍有 `/sys/class/power_supply/qcom-battmgr-bat`（type=Battery，capacity=100）；
> 实测 B（qcom-wayland/6.6.116）只有 `qcom-battmgr-usb`/`-wls`，没有 bat，与 DTS 一致。
> 所以**别用“有没有 battery 节点”判断电池**，看 DTS 与板上是否有电芯。
> BCL 的触发条件与带电池整机不同，调 CPU/GPU 功耗策略时仍要一起看这段。

## 4. 休眠 / 低功耗

```bash
echo mem > /sys/power/state
cat /sys/power/state ; cat /sys/power/wakeup_count
dmesg | grep -iE "PM:|suspend|resume"
```
- 唤醒源（标 `wakeup-source`）：`pon_pwrkey`、`pon_resin`、`&usb_1`(DTS:1694)、
  `&usb_2`(DTS:1795)、volume_up key(DTS:339)。
- **`&sdhc_1`（Wi-Fi SDIO）有 `keep-power-in-suspend`**（DTS:1415）：别让 Wi-Fi 断电否则唤醒失败。
- Type-C/充电链路：`pmic-glink`（DTS:91-98），`qcom,thermal-mitigation = <3000000 1500000 1000000 500000>`（µA）。

## 5. 已知坑

1. **`rtl8111h_3v3_vreg` 名字骗人**：它供的是 YT6801 以太网 3V3（`tlmm 116`）。
2. **UFS 的两个 regulator 被显式改成 `allow-set-load`**（DTS:1739-1751）：`/delete-property/`
   掉 min/max 是故意的，不要"补回"。
3. **`pin40_en_vreg` 是 `always-on`**：40Pin 电平域无法软件断电。
4. **按键分工容易混**：`pon_resin` = **VOLUMEDOWN**，`gpio-keys` 里那个才是 **VOLUMEUP**
   （且是 PM7325 GPIO6，不是 TLMM 的脚）。
5. **PWRKEY 长按行为由 PMIC 硬件决定**（关机/复位/进下载模式），只改 Linux input 层无效。
6. **BOB（`vreg_bob_3p296`）给 MICBIAS**：动 BOB 电压会影响麦克风偏置，音频异常先查这条轨。
7. **BCL 与 CPU/GPU 降频联动**：出现"跑一会儿就降频/复位"，先看 BCL trip 是否被触发，
   再看 `pm7250b-bcl-lvl1` 里对 `msm_gpu` 的限制。
8. **电源相关改动必须整机重启验证**：regulator 配置不支持热加载；改 DTS 后
   `./scripts/build-all.sh` → `./scripts/flash.sh`，别指望 `modprobe` 生效。
9. **无电池机型**：`qcom,battery-absent`，不要照"带电池整机"的充电行为排查供电问题。
