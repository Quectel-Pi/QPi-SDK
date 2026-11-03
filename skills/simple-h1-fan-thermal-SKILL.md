---
name: simple-h1-fan-thermal
description: "simple-h1 SDK: 板载 PWM 风扇（PM8350C PWM3 + TACH）控速与 thermal zone 温度监控"
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [qualcomm, qcs6490, quectel, simple-h1, fan, thermal, hwmon, pwm]
    related_skills: [simple-h1-build, simple-h1-pmic-power, simple-h1-gpio-40pin]
---

# simple-h1 风扇 / 热管理

设备树: `kernel/arch/arm64/boot/dts/qcom/qcs6490-idp-pi.dts`（行号以该文件为准）。
规格书: "支持根据温度更改风扇速度（40/60/75 ℃）"。

## 1. 硬件事实

| 项 | 值 |
|---|---|
| 风扇接口 | 板上 **5V 风扇连接器**（p13，接口表序号 3） |
| PWM 源 | **PM8350C PWM 通道 3**（不是 SoC TLMM PWM） |
| 测速（TACH） | SoC **`tlmm 112`**，pinctrl `fanfan_tach_default`（DTS:1502-1508，`input-enable` + `bias-disable`） |
| 控制脚 | `pm8350c_gpios gpio9`，`function="func1"`，`output-high`（pinctrl `fanfan_pwm_ctrl_default`，DTS:2018-2026） |
| 转速换算 | `pulses-per-revolution = <2>` |
| 驱动 | `CONFIG_SENSORS_PWM_FAN=m`（生效配置 `scripts/kernel-config:3905`；`kernel/arch/arm64/configs/qcom_defconfig:370` 同值），设备节点注册成 **hwmon**，不是 LED class |

```dts
fanfan: pwm-fan {                                  /* DTS:2030-2041 */
    compatible = "pwm-fan";
    pinctrl-0 = <&fanfan_pwm_ctrl_default>, <&fanfan_tach_default>;
    pwms = <&pm8350c_pwm 3 65535>;                 /* PWM 周期 65535 ns */
    interrupts = <112 IRQ_TYPE_EDGE_FALLING>;      /* TACH */
    pulses-per-revolution = <2>;
    cooling-levels = <0 85 128 170 212 255>;
    status = "okay";
};
```
> `cooling-levels` 有 6 档，但 `&fanfan` **没有**挂进任何 thermal zone 的 cooling-maps
> `&fanfan` 全文件仅被 DTS:2033 的 `pinctrl-0` 引用，所以内核不做自动控温，策略在用户空间（§3）。

> **实测**：`hwmon` 里 `name = pwmfan` 的节点存在（本板是 hwmon30，编号会变），未接风扇时
> `pwm1 = 0`、`pwm1_enable = 0`、`fan1_input = 0`；`thermal_zone*` 里 `cpuss0-thermal` 也在（约 40.5 ℃）。

> 两个镜像都自带 `fan_ctrl.service`（描述 "Fan LED Control by CPU Temperature"），实测为 `inactive/dead`；
> 它不在本 SDK 的 overlay 里。要自己控速见 §3，别与它抢 `pwm1`。

## 2. 运行时节点（hwmon）

```bash
# 按 name == "pwmfan" 找，不要硬编码 hwmonN（编号随加载顺序变）
for d in /sys/class/hwmon/hwmon*; do echo "$d -> $(cat $d/name 2>/dev/null)"; done
HWMON=$(for d in /sys/class/hwmon/hwmon*; do [ "$(cat $d/name)" = pwmfan ] && echo $d; done)

cat $HWMON/pwm1          # 当前占空比 0-255
cat $HWMON/pwm1_enable   # 0 = 关闭输出, 1 = 手动
cat $HWMON/fan1_input    # 实际转速 RPM（依赖 TACH 接线）
lsmod | grep pwm_fan || modprobe pwm_fan   # 模块没自动加载时手动补
```
- `/sys/class/leds/` 下**没有** `fanfan`（`&pm8350c_pwm` 只登记了 `led@1/2/3` 红绿蓝，
  DTS:986-1008）——文档里 `echo > /sys/class/leds/fanfan/brightness` 那条路在本板无效，
  **控风扇只写 `$HWMON/pwm1`**。

## 3. 控速策略（40 / 60 / 75 ℃）

| 温度（`cpuss0-thermal`） | `pwm1` | `pwm1_enable` | 档位 | 实测转速（原装风扇） |
|---|---|---|---|---|
| < 40 ℃ | `0` | 0 | OFF | 0（真停转） |
| 40 ~ 60 ℃ | `85` | 1 | LOW | 4662 → 稳定 **5483** RPM |
| 60 ~ 75 ℃ | `170` | 1 | MID | **8826** RPM |
| ≥ 75 ℃ | `255` | 1 | HIGH | **9960** RPM |

### 3.1 通用控速脚本（设备侧可直接用）

