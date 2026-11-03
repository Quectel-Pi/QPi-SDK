---
name: simple-h1-wireless
description: "simple-h1 SDK: QCA1023 SDIO Wi-Fi + UART 蓝牙的预置 ko 选择、使能脚核对、hciattach 上电时序"
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [qualcomm, qcs6490, quectel, simple-h1, wifi, bluetooth, qca1023, sdio, hciattach]
    related_skills: [simple-h1-ethernet, simple-h1-pcie, simple-h1-build]
---

# simple-h1 无线 — QCA1023 SDIO Wi-Fi + HCI UART 蓝牙

## 0. 能力边界

| 部分 | 本 SDK 里能不能改 |
|---|---|
| `wlan.ko`（QCA1023 SDIO 主机驱动） | **源码不在本 SDK**，只有预置 ko；只能换 ko，不能改逻辑 |
| `qca6490.ko` / `cnss2` / `cnss_*` / `icnss2` | 同上，给 SoC 内置 WCN6750 用，本板不用 |
| `quec,rfkill` 使能脚驱动 | **能**：`kernel/drivers/net/wireless/quectel/quec_rfkill.c` |
| SDIO 的 `quec,wifi-en-gpio` 处理 | **能**：`kernel/drivers/mmc/host/sdhci-msm.c`（约 2656 行） |
| 蓝牙 H4 传输 | **能**：`kernel/drivers/bluetooth/hci_qca.c`（`CONFIG_BT_HCIUART_QCA=y`） |
| 固件（BDF / cfg / bin） | 不在本 SDK 里，随镜像走；只能设备侧确认或往 overlay 里放 |

## 1. 硬件事实

| 项 | 值 |
|---|---|
| 模组 | **QCA1023**：Wi-Fi = **SDIO**；蓝牙 = **HCI UART**（H4） |
| Wi-Fi 能力 | 2.4/5 GHz，**802.11a/b/g/n/ac**（Wi-Fi 5） |
| 蓝牙 | **5.0**，强制特性齐全；**不支持** 2 Mbps BLE、扩展广播 |
| 天线 | ①板载 PCB 天线 ②射频同轴座 **`J0101`**（`ECT818000500`） |
| Wi-Fi 供电 | `wifi_3v3_vreg`（tlmm132，3.0V）、`wifi_1v8_vreg`（tlmm130，1.8V） |
| Wi-Fi 使能 | `quec,wifi-en-gpio = <&tlmm 84 GPIO_ACTIVE_HIGH>`（挂在 `&sdhc_1`） |
| BT 使能 | `bt_en-gpios = <&tlmm 85 GPIO_ACTIVE_HIGH>`（`rfkill` 节点） |
| 模组 SW 控制脚 | `sw_ctrl` = **tlmm 86**（pinctrl `bias-pull-down`） |
| BT 串口 | **UART7** → `/dev/ttyHS1`（`serial1 = &uart7`），`max-speed = <3200000>` |
| BT PCM/SCO | 走音频子系统（`btsco-out` 端口） |

DTS（`kernel/arch/arm64/boot/dts/qcom/qcs6490-idp-pi.dts`）：`:39-40`（alias）、
`:345-353`（`rfkill`）、`:1330-1332`（`&wifi` disabled）、`:1353-1355`（`&swr2` disabled）、
`:1382-1399`（Wi-Fi 两路 vreg）、`:1402-1417`（`&sdhc_1`）、`:1452-1457`（`bt_en` pinctrl）、
`:1607-1633`（`&uart7` + `bluetooth`）、`:1654-1664`（`&sdhc_2`）。

**三处最容易误判的点**：

1. `&wifi { status = "disabled"; }`（`:1330`）关的是 **SoC 内置 WCN6750**，
   本板用外挂 QCA1023，**不代表"没有 Wi-Fi"**。
2. `&uart7` 下的 `bluetooth` 是 `qcom,wcn6750-bt` 且 `status = "disabled"`（`:1616`，注释
   `TODO for QCA1023`）——**实际蓝牙不走这个节点**，走 `rfkill` 拉 `bt_en` + `hciattach`。
