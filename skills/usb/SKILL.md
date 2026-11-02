---
name: usb
description: "Quectel PI M2 USB：USB0 OTG（USB3.1 SuperSpeed，ETA6280S2F 供电）+ USB1→CH634M HUB→3 路 USB-A + Type-C 仅供电无数据；host/peripheral 切换（qpi-config usb0）、DTS 改法、ADB 掉线/USB 掉速排查、USB gadget 看门狗。当用户说「M2 USB 不识别」「ADB 老掉」「Type-C 不能传数据」「切成 host/peripheral」「U 盘挂不上」时使用。WHEN: M2 USB, USB0 OTG, CH634M hub, USB-A, usb host peripheral, adb disconnect, Type-C data, 掉线, 掉速. DO NOT USE FOR: 烧录/下载模式（用 sdk-flash），存储挂载（用 storage）。"
license: MIT
metadata:
  author: Quectel PI M2 外设 SKILL 库
  version: "1.0.0"
  board: Quectel PI M2 (RK3576 / QSM610ZAP-WF)
---

# M2 USB SKILL — USB0 OTG(3.1 SS) + CH634M HUB + 3 个 USB-A

适用：Quectel PI M2（`quectel,pi-m2-rk3576`）。

## 1. 硬件事实（网表核对过，勿凭印象）

| 接口 | 控制器 | 连接器 | 说明 |
|---|---|---|---|
| **USB0** | `usb_drd0_dwc3` + `u2phy0_otg` + `usbdp_phy_u3` | **J1602 上层**（USB-A） | USB3.1 SuperSpeed（只走 SS1 通道）；下载/ADB 调试口，**标配用 USB-A 转 USB-A 线** |
| **USB1** | `usb_drd1_dwc3`（host only） | — | 接到 **CH634M**（U0601）USB3.0 HUB 上行 |
| HUB 下行 P2/P3 | — | **J1601** 双层 A 口 | — |
| HUB 下行 P4 | — | **J1602 下层** | — |
| Type-C | — | **J0501** | 只有 `TYPEC_POWER_5V` + CC，**没有 USB 数据线**（不是数据口，别当 OTG 用） |

- USB0 VBUS（USB-A 口 5V）：`USB0_PWR_EN_1V8`（模组 pin25 = **`GPIO0_D1`**）→
  负载开关 **ETA6280S2F（U0505）** EN 脚 → 输出 `USB0_PORT_OTG` → J1602 上层 VBUS。
  DTS 里做成 regulator `vbus5v0_usb0_otg` 挂在 `&u2phy0_otg` 的 `vbus-supply` 上，
  **由 PHY 模式自动管理**（host→开，peripheral→关，避免反向馈电）。
- HUB 与下行 A 口电源：`USB1_PWR_EN_1V8`（模组 pin352 = **`GPIO0_A0`**），高=开。
  DTS 里是 `vcc_usb1_hub` regulator（`regulator-boot-on` + `always-on`）。
- HUB 晶振 X0601 24MHz；HUB 供电 `CH634M_VDD12` / `CH634M_VDD33` / `CH634M_VDD_5V0`。
- 载板上还留了一路 `90OHM_WIFI_BT_HS_DP/DM` 接到 U1704（**未贴片 NM**）——不要引用。

## 2. DTS 关键改法（`rk3576-quectel-pi-m2-linux.dtsi`）

```dts
/* 打开 DP-PHY 的 U3 lane，让 USB0 走 SuperSpeed（common 里默认 disabled） */
&usbdp_phy    { status = "okay"; };
&usbdp_phy_u3 { status = "okay"; };

&usb_drd0_dwc3 {
    dr_mode = "peripheral";          /* 基准：ADB/下载；host 模式用 overlay 覆盖 */
    extcon = <&u2phy0>;
    maximum-speed = "super-speed";
    phys = <&u2phy0_otg>, <&usbdp_phy_u3>;
    phy-names = "usb2-phy", "usb3-phy";
};
&u2phy0     { status = "okay"; };
&u2phy0_otg { vbus-supply = <&vbus5v0_usb0_otg>; };

&usb_drd1_dwc3 { dr_mode = "host"; status = "okay"; };   /* USB1 → HUB */
&usbc1 { status = "disabled"; }                          /* 无 Type-C DP Alt Mode */
&usbc0 { status = "disabled"; }

/* 腾出 GPIO4_B2 给喇叭 PA：停掉 EVB 的 Type-C VBUS 节点并删掉 u2phy1_otg 的 vbus-supply
 * —— 否则 u2phy1_otg deferred probe 会挡住 USB1 控制器初始化 → HUB 不上电 */
&vbus5v0_typec_evb { status = "disabled"; };
&u2phy1_otg { /delete-property/ vbus-supply; };
&u2phy1 { wakeup-source; status = "okay"; };   /* S3 唤醒源 */
```

## 3. USB0 host/peripheral 切换（板级机制）

板上 `/usr/sbin/qpi-config` + U-Boot + dtbo：