```bash
cat > /usr/local/bin/fan-ctl.sh <<'EOF'
#!/bin/sh
# 板载风扇按 cpuss0-thermal 温度调速：40/60/75 ℃ -> 85/170/255
HWMON=""; ZONE=""
for d in /sys/class/hwmon/hwmon*; do [ "$(cat "$d/name" 2>/dev/null)" = pwmfan ] && HWMON="$d" && break; done
for z in /sys/class/thermal/thermal_zone*; do [ "$(cat "$z/type" 2>/dev/null)" = cpuss0-thermal ] && ZONE="$z" && break; done
[ -z "$HWMON" ] || [ -z "$ZONE" ] && exit 0

T=$(( $(cat "$ZONE/temp" 2>/dev/null || echo 0) / 1000 ))
PREV=$(cat "$HWMON/pwm1" 2>/dev/null || echo 0)

if   [ "$T" -ge 75 ]; then PWM=255
elif [ "$T" -ge 60 ]; then PWM=170
elif [ "$T" -ge 40 ]; then PWM=85
else PWM=0; fi

if [ "$PWM" = 0 ]; then
    echo 0 > "$HWMON/pwm1"; echo 0 > "$HWMON/pwm1_enable"
else
    echo 1 > "$HWMON/pwm1_enable"
    [ "$PREV" = 0 ] && { echo 255 > "$HWMON/pwm1"; sleep 1; }   # kickstart 保底
    echo "$PWM" > "$HWMON/pwm1"
fi
echo "[FAN_CTRL] Temp=${T}C, PWM=${PWM}" > /dev/kmsg
EOF
chmod +x /usr/local/bin/fan-ctl.sh
/usr/local/bin/fan-ctl.sh            # 手动跑一次
```

### 3.2 常驻

```bash
printf '[Unit]\nDescription=H1 fan control\n[Service]\nExecStart=/bin/sh -c "while true; do /usr/local/bin/fan-ctl.sh; sleep 5; done"\nRestart=always\n[Install]\nWantedBy=multi-user.target\n' \
    > /etc/systemd/system/fan-ctl.service
systemctl daemon-reload && systemctl enable --now fan-ctl.service
systemctl status fan-ctl.service ; dmesg | grep FAN_CTRL
```

固化进镜像：脚本放 `overlay/usr/local/bin/fan-ctl.sh`、unit 放
`overlay/etc/systemd/system/fan-ctl.service`，在 `hooks/*.sh` 里建
`multi-user.target.wants` 软链（钩子在打包前以 root 执行），再
`SKIP_KERNEL=1 ./scripts/build-all.sh` → `./scripts/flash.sh`。

## 4. 温度监控

```bash
for z in /sys/class/thermal/thermal_zone*; do
    printf "%-24s %s %s\n" "$(cat $z/type)" "$(cat $z/temp)" "$z"
done
```

| 热区 | 传感器 | DTS 行 | trip |
|---|---|---|---|
| `quiet-thermal` | `pmk8350_adc_tm 1` | 256-268 | 125 ℃ passive |
| `sdm-skin-thermal` | `pmk8350_adc_tm 3` | 270-282 | 125 ℃ passive |
| `xo-thermal` | `pmk8350_adc_tm 0` | 284-296 | 125 ℃ passive |
| `cpuss0-thermal` | `qcm6490-addons.dtsi:1444` | — | 125 ℃ passive / **118 ℃ crit** |
| `pm7250b-bcl-lvl0/1/2` | `pm7250b_bcl 5/6/7` | 2141-2240 | 限流联动（见 `simple-h1-pmic-power-SKILL.md`） |

## 5. 已知坑

1. **不要硬编码 `hwmonN`**：按 `name == "pwmfan"` 查找，加载顺序变化会让编号漂移。
2. **不要硬编码 `thermal_zoneN`**：按 `type` 找 `cpuss0-thermal`；改 DTS 热区后编号会变。
3. **`pwm1_enable=0` 才是真停转**（只写 `pwm1=0` 时驱动可能仍输出），停止要两个都写。
4. **kickstart 只是保底**：本板风扇从停转直接给 85 也能起转（4662 RPM），
   别把它写成"不 kickstart 就转不起来"的硬性前提；换启动阈值高的风扇才关键。
5. **`fan1_input = 0` 有两义**：① 风扇没接（本板此前就是这样，接线后立刻有读数）；
   ② 已停转。**先看接线，再怀疑 TACH**（TACH 走 `tlmm 112`，实测有效）。
6. **DTS `cooling-levels` 与脚本阈值表不完全一致**（DTS 多 128/212 两档）；
   改策略以脚本为准，或两边一起改。
7. **40Pin 上的 PWM 风扇不是这套**：pin33(`GPIO_78`) + pin32(`GPIO_76` Tach)，
   走 lgpio `lgTxPwm`，见 `simple-h1-gpio-40pin-SKILL.md`。
8. **`cpuss0-thermal` 的 crit 是 118 ℃、passive 是 125 ℃**：先到 crit 就触发保护，
   看到"满载突然关机"先查这条 trip，别只看 passive。
9. **噪声优化**：MID 档 170 可降到 128；常转场景固定 `pwm1_enable=1` + 固定 `pwm1` 并
   `systemctl disable fan-ctl`，否则会被覆盖。