3. `&swr2` 被禁用是 **让给 PCIe1**（`:1354` 注释 `for PCIE1`），与无线无关。

> **实测 A**（Debian/6.6.52）：`/lib/modules/quectel-wifi/updates/` 为空、`wlan` 未加载，只有 `lo`/`usb0`。
> **实测 B**（qcom-wayland/6.6.116）：`wlan` 已加载，`wlan0`/`p2p0` 都在（SDIO `0271:0701`，驱动 `ar6k_wlan`），
> `rfkill` 里 `phy0` 未 block；`/sys/devices/platform/rfkill/` 的 `bt_en` 属性存在。
> 两镜像都有 `hciattach`/`hciconfig`/`bluetoothctl`。**Wi-Fi 是否已起、ko 在哪个目录，按镜像先查再动手。**

## 2. 预置 ko 怎么选（关键）

| 文件 | `depends` / 匹配 | 用途 |
|---|---|---|
| `overlay/lib/modules/quectel-wifi/updates/wlan.ko` | `cfg80211`，alias `sdio:c*v0271d0001*` | ✅ **QCA1023 SDIO，本板用这个** |
| `overlay/lib/modules/6.6.116-qli-1.7-ver.1.1/updates/wlan.ko` | `icnss2,cfg80211,cnss_nl` | SoC 内置 WCN6750（qcacld），本板**不用** |
| `.../updates/qca6490.ko`、`.../updates/cnss2/cnss2.ko` | `cnss2,cnss_nl,cnss_utils,cnss_prealloc` | 同上，WCN6750 配套 |
| `.../updates/scap.ko` | — | 抓包/诊断辅助，按需 |

两个 `wlan.ko` **模块名都叫 `wlan`**，同一时刻只能加载一个：

```bash
uname -r                                   # 6.6.116-qli-1.7-ver.1.1
modinfo /lib/modules/quectel-wifi/updates/wlan.ko | head    # 看 depends 是否含 cnss
lsmod | grep -E "wlan|cnss|icnss"
```

`/lib/modules/quectel-wifi/` **不是** `uname -r` 目录，`modprobe wlan` 找不到它，
必须 `insmod` 给全路径。

## 3. Wi-Fi

```bash
# 1) 供电/使能由 sdhc_1 完成 (见下), 无需手动拉脚
insmod /lib/modules/quectel-wifi/updates/wlan.ko      # 2) 加载正确的那份
dmesg | tail -40 | grep -iE "wlan|sdio|mmc1|firmware" # 3) 看 SDIO 枚举与固件
ls /sys/class/net/ ; ip -br link                      # 期望 wlan0 (+p2p0)
nmcli radio wifi on                                   # 4) 无线电默认可能是 off
nmcli dev wifi list ifname wlan0
nmcli dev wifi connect "SSID" password "12345678" ifname wlan0
ping -c3 <同网段主机>
```

供电由 `wifi_3v3_vreg`(tlmm132)/`wifi_1v8_vreg`(tlmm130) 负责，使能由 `&sdhc_1` 的
`quec,wifi-en-gpio`(tlmm84) 在 `sdhci-msm.c` 里 request。

**实测现场（同板同镜像）**：`echo 1 > /sys/devices/platform/rfkill/wlan_en` 报 `I/O error`，
dmesg 写 **`rfkill rfkill: wlan_en GPIO not available`** —— DTS 里 `wlan_en-gpios` 那行是
注释掉的（`:350`），`quec_rfkill.c` 的 `devm_gpiod_get_optional(..., "wlan_en", ...)` 拿到 NULL。
**别去写 `rfkill/wlan_en`，也别把该行取消注释**：tlmm84 已归 `&sdhc_1`，
两个 owner 抢同一脚会 `-EBUSY`。Wi-Fi 上电只走 `&sdhc_1` 这一条路径。

若仍无 `wlan0`：`dmesg | grep -i sdio` 看是否枚举到 `0271:0001`，再看固件是否加载失败（`request_firmware` 报错 = 镜像缺 BDF/cfg）。常见路径 `/lib/firmware/wlan_firmware/sdio/`、`/lib/firmware/wlan/qcom_cfg.ini`、`/lib/firmware/bdwlan30.bin`，**先在设备上 `ls` 确认**，本 SDK 不提供这些文件。

