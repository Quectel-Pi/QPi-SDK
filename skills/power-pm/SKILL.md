---
name: power-pm
description: "Quectel PI M2 电源与低功耗：电源使能链（默认低电平断开、整版 3V3 总闸 GPIO4_A7）、S3 深睡与唤醒源配置、关机/重启/电源键行为、休眠唤不醒排查。当用户说「M2 休眠唤不醒」「怎么关机重启」「3V3 掉了」「低功耗配置」「省电」时使用。WHEN: M2 power, PM, suspend S3, wakeup source, power enable GPIO, shutdown reboot, watchdog, 电源, 休眠, 唤醒, 关机. DO NOT USE FOR: 单个外设的供电细节（见各分册的电源表），按键硬件（用 rtc-keys）。"
license: MIT
metadata:
  author: Quectel PI M2 外设 SKILL 库
  version: "1.0.0"
  board: Quectel PI M2 (RK3576 / QSM610ZAP-WF)
---

# M2 电源 / 低功耗 (PM) SKILL — 使能链、S3 深睡唤醒、关机重启

适用：Quectel PI M2（`quectel,pi-m2-rk3576`）。相关：`peripherals-overview/SKILL.md` 的电源使能矩阵。

## 1. 电源使能链（改任何外设前先确认这条链）

```
VDD_5V0_SYS (Type-C / 40Pin pin2,4)
   └── U0502 DC-DC BUCK (ETA) ──> vcc_sys
          ├── U0509 IN ──> WIFI_BT_3V3 ──> FCS960K VBAT
          └── vcc_3v3_s0 / vcca_3v3_s0 等
整版 3.3V 总闸 = DCDC_EN_3V3 (模组 pin17 = GPIO4_A7)，高=使能，默认低下拉
```

**关键事实**：`GPIO4_A7` 在 M2 上**不是** PCIe1 私有使能（那是基线 `rk3576-evb.dtsi` 的用法），
它是**整版 3V3**。`rk3576-quectel-pi-m2-linux.dtsi` 里：

```dts
&vcc_3v3_s0 {
    enable-active-high;
    gpio = <&gpio4 RK_PA7 GPIO_ACTIVE_HIGH>;   /* DCDC_EN_3V3 */
    pinctrl-0 = <&dcdc_3v3_en>;
    regulator-state-mem { regulator-on-in-suspend; regulator-suspend-microvolt = <3300000>; };
};
&vcc3v3_pcie1 { /delete-property/ gpios; /delete-property/ enable-active-high; status = "disabled"; };
&pinctrl { power { dcdc_3v3_en: dcdc-3v3-en {
    rockchip,pins = <4 RK_PA7 RK_FUNC_GPIO &pcfg_output_high_pull_up>; }; }; }
```

其余使能脚（USB/HUB/ETH/CODEC/CAM/LCM/40PIN/WiFi-BT/PCIe）见总览表的"电源使能矩阵"。
USB 与 SD 的细节分别在 `usb/SKILL.md`、`storage/SKILL.md`。

## 2. S3 深睡 / 唤醒配置

```dts
&rockchip_suspend {
    rockchip,sleep-mode-config = <
        (0 | RKPM_SLP_ARMOFF_LOGOFF | RKPM_SLP_PMU_PMUALIVE_32K | RKPM_SLP_32K_EXT) >;

    rockchip,wakeup-config = <(0 | RKPM_GPIO_WKUP_EN | RKPM_USB_WKUP_EN)>;

    /* 深睡时保活的 GPIO：实测 GPIO4_A7 会掉，直接切掉 VDD_3V3_SYS → U0509 IN → FCS960K VBAT */
    rockchip,power-ctrl =
        <&gpio4 RK_PA7 GPIO_ACTIVE_HIGH>,  /* DCDC_EN_3V3 / VDD_3V3_SYS */
        <&gpio3 RK_PA3 GPIO_ACTIVE_HIGH>,  /* WIFI_BT_PWR_EN_3V3 */
        <&gpio2 RK_PB3 GPIO_ACTIVE_HIGH>;  /* WMOB_PWRKEY_WIFI_EN_3V3 */

    rockchip,sleep-io-ret-config = <(0 | RKPM_VCCIO2_RET_EN | RKPM_VCCIO4_RET_EN)>;
};
```

各供电域在 mem 状态保持：

```dts
&vdd_logic_s0  { regulator-state-mem { regulator-on-in-suspend; regulator-suspend-microvolt = <800000>; }; };
&vcca_1v8_s0   { ... 1800000 ... };
&vdda_0v85_s0  { ...  850000 ... };
&vdda_0v75_s0  { ...  750000 ... };
```

