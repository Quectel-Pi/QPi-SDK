---
name: rtc-keys
description: "Quectel PI M2 RTC 与按键：AIP8563MA8（= PCF8563 @I2C2 0x51，/dev/rtc0、跨重启保持）硬件与 DTS、PON/PWRKEY/VOL_UP/BOARD_ID 按键与 SARADC 测键、板型识别。当用户说「M2 时间不对」「RTC 不起」「按键不响应」「VOL+ 报两个事件」「板型 ID 怎么读」时使用。WHEN: M2 RTC, AIP8563, PCF8563, /dev/rtc0, PON, PWRKEY, VOL_UP, board id, SARADC key, 实时时钟, 按键. DO NOT USE FOR: 电源域/休眠（用 power-pm），LED（用 led）。"
license: MIT
metadata:
  author: Quectel PI M2 外设 SKILL 库
  version: "1.0.0"
  board: Quectel PI M2 (RK3576 / QSM610ZAP-WF)
---

# M2 RTC / 按键 SKILL — AIP8563 实时时钟 + PON/PWRKEY/VOL_UP + ADC

适用：Quectel PI M2（`quectel,pi-m2-rk3576`）。

## 0. 上板实测（2026-10-10，Debian 13.7 / 内核 `6.1.118-rt36`）

**RTC 功能实测通过**，§1 以下的设计内容与板上一致：

| 项 | 实测结果 |
|---|---|
| 器件/驱动 | `rtc-pcf8563 2-0051: registered as rtc0`；`/sys/class/rtc/rtc0/name` = `rtc-pcf8563 2-0051` |
| I2C2 扫描 | `i2cdetect -y 2` → **`0x10 UU`(es8389 codec) + `0x51 UU`(RTC)** —— 与 §3 的期望一致 |
| 节点 | `/dev/rtc0`（另有 `/dev/rtc` 软链）、`/sys/class/rtc/rtc0/{name,date,time,since_epoch}` 均正常 |
| 读写 | `hwclock -r` / `hwclock -w` 正常；`since_epoch` 在 35 s 内 +35（**晶振在走时**） |
| **UTC 语义** | `timedatectl`：`RTC time` 显示的是 **UTC**（07:0x，比 CST 少 8 h）、`RTC in local TZ: no` → **与"RTC 必须按 UTC 写"一致** |
| **跨重启保持** | 写入后重启，开机日志：`rtc-pcf8563 2-0051: setting system clock to 2026-10-10T07:02:59 UTC (1791615779)` → **系统时间由 RTC 恢复**（`CONFIG_RTC_HCTOSYS=y`、`RTC_HCTOSYS_DEVICE="rtc0"`） |
| wakealarm | `echo <epoch> > /sys/class/rtc/rtc0/wakealarm` 后读回非空 → **可设**（`CONFIG_RTC_DRV_PCF8563=y`、`CONFIG_RTC_INTF_SYSFS=y`） |
| hwclock 包装 | `/usr/local/sbin/hwclock` **确实存在**，内容是 `#!/bin/sh` + `exec busybox hwclock "$@"` —— ⚠️ 是 **busybox 版**（非 util-linux），`-u` 之类选项的语义可能与常见文档不同，别照抄 util-linux 的用法 |

> ℹ️ `RTC_IRQ_N_1V8`（模组 pin154 = `GPIO0_A5`）在 `/sys/kernel/debug/gpio` 里**未被驱动 claim** ——
> 它是"深睡 + RTC 定时唤醒"的**硬件唤醒路径**（见 §5），与 `rtc0` 自己的 alarm 不是一回事。
> 要验证它得走 `power-pm` 的 PMIC/GPIO 唤醒配置。

## 1. RTC 硬件事实

| 项 | 值 |
|---|---|
| 器件 | **AIP8563MA8**（U1301，I-CORE，8-MSOP）—— **PCF8563 兼容** |
| I2C | **I2C2**（`i2c@2ac50000` = `/dev/i2c-2`），7bit 地址 **0x51**（pinmap 明确写 `RTC address : 0x51(7bit)`） |
| 总线共享 | I2C2 同时挂 **ES8389 Codec @0x10**（见 `audio/SKILL.md`）与 `gc08a3@0x31`、`pericom_30216c@0x1d` |
| 晶振 | X1301 32.768kHz（±20ppm） |
| 备份电池 | `RTC_BAT_P` ← **J1301**（2Pin），经 D1301/D1303 与 `RTC_VDD` |
| 中断 | `RTC_IRQ_N_1V8`（模组 pin154 = **`GPIO0_A5`**），默认上拉 1V8，低=中断有效 |
| 中断用途 | pinmap 举例：**模组深度休眠 + RTC 定时唤醒** |

