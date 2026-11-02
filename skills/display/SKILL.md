---
name: display
description: "Quectel PI M2 显示：MIPI-DSI 屏适配标准流程（panel 节点、触摸 gt911、背光）、RK3576 原生 HDMI、显示链路 DTS 位置、无输出/花屏/触摸不通排查。当用户说「M2 换屏」「适配 DSI 屏」「M2 触摸不通」「HDMI 无输出」「M2 花屏」「背光不亮」「display DTS 怎么改」时使用。WHEN: M2 display, MIPI DSI panel bringup, touch gt911, backlight, HDMI no output, display DTS, 换屏, 触摸, 屏幕不亮. DO NOT USE FOR: 摄像头（用 camera），设备树 overlay 打包（用 sdk-overlays），整机编译（用 sdk-build）。"
license: MIT
metadata:
  author: Quectel PI M2 外设 SKILL 库
  version: "1.0.0"
  board: Quectel PI M2 (RK3576 / QSM610ZAP-WF)
---

# M2 显示 SKILL — MIPI-DSI 屏适配 + 触摸 + HDMI

适用：Quectel PI M2（`quectel,pi-m2-rk3576`）。M2 **没有 DP/eDP**，只有 DSI 和原生 HDMI。

## 1. 硬件事实

### DSI / LCM（J1201，22Pin 0.5mm A050102213M011ARA）

| LCM 连接器 pin | 信号 | 来源 / 说明 |
|---|---|---|
| 2/3, 5/6, 11/12, 14/15 | DSI LN0..LN3 差对 | 模组 DSI_TX_D0..D3（M2 引出 4 lane） |
| 8/9 | DSI CLK 差对 | DSI_TX_CLKP/N |
| 17 | LCM_RST | ← `TP_RST_1V8`（模组 pin21）经 U1203 电平转换（1V8↔3V3）+ R1215 |
| 18 | LCM_INT | ← `TP_INT_1V8`（模组 pin22）经 U1203 + R1204 |
| 20/21 | TP_I2C_SCL/SDA | ← `TP_I2C0_*_1V8`（模组 pin23/24）经 U1203 → 3V3 侧 |
| 22 | VDD_3V3_LCM | 3.3V，由 `LCM_PEN` 负载开关控制 |

- **LCM 3V3 使能 = `LCM_PEN_1V8`，模组 pin235 = `GPIO3_C5`**（输出高上电）。
- DSI 数据线与电源开关之间串了 ESD/共模器件；网表上 DSI 走 `R120x` 串联电阻 → U120x → 连接器。
- 触摸与 LCM **同一连接器、同一 I2C0**；触摸地址写在 DTS 里：8 寸 C = `gt911@14`，
  4.3 寸 A = `gt911@5d`（`dsi-panel-waveshare-auto-m2.dtsi`）。本板实测 `i2cdetect -y 0` 见
  `0x14`(触摸) 与 `0x45`(背光) 均为 `UU`。

### HDMI（J1401，Type-A MUP-H21602-02）

- **RK3576 原生 HDMI TX**，载板上没有独立 HDMI PHY 桥接芯片。
- `HDMI_TX_ON_H` = `GPIO4_C6`：HDMI 外部匹配使能，**工作在 2.0 以下可不控制**。
- HPD（`HDMI_DET`/`HDMI_TX_HPDIN`）模组 pin188，外部已上拉，**低电平=已插入**。
- 专用 I2C/DDC：`HDMI_TX_SCL/SDA`（模组 pin272/271），经 Q1406 等 MOS/电平网络。
- CEC：`HDMI_TX_CEC`（模组 pin273）。

## 2. DTS 位置与结构

```
rk3576-quectel-pi-m2-linux.dtsi
├── #include "display/dsi-panel-waveshare-auto-m2.dtsi"   ← 8寸 C + 4.3寸 A 双 profile（含触摸 I2C0 + 背光）
└── #include "display/rk3576-hdmi-m2.dtsi"                ← 原生 HDMI
```

