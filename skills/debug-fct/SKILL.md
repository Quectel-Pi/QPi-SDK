---
name: debug-fct
description: "Quectel PI M2 调试与产测：DBG 调试串口（console=ttyFIQ0）、下载/烧录模式、ADB、port_bridge AT 指令全集、板级自测 qpi-test 与配置 qpi-config 子命令、FCT 产测流程、常用诊断命令与坑。当用户说「M2 串口没输出」「进下载模式」「ADB 连不上」「AT 指令怎么发」「跑 qpi-test」「FCT 测试」「产测」时使用。WHEN: M2 debug, DBG UART, download mode, adb, AT command, port_bridge, qpi-test, qpi-config, FCT, 串口, 产测. DO NOT USE FOR: 烧录固件的完整流程（用 sdk-flash），编译（用 sdk-build）。"
license: MIT
metadata:
  author: Quectel PI M2 外设 SKILL 库
  version: "1.0.0"
  board: Quectel PI M2 (RK3576 / QSM610ZAP-WF)
---

# M2 调试 / 产测 SKILL — 串口、下载模式、ADB、AT 指令、FCT

适用：Quectel PI M2（`quectel,pi-m2-rk3576`）。烧录细节见 `sdk-flash/SKILL.md`，构建见 `sdk-build/SKILL.md`。

## 1. 调试串口（DBG UART）

| 项 | 值 |
|---|---|
| 连接器 | **J1502**（1×3Pin，2.54mm，C254VD103G01B1PH） |
| 信号 | pin1 = `DBG_RX_3V3`、pin3 = `DBG_TX_3V3`、pin2 = GND（经 U1501 电平转换成 3.3V/0V） |
| 模组侧 | `DBG_RX/TX`（模组 pin 45/46，1V8） |
| 内核 console | **`ttyFIQ0`**，`bootargs` 里 `earlycon=uart8250,mmio32,0x2ad40000 console=ttyFIQ0`（`rk3576-linux.dtsi`） |
| 波特率 | 板上实测 `stty -F /dev/ttyFIQ0` = **115200**；DTS 里没有 1500000 覆盖。**先用 115200，若无输出再试 1500000** |

```bash
# 主机侧
picocom -b 115200 /dev/ttyUSB0     # 或 minicom -D /dev/ttyUSB0 -b 115200
# 板侧
cat /proc/cmdline
cat /sys/class/tty/ttyFIQ0/../console/ 2>/dev/null
dmesg | head
```

- U-Boot 阶段也能进 console（`CONFIG_QPI_CONFIG_OVERLAY=y` —— U-Boot 负责应用 qpi-config 的 dtbo）。
- **⚠️ 别把 DBG UART 和 BT UART 搞混**：BT 在 **UART4 = `/dev/ttyS4`**（`bt-tty` 可查），
  排针 J1502 才是 console。

## 2. 下载 / 烧录模式

| 模式 | 进入方式 | 用途 |
|---|---|---|
| **MASKROM** | 断电 → 按住 Reset（或 MASKROM 测试点 TP0402，模组 pin9）→ 插 USB → 2-3s 后松手 | 无 Loader 时；`upgrade_tool DB MiniLoaderAll.bin` |
| **Loader** | 已有 Loader 时；或已启动系统 `adb reboot loader` | 直接 `upgrade_tool UF update.img` |
| **fastboot** | `reboot fastboot` | fastboot 阶段默认协商 USB3.0 SuperSpeed |
| **recovery** | `adb reboot recovery`；分区表里有 recovery 分区（见 `sdk-flash/SKILL.md`） | OTA 救援 |

```bash
# 本仓库烧录走 Rockchip rockusb：工具随 SDK 分发在 tools/flash/（VERSION.txt 的 FLASH_TOOLS_*）
tools/flash/linux/upgrade_tool LD          # 列出 Loader/MASKROM 设备
tools/flash/linux/upgrade_tool UF update.img   # 整包烧（需已有 Loader）
tools/flash/linux/upgrade_tool DB prebuilds/base_image/MiniLoaderAll.bin   # MASKROM 下先下 Loader
```

**硬件进 MASKROM 的按键**（网表核对）：模组 pin9 = `MASKROM`（测试点 TP0402）、
pin12 = `RESET_N`（TP0201）、pin7 = `PON`（S0402 拨动开关）、pin8 = `PWRKEY`（S0403 轻触）。

## 3. ADB

```bash
adb devices ; adb shell ; adb reboot [loader|fastboot|recovery]
adb push <file> /data/local/tmp/       # 只改内核/DTS 时用 boot.img 热替换，见 sdk-flash/SKILL.md
```

- 依赖 USB0（默认 `dr_mode = "peripheral"`）—— 若执行过 `qpi-config usb0 host`，
  **ADB 会消失**，先 `qpi-config usb0 peripheral` 再重启。
- ACM 端点占用/释放：板上 `/etc/usbdevice.d/acm_stop.sh`（`/usr/bin/usbdevice` 停止 ACM 时执行）。
- 热插拔自愈看门狗：板上 `/usr/local/bin/usb-gadget-watch.sh`（日志 `/var/log/usb-gadget-watch.log`）。
- AT 指令 `AT+QUSBADB` / `AT+QUSBHOST` 可切换 USB 模式。

## 4. AT 指令（port_bridge）

程序：板上 `/usr/bin/port_bridge`（AT 通道 + FCT），AT 落在 `/dev/ttyGS0`；源码不随本仓库。

支持的指令（源码里 grep 得到的全集）：