> ⚠️ **型号**：早期硬件文档写 M2 用 `RX8130`，是错的。BOM 位号 U1301 =
> `AIP8563MA8`，M2 DTS 也用 `nxp,pcf8563 @0x51`（见 `rk3576-quectel-pi-m2-linux.dtsi`）。
> `rx8130@0x32` 是公共 dtsi 里的默认 RTC，M2 特意 `/delete-node/ rtc@32` 换掉。
>
> 另外注意：`GPIO0_A5` 被 M2 复用为 RTC 中断（common dtsi 里因 SATA/PCIE0 MUX 曾把它的 interrupt 与
> pinctrl 关掉），改这一脚前先确认没和 SATA/PCIe MUX 打架。

## 2. DTS 实现

`rk3576-quectel-pi-common.dtsi`（公共基线）：

```dts
&i2c2 {
    rtc@32 { compatible = "epson,rx8130"; reg = <0x32>; };
};
&pinctrl { rx8130_gpio { rx8130_gpio: rx8130_gpio {
    rockchip,pins = <0 RK_PA5 RK_FUNC_GPIO &pcfg_pull_up>; }; }; }
```

`rk3576-quectel-pi-m2-linux.dtsi`（M2 覆盖）：

```dts
&i2c2 {
    /delete-node/ rtc@32;
    rtc@51 { compatible = "nxp,pcf8563"; reg = <0x51>; };
};
```

## 3. 使用

```bash
i2cdetect -y 2                  # 实测期望：0x10(es8389) + 0x51(RTC) 都显示 UU
hwclock -r ; hwclock -w
timedatectl                     # RTC 与系统时间一致性（RTC 行显示 UTC）
cat /sys/class/rtc/rtc0/time ; cat /sys/class/rtc/rtc0/since_epoch
dmesg | grep -iE "rtc|pcf8563"
# 定时唤醒（深睡 + RTC alarm）
echo +60 > /sys/class/rtc/rtc0/wakealarm   # 60s 后唤醒（实测可设，读回为绝对 epoch）
cat /sys/class/rtc/rtc0/wakealarm
echo 0 > /sys/class/rtc/rtc0/wakealarm     # 清除
```

### 应用层

- 板上有 `/usr/local/sbin/hwclock`（**busybox 包装**：`exec busybox hwclock "$@"`）。
- **时区陷阱**：RTC 必须按 **UTC** 写；写成当地时间会让开机后系统时间多 8 小时。

## 4. 按键 / ADC（**待核实项① 已定案，2026-10-10**）

### 4.1 硬件（网表核对）

| 位号 | 类型 | 网络 | 连到模组 | 说明 |
|---|---|---|---|---|
| **S0402** | 拨动开关 | `PON_1` | pin 7 | 模组 **PON**（开机） |
| **S0403** | 轻触开关 | 经 R0404(1K) → `PWRKEY` | pin 8 | **PWRKEY** |
| **S0401** | 轻触开关 | `VOL_UP` | pin 10 | VOL+ |
| —（无实体按键） | — | `VOL_DOWN` | pin 11 | 只引出测试点 TP0406 |
| — | — | `MASKROM` | pin 9 | 测试点（进 Maskrom 用） |
| — | — | `RESET_N` | pin 12 | 测试点 |

引脚名 `ADC4/ADC7/ADC6/ADC3`（模组 pin 18/42/43/298）是 **SARADC 通道**：

| 模组 pin | SARADC 通道 | 网络 | 实测 raw / 电压（2026-10-10） | 结论 |
|---|---|---|---|---|
| **18** | **ADC4（`&saradc 4`）** | `BOARD_ID` | **2021 / 888 mV** | **就是 BOARD_ID 分压**（pinmap 理论 `47K‖10K = 0.877V`，实测对上 ✅） |
| **10** | **ch1（`adc_keys_ch1`）** | `VOL_UP` | **4094 / 1799 mV（满量程）** | **是按键通道**（未按时上拉到 1.8V） |
| 42 / 43 / 298 | ADC7 / ADC6 / ADC3 | 同名 | 3398/3350（浮空抖动） | 仅测试点 |
| — | ch0 / ch2 / ch3 | — | 4089 / 3723 / 3719 | 其他 ADC |

（`iio:device0` = `2ae00000.adc`，`scale=0.439453125` mV/LSB，vref 1.8V，12bit。
`BOARD_ID` 分压预留 2 位不贴，pinmap 给的三档：`0.877V / 0.481V / 0.331V`。）

### 4.2 ★ 定案：DTS 注释是错的，且 `delete-node` 失效

**M2 DTS 注释**（`rk3576-quectel-pi-m2-linux.dtsi:475-489`）声称：BOOTKEY 复用 SARADC1（芯片 Pin18/ADC4）、
与 VOL_UP 共用引脚，公共 dtsi 已把该通道 disabled、M2 需要重新 enable 并配为 KEY_POWER。
**这段注释是错的**（见下）。

配上这段实现：
```dts
&adc_keys_ch1 {
    status = "okay";
    /delete-node/ v_up_key;          /* ← 这句是空操作！见下 */
    boot-key { label = "bootkey"; linux,code = <KEY_POWER>; press-threshold-microvolt = <45000>; };
};
&adc_keys_ch5 { status = "disabled"; }
```

**实测推翻了两点**：

