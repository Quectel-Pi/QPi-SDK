---
name: wireless
description: "Quectel PI M2 无线：FCS960KBAAMD（AIC8800）SDIO Wi-Fi + 蓝牙 UART4 四线 + PCM，模块电源使能与唤醒 GPIO 保活、天线连接器、qpi-config wifi 连接、休眠后掉线排查、FCT 射频测试、aic8800 外置 .ko 加载。当用户说「M2 Wi-Fi 起不来」「蓝牙连不上」「休眠后掉网」「FCT 射频测试」「wifi 连不上」「aircraft」时使用。WHEN: M2 wireless, FCS960K, AIC8800, SDIO wifi, BT UART4, bluetooth, RF test, 无线, 蓝牙, 掉线. DO NOT USE FOR: 有线网口（用 ethernet），高通板无线（用 quectel-yocto-bsp）。"
license: MIT
metadata:
  author: Quectel PI M2 外设 SKILL 库
  version: "1.0.0"
  board: Quectel PI M2 (RK3576 / QSM610ZAP-WF)
---

# M2 无线 SKILL — FCS960K (AIC8800) Wi-Fi SDIO + 蓝牙 UART4

适用：Quectel PI M2（`quectel,pi-m2-rk3576`）。模组型号：**FCS960KBAAMD**（U1702，QUECTEL），
芯片方案 AIC8800 SDIO（Wi-Fi）+ UART（BT）。天线：**J1702 = Wi-Fi/BT**、**J1701 = BT 独立**。

## 1. 硬件事实

| 信号 | 模组 pin | GPIO 宏 | 方向/说明 |
|---|---|---|---|
| WLAN_SDIO_CLK/CMD/D0..D3 | 133/132/128..131 | SDMMC1 M0 | Wi-Fi 数据（`sdmmc1m0_*`） |
| WIFI_BT_PWR_EN_3V3 | 360 | `GPIO3_A3` | 出：Wi-Fi/BT **模组电源使能**，高=开 |
| WMOB_PWRKEY_WIFI_EN_3V3 | 301 | `GPIO2_B3` | 出：模组**开机脚**，高=开机（**需在 PWR_EN 拉高之后**再拉） |
| WMOB_BT_EN_3V3 | 208 | `GPIO2_C0` | 出：BT 使能（pinmap 注"仅 FC905A 模组使用"，FCS960K 不用） |
| WLAN_WAKE_HOST_1V8 | 41 | `GPIO0_D3` | 入：WLAN 唤醒主机（`WIFI,host_wake_irq`） |
| HOST_WAKE_WLAN_1V8 | 282 | `GPIO4_A0` | 出：主机唤醒 WLAN |
| BT_WAKE_HOST_1V8 | 13 | `GPIO1_C6` | 入：BT 唤醒主机（高/上升沿中断） |
| HOST_WAKE_BT_1V8 | 14 | `GPIO1_C7` | 出：主机唤醒 BT |
| WIFI_32K_OUT_1V8 | 380 | — | 出：32K 时钟（pinmap 注"仅 FC905A 使用"） |
| BT UART4 | 230/229/227/228 | `GPIO1_C5/C4/C2/C3` | BT_UART4_RXD/TXD/RTS/CTS（M1 复用，四线流控） |
| BT PCM (SAI2) | 231..234 | — | PCM_CLK / SYNC / DIN / DOUT |
| Wi-Fi/BT USB（保留） | — | U0601 pin21/22 → U1704 | **U1704 未贴片（NM）**，不要引用 |
| 调试脚 | 29/30 | — | `WIFI_BT_DBG_TXD/RXD_1V8` 测试点 |

> **唤醒脚方向注意**：按网表命名，pin13 `UART2_TXD` = `BT_WAKE_HOST_1V8`（BT→主机，SoC 输入）、
> pin14 `UART2_RXD` = `HOST_WAKE_BT_1V8`（主机→BT，SoC 输出）。
> 基线 `rk3576_M.2_wifibt.dtsi` 里 `BT,wake_gpio`/`BT,wake_host_irq` 两行是**注释掉的**，
> 且注释里标的 `GPIO1_C7`/`GPIO1_C6` 与上述方向**相反**。要启用唤醒时以网表/pinmap 为准并上板实测，
> 不要直接抄注释。

## 2. DTS 覆盖（M2 相对基线的全部差异）

基线：`M.2_external/rk3576_M.2_wifibt.dtsi`（`&sdio` = **SDMMC1 M0**，`wifi_chip_type = "rtl8821cs"`，
BT `/dev/ttyS4`，`BT,reset_gpio = GPIO0_B1`，`uart_rts_gpios = GPIO1_C2`）。

M2 在 `rk3576-quectel-pi-m2-linux.dtsi` 里改：

