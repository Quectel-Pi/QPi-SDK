---
name: fan-thermal
description: "Quectel PI M2 风扇与热管理：PWM1_CH1 → MOS Q0401 → pwm-fan（hwmon6）硬件与 DTS 结构、hwmon 读写转速/占空比、thermal trip 调温策略、风扇不转排查。当用户说「M2 风扇不转」「调风扇转速」「温控策略」「hwmon 在哪」「过温降频」时使用。WHEN: M2 fan, pwm-fan, hwmon, thermal zone, cooling device, trip point, 风扇, 转速, 热管理. DO NOT USE FOR: 板载 LED（用 led，不同 PWM 控制器），40Pin 上的 PWM2（用 40pin）。"
license: MIT
metadata:
  author: Quectel PI M2 外设 SKILL 库
  version: "1.0.0"
  board: Quectel PI M2 (RK3576 / QSM610ZAP-WF)
---

# M2 风扇 / 热管理 SKILL — PWM 风扇（hwmon）+ thermal 温控

适用：Quectel PI M2（`quectel,pi-m2-rk3576`）。LED 在 `led/SKILL.md`（两者是**不同的 PWM 控制器**，不共用）。

## 1. 硬件事实

| 项 | 值 |
|---|---|
| **风扇** | `PWM1_CH1_M0`（模组 **pin190** = `GPIO0_B5_d` / PWM1）→ MOS **Q0401**（PNM523T201E0，NMOS） |
| 连接器 | **J0401**（4Pin） |
| 控制器 | **`2add1000.pwm` = `/sys/class/pwm/pwmchip1`**（npwm=1）；pinmux: pin 13 (gpio0-13) = `pwm1m0-ch1` |
| 驱动 | `pwm-fan`（内核），注册成 **hwmon**，`/sys/kernel/debug/pwm` 里显示 `pwm-0 (pwm-fan)` |
| 逻辑 | 低 = 风扇关；**需要配成 PWM**，联动温度/指令控制。配件参考 radxa X4 散热器 |

DTS（`rk3576-quectel-pi-m2-linux.dtsi`）：

```dts
system_fan: pwm-fan {
    compatible = "pwm-fan";
    #cooling-cells = <2>;
    pwms = <&pwm1_6ch_1 0 200000 0>;        /* period 200us (~5kHz) */
    cooling-levels = <0 64 128 192 255>;
    rockchip,temp-trips = <
        30000 1
        40000 2
        50000 3
        60000 4
    >;
};

/* rk3576-quectel-pi-common.dtsi */
&pwm1_6ch_1 { status = "okay"; pinctrl-0 = <&pwm1m0_ch1>; };   /* FAN */
```

内核片段：`kernel/arch/arm64/configs/quectel-pwm-fan.config`（`CONFIG_SENSORS_PWM_FAN=y`），
已列在 `tools/build-kernel.sh:63` 的 `KERNEL_FRAGMENTS` 里（本仓库没有 defconfig，
片段清单只在这份脚本和 `tools/VERSION.txt` 的 `FRAGMENTS` 行）。

## 2. 使用（hwmon）

```bash
# 找 hwmon（编号会漂，按 name 找）
H=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name 2>/dev/null)" = pwmfan ] && echo $h; done)
cat $H/pwm1           # 当前档位（0–255）
cat $H/pwm1_enable    # 工作模式，见下表
```

`pwm1_enable` 取值（驱动 `drivers/hwmon/pwm-fan.c` 的 `enum pwm_fan_enable_mode`）：

| 值 | 枚举名 | 含义 |
|---|---|---|
| 0 | `pwm_off_reg_off` | **停风扇**（关 PWM + 关供电；驱动注释 "Disable pwm-fan unconditionally"） |
| 1 | `pwm_disable_reg_enable` | probe 完的默认值；PWM 由温控 notifier 驱动 |
| 2 | `pwm_enable_reg_enable` | PWM 开 + 供电开 —— **手动调速用这个** |
| 3 | `pwm_disable_reg_disable` | 关 PWM + 关供电 |

```bash
# 手动调速（必须先 enable=2；enable=0 时写 pwm1 不生效）
echo 2 > $H/pwm1_enable
echo 255 > $H/pwm1        # 0–255，立即生效
```