1. **BOOTKEY 不在 pin18/ADC4 上**。ADC4 实测 888mV = `BOARD_ID` 分压（纯电阻，**没有按键**），
   `&saradc 1`（ch1）才是按键线（VOL_UP，pin10）。所以"BOOTKEY 复用 SARADC1 = Pin18/ADC4"是**错的**。
2. **`/delete-node/ v_up_key;` 没生效**。节点在 common dtsi 里写作 `v_up_key:v-up-key{ ... }`
   —— **label 是 `v_up_key`（下划线），节点名是 `v-up-key`（连字符）**；
   DTS 的 `/delete-node/` 认**节点名**，所以这句删不到任何东西。
   板上 DT 实测：`adc-keys-ch1` 下 **`boot-key` 与 `v-up-key` 同时存在**、`status=okay`。

**后果（要修）**：`boot-key`(KEY_POWER) 和残留的 `v-up-key`(KEY_VOLUMEUP) 挂在**同一通道同一阈值(45000µV)**上
→ **按一次 VOL+ 会同时报出 `KEY_VOLUMEUP` 和 `KEY_POWER`**，后者会被 GNOME 电源管理接管
（GNOME 电源管理接管 KEY_POWER 后更容易误触发）。

**正确改法**（二选一，改完 `read_file` 定位 → `patch` 精确改）：
- 想把 VOL_UP 当**电源键**用：把删除写成节点名 `/delete-node/ v-up-key;`
  （或直接改 common dtsi 里的节点名，但那是多板共用的公共文件，慎动）；
- 想保留 `volume_up` 语义：**删掉 `boot-key`**，别让 KEY_POWER 挂在按键线上。

验证：
```bash
evtest /dev/input/event4        # adc-keys-ch1；按 VOL+ 看报的是哪个 code（应只有 KEY_VOLUMEUP）
for f in /sys/bus/iio/devices/iio:device0/in_voltage*_raw; do echo -n "$f="; cat $f; done   # 按下时 ch1 会掉下来
```

### 4.3 电源键行为

- 电源键行为由 GNOME 电源设置控制；不要再往 `input-event-daemon` / `triggerhappy` 里加 KEY_POWER 处理。
- 休眠/关机 AT：`AT+SLEEP`、`AT+POWEROFF`（见 `debug-fct/SKILL.md`）。
- Direct suspend 脚本：板上 `/usr/local/sbin/direct-suspend.sh`（`echo mem > /sys/power/state`，
  绕过 systemd-sleep hooks）。

### 4.4 板上 input 设备（实测）

```
input0 rk805 pwrkey            input3 bt-powerkey
input1 headset-keys            input4 adc-keys-ch1     ← 上面那条
input2 rockchip-es8389 Headset input5 rockchip-hdmi
```

## 5. 扩展场景

- **RTC 定时唤醒 + 深睡**：`/sys/class/rtc/rtc0/wakealarm` + `RTC_IRQ_N(GPIO0_A5)` 作唤醒源；
  深度休眠配置见 `power-pm/SKILL.md`（`RKPM_SLP_ARMOFF_LOGOFF` / `RKPM_SLP_PMU_PMUALIVE_32K` / `RKPM_SLP_32K_EXT`）。
- **板型识别**：`BOARD_ID`（**ADC4 / pin18**，实测 888mV）本来就是给"不同 10K 电阻对应不同软件版本配置"用的，
  当前代码里没有读取者（grep 无结果）。要做一板一配置时，在 U-Boot 或 early init 读 `&saradc 4` 再选 dtb/config。
- **外接按键面板**：40Pin 上 `HS_DET(GPIO2_B7)`、`CAN0`、`I2C3/I2C7`、`UART8` 都能做输入，见 40Pin 分册。

## 6. 已知坑

1. **RTC 型号别抄错**：M2 = `AIP8563MA8`（PCF8563 兼容 @0x51），不是 `RX8130`。
2. **`/delete-node/` 认节点名不认 label**：`v_up_key`(label) vs `v-up-key`(节点名) 这种坑很难看出来，
   改完**必须上板 `ls /proc/device-tree/<node>/` 核对**，不能只看 dtsi 写得对。
3. **BOOTKEY/BOARD_ID 别搞混**：ADC4 = BOARD_ID（分压，无键）；按键在 `&saradc 1`。
4. **hwclock 是 busybox 版**（`/usr/local/sbin/hwclock` → `busybox hwclock`），
   `-u`/`--utc` 等选项语义与 util-linux 不同；RTC 本身按 **UTC** 存（`LocalRTC=no`）。
5. **RTC 中断脚 `GPIO0_A5` 复用冲突**：common dtsi 注释里提到它曾被 SATA/PCIE0 MUX 占用。
6. **时间多 8 小时** = RTC 按本地时间写了，改回 UTC。
7. **I2C2 上 Codec 与 RTC 互相影响**：一根总线（ES8389/gc08a3/pericom/rtc），
   其中一个 probe 卡住会拖慢/阻塞整条总线；调试时先 `i2cdetect -y 2`。
8. 不要用 `sed` 改 dtsi 里的 `/delete-node/`、`/delete-property/` 结构。