```
+QGMR  +EGMR  +QCSN  +MAC   +QMAC  +QCFG  +QDEVINFO  +QPRTPARA
+QNVR  +QNVW  +QDATA  +QAPCMD  +QAPSUB  +QUSBADB  +QUSBHOST
+QFCT  +QAPCMD
+FCT 各项： +LED  +FAN  +FANON  +FANOFF  +SPK  +DMIC  +HEADSET  +CAMERA
           +HDMI  +LCD  +ETHERNET  +SDCARD  +RTC  +KEYSET
           +40PINLEDON  +40PINLEDOFF  +40PINREUSE
+SLEEP  +POWEROFF
```

用法举例：

```bash
# 有线/串口 AT 通道（Debian 上 port_bridge 提供）
AT+QGMR            # 版本（曾修过"返回值多出V01"）
AT+EGMR=...        # SN 读写：index 5 保留，index 6 = 独立 PCBA SN
AT+MAC=?           # +MAC: (1,2)  1=Wi-Fi 2=BT
AT+QMAC=1          # 读写 Wi-Fi MAC
AT+QUSBADB / AT+QUSBHOST    # USB 模式切换
AT+CAMERA          # 双路摄像头二维码识别产测
AT+QFCT=...        # 射频 FCT（Wi-Fi TX/RX、BT TX/RX、BLE RX）
AT+LED=1 / AT+FAN  # LED/风扇产测（见 led/SKILL.md / fan-thermal/SKILL.md）
AT+HDMI            # 检查 /sys/class/drm/card0-HDMI-A-1/status == connected 后 modetest -M rockchip -s @:720x1280@RG60
AT+SPK             # 先查 /proc/asound/cards 里有 es8389，再 aplay -D hw:0,0 /tmp/dmic.wav|/tmp/hs_loop.wav
AT+SLEEP / AT+POWEROFF
AT+40PINLEDON / OFF / +40PINREUSE   # 40Pin 状态 LED
```

**FCT 内部判定用到的 sysfs/proc（写脚本时直接照抄）**：

| 项 | 判定命令 |
|---|---|
| HDMI | `cat /sys/class/drm/card0-HDMI-A-1/status \| grep -qw connected` |
| LCD | `i2cdetect -y -r 0`，地址 `0x14`（触摸/exciter 控制器）显示 `UU`；**DSI-1 的 status 永远 connected，不能用** |
| 风扇 | `test -e /sys/class/hwmon/hwmon6/pwm1_enable` |
| 喇叭 | `grep -q es8389 /proc/asound/cards` |
| 麦克风路由 | `amixer -c 0 cset name='PGAL Select' 'DifferentialL'(耳麦) 或 'Line 2P'(板载)` |
| LED | 导出 pwm chip 的 `pwm0`，写 period→polarity→duty_cycle→enable（顺序不能反） |

## 5. 板级自测工具 `qpi-test`

```bash
qpi-test --help
qpi-test camera {on|off|shot|view|play|mp4} [0|1]   # 0=Camera1(J1002/CSI0) 1=Camera2(J1001/CSI3)
qpi-test display {backlight|mode}                   # M2 用 /sys/class/backlight/0-0045
qpi-test audio {headset|speaker}                    # 录音+回放
```
- 板型自动识别：脚本按 `compatible` 选 `/sys/class/backlight/0-0045`。
- 相机预览会自己找 Wayland socket（`/run/user/*/wayland-0`）并设
  `GST_V4L2_FORCE_LIBV4L2=0`。
- 二进制位置（板上）：`/usr/bin/qpi-test`；`qpi-config` 在 `/usr/sbin/qpi-config`。源码不随本仓库。

## 6. 板级配置工具 `qpi-config`

```bash
qpi-config {i2c3|i2c7|spi1|uart1} {enable|disable}   # 40Pin 功能开关，重启生效（只有这四个）
qpi-config usb0 {host|peripheral}                          # 重启生效
qpi-config wifi {scan|connect <ssid> [passwd]|show|remove <id|ssid>}
qpi-config dump {temperature|systemusage}
qpi-config serial_login {on|off|status}                    # 只管 ttyFIQ0 登录，不管内核日志
qpi-config switch {gnome|weston}                           # 下次启动的桌面，重启生效
```
板型靠 `/proc/device-tree/compatible` 判断（`*pi-m2*` → M2 分支）。脚本在板上 `/usr/sbin/qpi-config`，源码不随本仓库。

## 7. 其它常用诊断

```bash
# 版本
cat /etc/quectel-release
qpi-config dump temperature ; qpi-config dump systemusage
# 内核/驱动
uname -r ; dmesg | grep -iE "error|fail|timeout"
cat /sys/kernel/debug/dri/0/summary       # 显示
# 内核日志限制（安全加固后普通用户读不到）
cat /proc/sys/kernel/dmesg_restrict       # =1 时需 root
```

## 8. 已知坑

1. **别把 BT 串口当 console**：BT = `/dev/ttyS4`（pinmap 的 BT_UART4），console = `ttyFIQ0`。
2. **`qpi-config usb0 host` 之后 ADB 没了** —— reboot 前记得改回 peripheral。
3. **`upgrade_tool EF` 会毁掉 update_bak 黄金包**，量产机器上禁用。
4. **`dmesg` 读不到**：rootfs 安全加固设了 `kernel.dmesg_restrict=1`；用 root 或 `sudo dmesg`。
5. **`AT` 回显格式**：ERROR 路径不要带响应体（自己加指令时照此实现）。
6. **产测结果持久化**：FCT 结果写文件（`fct_record()`），改产测逻辑时保持这个行为，
   否则产线拿不到结果。
7. **调试口是 1V8 转 3V3**（U1501），不要直接接 5V TTL。