```bash
# 刷机/调试（默认）：peripheral，USB-A 口上有 ADB
qpi-config usb0 peripheral

# 当 host 用（U 盘/键盘/摄像头）：写入 /etc/qpi-config/usb0_host 标记 → **重启生效**
qpi-config usb0 host
```

- overlay 源文件：`kernel/arch/arm64/boot/dts/rockchip/rk3576-quectel-pi-m2-usb0-host.dts`
  （只做一件事：`target-path = "/usb@23000000"` 下 `dr_mode = "host"`）。
- ⚠️ **本仓库的打包链不产出这个 dtbo**：`tools/build-kernel.sh` 只编 `overlay/*.dts` 和内核
  `Makefile` 里声明的 M2 内建 overlay（i2c3/i2c7/spi1/uart1/can0-enable 共 5 个；Makefile 里另有两个
  `smarc-*` 条目，被 `build_overlays` 的 M2 正则过滤掉），`usb0-host` 不在其中；
  板上实测该 dtbo 在 `/usr/share/qpi-config/overlays/rk3576-quectel-pi-m2-usb0-host.dtbo`。
  标记文件 `/etc/qpi-config/usb0_host` 存在时由 U-Boot 应用（U-Boot 里是 `qpi_apply_usb0_host`，
  从 rootfs 分区读该 dtbo）。
- overlay 里**没有**删 extcon/usb-role-switch —— dwc3 在 host 分支不消费 extcon，无需处理
  （dtc 1.6.1 也会丢弃 `__overlay__` 内的 `/delete-property/`）。

## 4. 使用

```bash
# 枚举与拓扑
lsusb -t
cat /sys/class/udc/*/state              # USB0 gadget 状态（configured / not-attached）
ls /sys/class/net/ | grep usb           # RNDIS/ACM 网络口
# ADB
adb devices
# 板级/产测
qpi-test --help
```

- 下载/烧录（Maskrom / fastboot / loader）：见 `sdk-flash/SKILL.md`；
  fastboot 阶段默认协商 USB3.0 SuperSpeed。
- RNDIS/ACM：板上已启用（有 `/dev/ttyGS0` 与 `usb0` 网络口）。
  ACM 停止时的端点释放钩子是板上 `/etc/usbdevice.d/acm_stop.sh`：`/usr/bin/usbdevice` 停止 ACM 时
  `fuser -k /dev/ttyGS0` 强释放，否则下次 `usbdevice start` 会占用失败。
- ADB 热插拔自愈：板上 `/usr/local/bin/usb-gadget-watch.sh`
  —— 轮询 `/sys/class/udc/23000000.usb/state`（**不是 dmesg**），poll 0.3s，
  cooldown 20s→3s 自适应；脚本头注释里有 v2→v3 的完整踩坑记录。

## 5. 扩展场景

- **外接 USB 设备**：`qpi-config usb0 host` 重启后 USB0 口可读 U 盘。**必须按 `USB0_PWR_EN` 上电**，
  否则 VBUS 没电、设备枚举不出来（现象：`lsusb` 空、`dmesg` 无 port connect）。
- **三路 USB-A 同时插 U 盘**：HUB 下行 P2/P3/P4（FCT 判定"3 口全部识别 U 盘才通过"）。
  第 4 个 A 口是 USB0，
  要它当 host 必须先 `qpi-config usb0 host`。
- **PCIe 5G HAT 与 USB 机箱条**：PCIe 与 USB1 共用 SerDes（`combphy1_psu`），见 `pcie/SKILL.md`。
- **USB 网卡/RNDIS 上网**：走 HUB 口，无需改 DTS。

## 6. 已知坑（都是实际踩过的）

1. **HUB 不上电** → 先查 `u2phy1_otg` 是否 deferred probe（DTS 里已删 `vbus-supply` 规避）
   和 `GPIO0_A0`（USB1_PWR_EN）电平。
2. **USB0 只能协商到 2.0** → 确认 `&usbdp_phy` / `&usbdp_phy_u3` 被 M2 dtsi 重新 okay
   （common 里为"释放 GPIO4_PC4 给 PCIe1 reset"而 disabled），且 `maximum-speed = "super-speed"`。
3. **热拔插后 ADB 丢失** → `usb-gadget-watch.sh` 处理；v2 用 dmesg 轮询会被 `dmesg -c` 清 ring buffer 搞失效，
   升级 v3 后改用 sysfs `state`。
4. **反向馈电**：peripheral 模式下 VBUS 必须关（`vbus-supply` 由 PHY 管理），
   否则板子通过 USB-A 口给上位机/P C 反送电，表现为上位机侧异常/电流倒灌。
5. **Type-C（J0501）没数据**：它只接 5V 和 CC。想用 Type-C 做数据口是硬件不支持，不是驱动问题。
6. **不要用 `sed` 改 DTS**；USB 相关节点被 common / m2 dtsi 多次覆盖，看全 grep 再改。