- **2026-10-10 上板实测**（全部板侧取证）：
  - 板上风扇 = **`hwmon6`（`name=pwmfan`）**，`pwm1_enable=1`；FCT 里硬编码的 hwmon6 与板上一致。
  - **档位 → 占空比**（`period = 200000ns`）：`duty = 档位/255 × 200000ns`
    `0→0ns(停)`｜`64→50196(25%)`｜`128→100392(50%)`｜`192→150588(75%)`｜`255→199999(100%)`
  - **写 `pwm1` 立即生效，但会被温控 notifier 按 `temp-trips` 覆盖**：写 255 → duty 199999ns，
    几秒后回到 192 / 150588ns（当时 soc 51℃ 落在 50℃ 档）。**手动调速只在温度不跨档时稳得住。**
  - **要满速不必手动**：跑热即得。8 核满载 5 秒 soc 63.7℃ / bigcore 70.2℃ → 自动 **`pwm1=255`（100%）**；
    停负载后 15 秒内回落 192。这也是验证温控档位的办法。
  - `hwmon6` 下**只有 `pwm1` / `pwm1_enable` 两个属性** —— **没有 `fan1_input`（本风扇无 TACH 线，读不到转速）、没有温度属性**。
  - **本板没有 `fan_ctrl.service`**；M2 风扇温控完全由内核 notifier 驱动。
- **温控是内核驱动 + Rockchip 私有 notifier**（不是标准 thermal cooling device ——
  `/sys/class/thermal/cooling_device*` 里只有 gpu/npu 的 devfreq，**没有 pwm-fan，故无法从 thermal 侧禁用**）：
  `pwm_fan_register_thermal_notifier` 订阅 `SYSTEM_MONITOR_CHANGE_TEMP`，每几秒按温度重设 `pwm1`。
  `cooling-levels` 0/64/128/192/255 对应 `rockchip,temp-trips` 的 30/40/50/60°C 四档。
  **改温度点改 DTS 里这两处，不要在应用里写死。**
- 温度查看：`qpi-config dump temperature`，或直接读 6 个 zone：
  `soc / bigcore / little-core / ddr / npu / gpu`（对应 `hwmon0..5`）。

### 产测 AT

```bash
AT+FAN          # 风扇起转（FAN:START / FAN:FAIL）
AT+FAN=1|0      # 人工判定结果（1=PASS 0=FAIL）→ 持久化
AT+FANON / AT+FANOFF   # 风扇开关
AT+FAN=?        # +FAN: (0,1)
```

## 3. 扩展场景

- **散热策略联动**：`pwm-fan` 作为 cooling device 注册 `#cooling-cells = <2>`，
  可以挂到 CPU/GPU/DMC 的 thermal zone 上（改 thermal zone 的 `cooling-maps`）。
  M2 当前只用了 `rockchip,temp-trips` 这套简易温控。
- **换风扇**：注意 **Vth 与 MOS 驱动能力**（Q0401 = PNM523T201E0，VDS=20V/1A）；
  变频会让 MOS 驱动风扇出现噪音，非必要别动 `period`。
- **40Pin 上另有 PWM**：`PWM2_CH3`（pin33，`2ade3000.pwm`；chip 号随启动变，本板实测 `pwmchip3`），
  没有开关、直接走 `/sys/class/pwm`（见 `40pin/SKILL.md`），与板载风扇无关。

## 4. 已知坑

1. **`pwm1`(风扇) 的 period 是 200000ns (5kHz)**；改频率会让 MOS 驱动风扇出现噪音，非必要别改。
2. **`temp-trips` 是毫摄氏度**（`30000` = 30°C），别写成 30。
3. **hwmon 编号会变**：FCT 里硬编码 `hwmon6`（板上实测也是 6），加了别的 hwmon 设备后编号会漂。
   自己写脚本时用 `grep -l pwm1_enable /sys/class/hwmon/hwmon*/` 动态找。
4. **风扇的 PWM 被内核驱动占用**：`/sys/class/pwm/pwmchip1/export` 会失败
   （`/sys/kernel/debug/pwm` 显示 `pwm-0 (pwm-fan)`）—— 要手动控就写 hwmon，别去 export。
5. **`pwm1_enable=0` 是"停风扇"，不是"切手动"**（见 §2 表）。手动调速用 `enable=2`；
   写 `pwm1` 后值会被温控 notifier 覆盖是正常现象，不是写失败。
6. **本风扇无转速反馈**（hwmon 下没有 `fan1_input`），只能靠听声音/看温度判断；
   想看 RPM 得换带 TACH 的 4 线风扇（J0401 是 4Pin，但当前配件未接 TACH）。
7. **风扇接在 J0401**（4Pin）；换风扇注意 Vth 与 MOS 驱动能力。
8. 不要用 `sed` 改 DTS。