```dts
&sdio_pwrseq { /delete-property/ reset-gpios; };   /* GPIO2_B3 是 PWRKEY 不是 SDIO reset */

&wireless_wlan {
    wifi_chip_type = "aic8800";                     /* ← 换芯片方案的关键一行 */
    pinctrl-0 = <&wifi_host_wake_irq &wifi_vbat_gpio>;
    WIFI,vbat_gpio    = <&gpio3 RK_PA3 GPIO_ACTIVE_HIGH>;  /* 模组电源使能 */
    WIFI,poweren_gpio = <&gpio2 RK_PB3 GPIO_ACTIVE_HIGH>;  /* PWRKEY/WLAN_EN */
    wakeup-source;
};

&wireless_bluetooth {
    /delete-property/ clock-names;
    /delete-property/ BT,reset_gpio;                /* 无独立 BT reset */
    /delete-property/ uart_rts_gpios;               /* 让给 uart4 做硬件流控 */
    /delete-property/ pinctrl-names; /delete-property/ pinctrl-0; /delete-property/ pinctrl-1;
    wakeup-source;
};

&uart4 { pinctrl-0 = <&uart4m1_xfer &uart4m1_ctsn &uart4m1_rtsn>; };   /* 补齐四线 RTS */

&wifi_poweren_gpio { rockchip,pins = <2 RK_PB3 RK_FUNC_GPIO &pcfg_output_high_pull_up>; };
&pinctrl { wireless-wlan { wifi_vbat_gpio: wifi-vbat-gpio {
    rockchip,pins = <3 RK_PA3 RK_FUNC_GPIO &pcfg_output_high_pull_up>; }; }; };
```

**为什么 BT 的 `uart_rts_gpios` 必须删掉**（dtsi 注释里写得很清楚，值得记住）：
AIC8800 的 BT 上电由 `aicbsp` 经 `WIFI,poweren_gpio`(GPIO2_B3) 控制，
不依赖 `rfkill-bt` 的 uart_rts 上电脉冲（实测该脉冲在蓝牙正常工作时从未发出）。
若保留，`rfkill-bt` 与 `&uart4` 会**同时申请 pin-50**，probe 失败并报
`pin gpio1-18 already requested by 2ad70000.serial`。

## 3. 使用

```bash
# Wi-Fi（Debian，nmcli 后端）
qpi-config wifi scan
qpi-config wifi connect <SSID> [passwd]
qpi-config wifi show
qpi-config wifi remove <id|ssid>
nmcli device status ; iw dev wlan0 link

# 蓝牙
bt-tty                 # 输出 BT 所在串口（M2 = /dev/ttyS4，由设备树 pinctrl 名反推）
hciconfig -a ; bluetoothctl
systemctl status fcs960k.service
rfkill list            # 看 bluetooth rfkill 是否 soft-block
```

### ★ 上板实测（2026-10-10，Debian 13.7 / 内核 `6.1.118-rt36`）

**M2 的 Wi-Fi 是能用的**（以下均为板上实测）：

| 项 | 实测 |
|---|---|
| 驱动/接口 | `aic8800_bsp`+`aic8800_fdrv` 已加载；`wlan0` 存在，MAC **`74:07:7e:c7:45:4e`**（另有 `p2p-dev-wlan0`） |
| rfkill | `phy0 Wireless LAN`：soft/hard 均 not blocked |
| **扫描** | ✅ `qpi-config wifi scan` 与 `nmcli dev wifi list ifname wlan0` 都能用，**实测扫到 24 个 AP** |
| **关联** | ✅ 实测发起连接后 dmesg：`rwnx_send_sm_connect_req … connect to <SSID> … auth_type:0` → `rwnx_rx_sm_connect_ind status_code:0` → `cfg80211_connect_result pass`（**L2 关联成功**） |
| DHCP | ⚠️ 测试用的开放 SSID 在关联后被 AP 断开（见下），所以没走到取 IP 那步 |
| 蓝牙 | ✅ `hci0` `Type: Primary Bus: UART`、**UP RUNNING**、BD Address `74:07:7E:C7:3D:78`、Name 'linaro-alip'；`bt-tty` → **`/dev/ttyS4`**；`fcs960k.service` active+enabled；`bluetooth.service` running |
| 其他 | ⚠️ `NetworkManager-wait-online.service` 是 **masked**（开机不等网络就绪，排查"开机没网"时记得这条） |

#### ⚠️ 坑：`qpi-config wifi connect <ssid>`（不给密码时）**不是**"连开放网络"

看 `/usr/sbin/qpi-config` 的实现（`cmd_wifi_connect`）：**有密码**才走
`nmcli device wifi connect <ssid> password <pwd> ifname wlan0`；
**不给密码**走的是 **`nmcli connection up id <ssid>`** —— 即"把 `<ssid>` 当成**已保存的连接**拉起"。
所以对一个从没连过的开放网络执行 `qpi-config wifi connect Quectel-Internal`，会直接报
`Error: unknown connection 'Quectel-Internal'.`（**不是**网络连不上）。

**开放网络正确连法**（两条任选）：
```bash
# ① 先用 nmcli 建一个连接，再 up
nmcli connection add type wifi con-name QPI-Open ifname wlan0 ssid <SSID>
nmcli connection up QPI-Open
# ② 或直接让 nmcli 去连
nmcli dev wifi connect "<SSID>" ifname wlan0
# 用完清理
nmcli connection delete QPI-Open
```