- `dsi-panel-waveshare-auto-m2.dtsi` 内部 **#include 了两个 panel profile**（`dsi-panel-waveshare-8inch-c-m2.dtsi`
  与 `dsi-panel-waveshare-4.3inch-a-m2.dtsi`），并按触摸地址选型（Goodix `0x14` = 8 寸 C、`0x5d` = 4.3 寸 A）；
  include 一个 profile 不等于点亮那块屏。
- 它还把 `&m2_dsi_panel` 的 `compatible` 覆盖成 `waveshare,m2-auto-panel`、`&m2_ws_backlight` 覆盖成
  `waveshare,m2-auto-backlight`（一个背光设备、两种 MCU 协议），并 `&route_dsi { status = "okay"; }`。

- `&display_subsystem` / `&vp0`：**两个文件都会动**，HDMI 文件把 `&vp0` 与 `&hdmi_in_vp0` 置 okay、
  `&hdmi_in_vp1`/`&hdmi_in_vp2` disabled；common 里 `&vp0 = disabled`、`&vp1 = okay`。
  改显示要同时看这三处，否则屏不出图。
- `&dsi` 下的 `m2_dsi_panel: panel@0`：8 寸 profile 里定义成 `compatible = "waveshare,dsi-lcd-c"`，
  电源 `<&m2_lcm_3v3>`（`GPIO3_C5`）、背光 `<&m2_ws_backlight>`、`dsi,lanes = <2>`；
  auto 文件再把 `compatible` 覆盖为 `waveshare,m2-auto-panel`。
- `route_dp0` / `&dp` / `&dp0` / `&edp` / `&hdptxphy`（非 HDMI 那个）在 M2 全部 disabled，
  `&dp0_sound` 由 M2 dtsi 显式设为 `disabled`（`rk3576-quectel-pi-m2-linux.dtsi:475-477`）。
  这条要留着：common 链里的 `usb/rk3576-usb_dp.dtsi`（USB-C DP Alt Mode）会把
  `&dp0` / `&dp0_in_vp2` / `&dp0_sound` 都设成 okay，M2 靠这一处覆盖关回来，否则会多一张绑在
  已 disabled 的 dp0 上的声卡。不要据此认为有 DP 音频可用。

## 3. 适配一块新 DSI 屏（标准流程）

1. **抄一份 panel dtsi**：`display/dsi-panel-waveshare-8inch-c-m2.dtsi` → 新文件名（**不要改原件**）。
   当前生效的是 `dsi-panel-waveshare-auto-m2.dtsi`（两个 profile 都 include 进来），换屏时先确认
   U-Boot/内核按哪个触摸地址选型，别只改 profile 文件里的 panel 节点。
2. **改 panel 节点**：`compatible`、`dsi,lanes`、`dsi,format`、`bpc`、`width-mm/height-mm`、
   timing（`rockchip,panel-init-sequence` 或 `display-timings`）、各 `*-delay-ms`。
3. **改背光**：M2 的 8 寸屏背光是 **I2C 背光芯片挂在连接器 I2C 通路**（`waveshare-bl@45`，
   sysfs `/sys/class/backlight/0-0045`，`qpi-test display backlight` 就写这个节点）。
   新屏若是 PWM 背光，需要改到 `pwmX` 背光节点并确认 40Pin/LCM 上是否有该脚。
4. **确认电源**：仍用 `m2_lcm_3v3`（`GPIO3_C5`）；若新屏需要不同上电时序，改 `*-delay-ms`。
5. **确认触摸**：触摸 I2C 保持 `i2c0`；`TP_RST`/`TP_INT` 的 GPIO 映射 DTS 注释里标为"待 M2 资料确认"，
   实际硬件映射是：
   - LCM_RST（连接器 pin17）↔ `TP_RST_1V8`（模组 pin21）
   - LCM_INT（连接器 pin18）↔ `TP_INT_1V8`（模组 pin22）
   落地时按 `GPIO3_C?`/对应 pin 的 pinctrl 填 `reset-gpios` / `irq-gpios`，并实测中断。