## 4. 蓝牙（顺序不能反）

```bash
# 1) 上电（quec_rfkill 暴露的 sysfs）
echo 1 > /sys/devices/platform/rfkill/bt_en
dmesg | tail -3                       # 期望: rfkill rfkill: bt_en has been set to 1
# 2) 串口初始化（H4, 3000000, 流控）
hciattach /dev/ttyHS1 qca 3000000 flow
hciconfig                             # 期望 hci0 UP RUNNING, HCI Version 5.0
# 3) 配对/连接
bluetoothctl
[bluetooth]# scan on ; devices ; scan off
[bluetooth]# pair <MAC> ; trust <MAC> ; connect <MAC>
```

**实测结论**：1→2 走通后 `hci0: Type: Primary Bus: UART, UP RUNNING, BD Address 00:00:00:00:5A:AD, HCI Version: 5.0 (0x9), Name: 'quectelpi'`。`hciconfig hci0 up` 非必需（hciattach 后已 UP）；`bluetooth.service` 默认 inactive 不挡手动流程；中间打印 `EDL_PATCH_VER_REQ_CMD` / `HCI-VS-EVENT` 是正常 QCA 握手。

## 5. 内核侧可改点

| 目标 | 位置 |
|---|---|
| `bt_en` / `wlan_en` sysfs | `kernel/drivers/net/wireless/quectel/quec_rfkill.c` |
| SDIO `quec,wifi-en-gpio` 上电 | `kernel/drivers/mmc/host/sdhci-msm.c`（约 2656 行） |
| BT H4 传输/固件下载 | `kernel/drivers/bluetooth/hci_qca.c` |
| 选项 | `CFG80211=m`、`MAC80211=m`、`RFKILL=m`、`BT_HCIUART=m`、`BT_HCIUART_QCA=y`、`BT_QCA=m` |

改完下发：`./scripts/build-all.sh` 一次到位（`CFG80211`/`MAC80211`/`RFKILL`/`BT_QCA` 都是 `=m`，只换 Image 不带模块没用）

## 6. 已知坑

1. **`wlan.ko` 路径不要写死内核版本号**：用 `/lib/modules/$(uname -r)/...` 或
   `/lib/modules/quectel-wifi/updates/`，写死了换内核就失效。
2. **两个同名 `wlan.ko` 别混**：`insmod` 前 `modinfo` 看 `depends`，依赖 `icnss2/cnss_*`
   的是 WCN6750 版，本板加载会失败或找不到设备。
3. **BT 必须先 `bt_en=1` 再 `hciattach`**，顺序反了会超时。
4. **波特率**：DTS 是 `max-speed = <3200000>`，`hciattach` 示例用 `3000000`；以能起来为准，
   改速度要同时确认 UART 侧能力。
5. **`sw_ctrl`(tlmm86) 默认下拉**，是模组 SW 控制脚，改 pinctrl 前先确认语义。
6. **天线二选一**：接 `J0101` 同轴要确认板上匹配网络（`R0103/R0104`、`NM-ECT818000500`），接错会"能连但速率/距离极差"。
7. **`&sdhc_1` 是 Wi-Fi SDIO，`&sdhc_2` 是 SD 卡座**（`:1654-1664`，`cd-gpios=tlmm91`），
   改一个别动另一个的 pinctrl。
8. **BLE 可选特性不支持**，方案里不要依赖 2 Mbps PHY / 扩展广播。
9. **别拿 `ath11k` 排障**：它是 SoC 内置 WCN6750 的驱动，与 QCA1023 无关。

## 7. 扩展

- **AP 模式 / Wi-Fi Direct**：镜像内有 `hostapd`；`p2p0` 与 `wlan0` 同时出现，扫描可用 `iw dev wlan0 scan`。
- **蓝牙音频 / SPP**：A2DP/SCO 走音频子系统端口；SPP 用 `rfcomm bind`。
- **产测**：`myftm` / `btdiag` / `btconfig` 随镜像，命令以设备上 `--help` 为准。