#### ⚠️ 现象：关联成功后被 AP 断开（`reason code:23`）

实测连某个"扫描里显示开放"的企业 SSID 时，dmesg 出现：
```
rwnx_rx_sm_connect_ind ind->status_code:0 → cfg80211_connect_result pass   （关联成功）
rwnx_rx_sm_disconnect_ind reason code:23
rwnx_cfg80211_unlink_bss(): cfg80211_unlink error <SSID>!!
```
**`reason 23` = 802.1X 认证失败** —— 是 **AP 侧拒绝**（该 SSID 虽然对外显示开放，实际要 802.1X/门户认证），
**不是板子/驱动问题**。判断依据：`connect_result pass` 在前（L2 通了），断在 802.1X 阶段。
换一个真正能加入的网络（有凭据的 WPA2 SSID）即可走到 DHCP 与 ping。

### 应用层/服务

- **`fcs960k.service`**（`/usr/bin/fcs960k-init.sh`）：`DefaultDependencies=no`，
  `After=local-fs.target`，`Before=network.target bluetooth.target bluetooth.service`。
  脚本里有 `bt_rfkill_wait_unblocked()` —— 因为 **rfkill 状态同步是异步的**（内核→bluetoothd→soft-block），
  hci0 刚 attach 时节点可能仍 blocked，直接 `hciconfig up` 会报
  `Operation not possible due to RF-kill (132)`。排查启动失败先看这里。
- **休眠钩子**：`fcs960k-sleep-hook.sh` 在 suspend/resume 时 **exit 0 什么都不做**，
  目的是"保持 FCS960K 供电与驱动绑定跨过 suspend"；AIC SDIO 驱动自己 in-place resume。
  配合 `power-pm/SKILL.md` 里 `rockchip,power-ctrl` 的三条 GPIO 保活。
- **固件/驱动**：`external/rkwifibt/drivers/aic8800_sdio/`（`aic8800_bsp` / `aic8800_fdrv` / `aic8800_btlpm`）。
  升级：同步替换驱动与 `firmware/` 下的固件（当前版本 2026_0509_2195ae36）。
- **bluez / hciattach**：板上 `/usr/bin/hciattach` 可用（bluez 5.77），`hci0` 实测 `Type: Primary Bus: UART`、`UP RUNNING`。

### FCT 射频测试 / AT

```bash
# 通过 port_bridge 的 AT 通道（见 debug-fct/SKILL.md）
AT+QFCT=...        # FCT 射频测试（Wi-Fi TX/RX、BT TX/RX、BLE RX）
AT+MAC=?           # 读 Wi-Fi/BT MAC：+MAC: (1,2)  （1=Wi-Fi, 2=BT）
AT+QMAC=1 / =2     # 设置/读取 Wi-Fi / BT MAC
```

## 4. 扩展场景

- **Wi-Fi 休眠唤醒**：`rockchip_suspend` 的 `wakeup-config` 需含 `RKPM_GPIO_WKUP_EN`；
  `rockchip,power-ctrl` 必须保 `GPIO4_A7`(DCDC_EN_3V3) / `GPIO3_A3` / `GPIO2_B3` 三条
  —— 实测 S3 时 `GPIO4_A7` 会掉，直接切断 U0509 → FCS960K VBAT。详见电源分册。
- **BT 高速数传**：L2CAP MTU 已从 672 提到 1009，UART 提到 3.25 Mbaud。
- **独立天线模式**：把 `BTMODE` 从 `COANT` 改为 `BT_ONLY`（用 J1701）。
- **BT 音频**：走 SAI2 PCM，见 `audio/SKILL.md`。
- **GNOME 蓝牙弹窗/通知**：blueman 通知对话框开关由 dconf（`00-bluez`）控制。
- **Wi-Fi SDIO 卡移除机制**：`&sdio` 有 `logic-remove-card` —— 反复 `insmod`/`rmmod` aic8800 前先确认它，否则会 oops/死锁。

## 5. 已知坑

1. **上电时序**：`WIFI_BT_PWR_EN_3V3`(GPIO3_A3) 必须先拉高，再拉 `WMOB_PWRKEY_WIFI_EN_3V3`(GPIO2_B3)。
   pinmap 明确"需要在 PWRKEY 拉高后再拉高（时序要求）"。反了会起不来。
2. **`GPIO3_A3` 同时是整版 3V3 的消费者**：`DCDC_EN_3V3`(GPIO4_A7) 没开，U0509 IN 就没电，
   FCS960K VBAT 也没有。见电源分册。
3. **CVE 合入曾打断蓝牙** —— 打完安全补丁后一定要回归 BT 节点。
4. **`bt-tty` 不要写死 ttyS 号**：它从 `/sys/firmware/devicetree/base/pinctrl/wireless-bluetooth`
   的 `uartN` 推导；改 UART 复用后不用改脚本，但**要保证 pinctrl 目录名仍是 `uart4`**。
5. **不要照抄另一块板的无线配置**：那块板用 USB 接口的模组，没有 SDIO/UART4 这套。