6. **编译验证**：
   ```bash
   ./build.sh kernel      # 只编内核 + dtb
   ./build.sh all         # 全量（内核 + FIT boot.img + overlays + update.img）
   ```
7. **上板验证**（无 GUI 也能看到）：
   ```bash
   cat /sys/class/drm/card0-DSI-1/status      # connected / enabled
   cat /sys/class/drm/card0-DSI-1/modes | head -1
   grep -E "Connector:|Display mode:" /sys/kernel/debug/dri/0/summary
   # 背光
   ls /sys/class/backlight/ ; echo 200 > /sys/class/backlight/0-0045/brightness
   ```

## 4. 使用（板级/应用层）

```bash
# 板级自测（板型自动识别 M2 用 /sys/class/backlight/0-0045）
qpi-test display backlight      # 背光 50→200 扫一遍
qpi-test display mode           # 打印 HDMI-A-1 / DSI-1 的分辨率与 fps
```

- Debian 侧显示栈：**GNOME on Wayland**（Xorg 被 stub）；GPU 在 trixie 上用 Panfrost（见 `sdk-build/SKILL.md`）。
- HDMI 音频走 ALSA `rockchip-hdmi1` UCM，见 `audio/SKILL.md`；`&hdmi_sound` 为 `okay`，
  `aplay -l` 应能看到 `card N: rockchiphdmi`（未插 HDMI 屏时卡存在，只是没有 sink 输出）。
- U-Boot/Kernel logo：`route_hdmi` 里 `logo,uboot = "quectel_720p.bmp"`、
  `logo,kernel = "quectel_720p_kernel.bmp"`；换 logo 改这里 + 对应 bmp 资源。

## 5. 扩展场景

- **双屏同显/异显**：DSI 挂 `&vp1`、HDMI 挂 `&vp0`（当前配置）；若要异显需确认 VP 分配不冲突，
  并注意 `&vp0` 被 HDMI 文件置 okay、common 里置 disabled 的覆盖顺序。
- **HDMI 输出到采集卡/低分辨率屏**：见"坑"第 3 条。
- **DSI 转 LVDS/转 eDP 桥**：M2 的 LVDS/eDP 桥不在载板上；要么接在 DSI 上（自备桥芯片 DTS），
  要么走 40Pin。`mipi_lvds` 这类 MUX 在本板上**不存在**，别照抄。

## 6. 已知坑（硬件核对 + 实测）

1. **HDMI 接低分辨率屏（如 1024x600）进系统黑屏** — 已修。
   遇到"U-Boot 有 logo、进系统黑屏"先查这条。
2. **HDMI 眼图/信号完整性** — 与 `rockchip,sda-falling-delay-ns`、`ddc-i2c-scl-high-time-ns`、`ddc-i2c-scl-low-time-ns` 三个参数有关，改前先看当前值（`display/rk3576-hdmi-m2.dtsi`）。
3. **LCM 电源没开 → 屏白/不亮**：`m2_lcm_3v3` 的 `GPIO3_C5` 若被其它功能占用（它是复用脚），
   或整版 3V3（`GPIO4_A7`/DCDC_EN_3V3）没上，LCM 也不会亮。先量电，再看 DTS。
4. **不要用 `sed` 改 DTS**；用 `read_file` 定位 → `patch` 精确改 → `git diff` 复核（项目铁律）。
5. **同一块屏在另一块板上的 dtsi（`display/dsi-panel-waveshare-8inch-c.dtsi`，本仓库也有）不能直接给 M2 用**，
   电源/背光/触摸引脚不同，M2 专用文件是 `-m2` 后缀那份。