- 唤醒源：`RKPM_GPIO_WKUP_EN` + `RKPM_USB_WKUP_EN`（USB 唤醒）。
  相关设备也要 `wakeup-source`：`&u2phy1`、`&wireless_wlan`、`&wireless_bluetooth`。
- 这处配置只改 dtsi（+44 行）。
- **FCS960K 跨 suspend 不重新初始化**：板上 `/usr/lib/systemd/system-sleep/03fcs960k`
  在 pre/post 都 `exit 0`，靠上面的 `power-ctrl` 保电。

### 使用

```bash
# 直接挂起（绕过 systemd-sleep hooks）——板上现成脚本
/usr/local/sbin/direct-suspend.sh                    # 内容就是 echo mem > /sys/power/state
echo mem > /sys/power/state
# 唤醒源
cat /proc/acpi/wakeup 2>/dev/null ; cat /sys/power/wakeup_count
cat /sys/power/wake_lock /sys/power/wake_unlock 2>/dev/null
dmesg | grep -iE "PM:|suspend|resume|rockchip_suspend"
# RTC 定时唤醒
echo +60 > /sys/class/rtc/rtc0/wakealarm       # 见 rtc-keys/SKILL.md
# AT 侧
AT+SLEEP        # 休眠
AT+POWEROFF     # 关机
```

## 3. 关机 / 重启

| 现象/需求 | 处理 |
|---|---|
| `adb reboot` 不走正常重启流程（Debian） | 已修；异常时对比 `adb reboot` 与 `systemctl reboot` |
| 偶发卡住不重启 | 有重启看门狗兜底（自动复位），PMIC 复位日志可查 |
| 偶发无法重启 | 依赖 RK806 PMIC 拉 RESETB 做完整断电重启 |
| 重启偶发耗时 121s | 额外分区 fstab 已加超时兜底 + 开机自愈挂载，别去掉超时参数 |
| 关机侧稳定性 | 停止超时已收敛 + 卡住自愈 |
| GNOME 重启耗时异常 | 已修；仍异常时先看 systemd 停止超时 |
| 指定启动模式失效 | `reboot loader` / `reboot fastboot` 已可用 |

**M2 的重启依赖 RK806 PMIC 拉 RESETB 做完整断电重启**；改关机/重启流程时不要绕过它。

## 4. 电源键

- 电源键行为由 GNOME 电源设置控制；`input-event-daemon` / `triggerhappy` 不接管 KEY_POWER。
- 硬件按键映射（PON/PWRKEY/VOL_UP）见 `rtc-keys/SKILL.md`。

## 5. 扩展场景

- **低功耗待机（非 S3）**：`qpi-config dump systemusage`、`dump temperature` 看运行时状态；
  CPU/DVFS 用 SoC 默认配置（M2 未改动）。
- **RTC 定时唤醒 + 深睡**：RTC alarm + `RTC_IRQ_N(GPIO0_A5)`；确保 `RKPM_GPIO_WKUP_EN` 打开。
- **USB 唤醒**：`RKPM_USB_WKUP_EN` + `&u2phy1 { wakeup-source; }`（USB1/HUB 域）。
- **看门狗**：`usb-gadget-watch.sh` 是应用级看门狗（见 `usb/SKILL.md`）；
  硬件 WDT 在 RK3576 SoC 内，默认未在 M2 DTS 里特化。

## 6. 已知坑

1. **`GPIO4_A7` 会掉电**（S3 以及被别的功能占用）→ 整版 3V3 没了，Wi-Fi/BT/SD/40Pin 全挂。
   `rockchip,power-ctrl` 就是为了保它，别删。
2. **`GPIO4_A7` ≠ PCIe1 使能**。照抄基线 `rk3576-evb.dtsi` 的 `vcc3v3_pcie1` 会抢这个脚。
3. **内核以静态编译为主，但存在外置模块**：`/lib/modules` 里当前有 **`aic8800_bsp.ko`/`aic8800_btlpm.ko`/`aic8800_fdrv.ko`**
   （Wi-Fi/BT，`lsmod` 可见），其余驱动多为 `=y`。
   ⇒ 改电源/PM 相关 Kconfig 时**按静态编译对待**（`=y` 最稳）；但若确实要用 `=m`，
   该 `.ko` 必须进 rootfs 的 `/lib/modules` 且有加载机制（别以为 `=m` 一定不生效 —— 见 `storage/SKILL.md` 同条）。
4. **`direct-suspend.sh` 绕过 systemd-sleep hooks**：用它挂起时，依赖 systemd 的保存/恢复逻辑不会跑，
   排查"挂起后外设异常"要区分是用哪条路径挂的。
5. **摄像/视频与休眠相互影响**：视频链路开着时进入 S3 有过异常，排查时先停视频再复测。
