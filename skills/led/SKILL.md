---
name: led
description: "Quectel PI M2 板载 LED：PWM0_CH0 → 数字三极管 Q0402 → D0407（裸 PWM sysfs，无 LED class 节点）的点亮/调光/呼吸写法，以及 gpio-leds -EBUSY 的正确解释。当用户说「M2 LED 怎么点」「板载红灯」「gpio-leds 报 EBUSY」「PWM 调光」时使用。WHEN: M2 LED, PWM0, pwm sysfs, gpio-leds EBUSY, breathing, 点亮, 绿色/红色指示灯. DO NOT USE FOR: 风扇 PWM1（用 fan-thermal），以太网口状态灯（用 ethernet）。"
license: MIT
metadata:
  author: Quectel PI M2 外设 SKILL 库
  version: "1.0.0"
  board: Quectel PI M2 (RK3576 / QSM610ZAP-WF)
---

# M2 LED SKILL — 板载指示灯（PWM0_CH0 → Q0402 → D0407）

适用：Quectel PI M2（`quectel,pi-m2-rk3576`）。

## 1. 硬件事实

| 功能 | 控制 | 说明 |
|---|---|---|
| **可控 LED（红灯 D0407）** | **`PWM0_CH0_M0`**（模组 **pin26**）→ 数字三极管 **Q0402**（DTC123JMT2L，NPN 带阻）→ **D0407**（A-SP194R6C-C02-4T，红光，0603） | pinmap：**引脚输出低电平 LED 不亮、高电平亮**；用数字三极管驱动 |
| 电源指示灯 | 硬件常亮，**软件不可控** | D0501 蓝 / D0702（以太网 LED2） |
| 以太网 LED | 黄灯 → PHY LED1、绿灯 → PHY LED2（J0701） | **低电平点亮**，状态由 PHY 内部寄存器配置（见 `ethernet/SKILL.md`） |

DTS（`rk3576-quectel-pi-common.dtsi`）：

```dts
&pwm0_2ch_0 { status = "okay"; pinctrl-0 = <&pwm0m0_ch0>; };   /* LED */
```

引脚/控制器归属（2026-10-10 上板实测）：

```
27330000.pwm  →  /sys/class/pwm/pwmchip0（npwm=1）
pinmux: pin 20 (gpio0-20): 27330000.pwm  function pwm0 group pwm0m0-ch0
/sys/kernel/debug/pwm: platform/27330000.pwm  pwm-0 (sysfs)
clk: clk_pmu1pwm (24MHz) → 27330000.pwm（PWM0 时钟有源）
```

> ⚠️ **这颗 LED 是"裸 PWM"，没有 LED class**：`/sys/class/leds` 里**只有 `mmc0::`**，
> **永远不会有 `work` 之类的节点**（见 §3 的 `gpio-leds` 说明）。控制它只能走 `/sys/class/pwm`。
> 也**不能当普通 GPIO 用** —— 该脚被 DT 固定 mux 成 pwm0 功能，`pwm0` 即使 unexport 也不释放
> （pinmux 仍显示 `27330000.pwm`）。M2 上 `gpioset/gpioget/gpiodetect` 有（`rgs` 没有，那是别的板子），
> 但对这个脚无效。

## 2. 使用（PWM sysfs）✅ 2026-10-10 上板实测通过

```bash
# 1) 导出 PWM0 通道 0（注意是 pwmchip0 = 27330000.pwm 这一支）
echo 0 > /sys/class/pwm/pwmchip0/export
cd /sys/class/pwm/pwmchip0/pwm0

# 2) ★ 顺序不能反（rockchip pwm v4 sysfs 实测要求）
echo 0 > enable           # 0) 先关，避免改参数时输出毛刺
echo 200000 > period      # 1) 必须最先写 period；period=0 时写 polarity/enable 会 EINVAL
echo normal > polarity    # 2) 新导出默认是 inversed，必须改回 normal（否则点不亮）
echo 200000 > duty_cycle  # 3) duty = period → 全亮（5kHz，与风扇同频）
echo 1 > enable           # 4) 最后使能

# 3) 收尾（熄灯 + 释放）
echo 0 > enable
echo 0 > /sys/class/pwm/pwmchip0/unexport
```

- **实测结论**：`period=200000`(5kHz) + `normal` + `duty=200000` → **灯亮**；
  `period=2000000000`(1Hz, duty 50%) → **肉眼可见慢闪**；`inversed` 全亮时不亮（极性确实要 normal）。
- `duty_cycle` 写入**不会被驱动裁剪**（写 100000/190000/200000 读回一致）。
- 亮度调节：直接改 `duty_cycle`。
- 这条顺序是 **FCT 实际踩坑总结**（板上 `port_bridge` 的 LED 产测就按这个顺序做，源码注释原文
  "Order matters for rockchip pwm v4 sysfs (all verified on target)"）。

### 产测 AT

```bash
AT+LED=0      # 只确认端口有响应（=板子已通电）→ LED:PASS
AT+LED=1      # 点亮 3 秒后自动关；PWM 全部成功 → LED:PASS，否则 LED:FAIL（结果持久化）
AT+LED=?      # +LED: (0,1)
```

## 3. ⚠️ 修正：`gpio-leds` 的 `-EBUSY` **不是**"被 PWM0 占用"

DT 里有这么个节点（**来自通用 dtsi，不是 M2 加的控制灯**）：

```
leds { compatible = "gpio-leds"; work { linux,default-trigger = "heartbeat"; gpios = <&gpio0 12 GPIO_ACTIVE_HIGH>; } }
```

它在启动时报 `leds-gpio: probe of leds failed with error -16`（-EBUSY）。
**旧稿把原因写成"该 GPIO 被 PWM0_CH0 复用占用"——这是错的**（2026-10-10 实测核对）：

```
leds/work 的 gpios = gpio0-12        （od 读 /proc/device-tree/leds/work/gpios → pin 12）
PWM0_CH0 实际在      gpio0-20        （pinmux: pin 20 (gpio0-20): 27330000.pwm）
```

**两个是不同的脚**，所以"占用"解释不成立；`-EBUSY` 的真正原因未定位。
**结论不变的部分**：`/sys/class/leds` 里不会有 `work`，别在 LED class 上找；控灯走 §2 的 PWM0 路子。
如果哪天要启用 `heartbeat` 心跳灯，得**改这个 gpio-leds 节点指向 gpio0-20 并让 pwm0 让位**（二者互斥）。

## 4. 已知坑

1. **顺序**：`period` → `polarity` → `duty_cycle` → `enable`；少写 `period` 直接 EINVAL。
2. **`polarity` 默认是 `inversed`** —— 不改 `normal` 灯不亮（这是最容易踩的一条）。
3. **`pwmchip` 编号要看设备名**：LED = `27330000.pwm`、风扇 = `2add1000.pwm`。编号随启动变，
   用 `for c in /sys/class/pwm/pwmchip*; do echo "$c -> $(readlink -f $c)"; done` 反查
   （本板实测：pwmchip0=27330000、pwmchip1=2add1000、pwmchip2=2add5000(pin35)、pwmchip3=2ade3000(pin33)）。
   别按编号猜。
4. **该脚不能当 GPIO**（见 §1）；也**没有 LED class 节点**（见 §3）。
5. **别把电源指示灯/网口 LED 当可控** —— 前者硬件常亮，后者由 PHY 寄存器决定。
6. 不要用 `sed` 改 DTS；`&pwm0_2ch_0` 的 pinctrl 决定了 pin20 的归属。
