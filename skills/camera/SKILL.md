---
name: camera
description: "Quectel PI M2 双 MIPI-CSI 摄像头适配与使用：CSI0/CSI3 连接器与 I2C 总线、IMX219/IMX477/S5K3L6B/S5K3P9B 适配步骤、v4l2 出图、产测二维码识别。当用户说「M2 接摄像头」「双击不识别」「CSI 出图全黑」「IMX219 怎么配」「v4l2-ctl 预览」「camera DTS」时使用。WHEN: M2 camera, MIPI CSI, IMX219, IMX477, S5K3L6B, v4l2 capture, camera DTS, 摄像头适配, 出图黑屏. DO NOT USE FOR: 显示/屏（用 display），USB 摄像头（用 usb）。"
license: MIT
metadata:
  author: Quectel PI M2 外设 SKILL 库
  version: "1.0.0"
  board: Quectel PI M2 (RK3576 / QSM610ZAP-WF)
---

# M2 摄像头 SKILL — 双 MIPI-CSI 适配与使用

适用：Quectel PI M2（`quectel,pi-m2-rk3576`）。M2 有**两个** MIPI-CSI 连接器。

## 1. 硬件事实

| 项 | Camera1（CS0 通道） | Camera2（CS1 通道） |
|---|---|---|
| 连接器 | **J1002**（HRS TF38-22S，22Pin） | **J1001**（A050102213M011ARA，22Pin） |
| CSI 物理通道 | 模组 `CSI0`（RK3576 **DC-PHY0** / `csi2_dcphy0`） | 模组 `CSI3`（**DPHY3** / `csi2_dphy3` + `mipi3_csi2` + `rkcif_mipi_lvds3`） |
| lane | LN0..LN3 + CLK（4 lane 引出） | 同（LN0..LN3 + CLK） |
| 专用 I2C | **I2C4**（M3 复用）模组 pin64/65 | **I2C5**（M3 复用）模组 pin205/206 |
| MCLK | `CAM_CLK0_OUT_M0` = `CAM0_MCLK_1V8`（模组 pin62） | `CAM_CLK2_OUT_M0` = `CAM3_MCLK_1V8`（模组 pin91） |
| PWDN 脚（连接器 pin17） | `CAM0_PWDN` = `GPIO3_C7`（模组 pin64） | `CAM3_PWDN` = `GPIO3_D4`（模组 pin287） |
| RST 脚 | `CAM0_RST` = `GPIO3_D5`（模组 pin66） | `CAM3_RST` = `GPIO3_D6`（模组 pin207） |
| 3.3V | `CAM0_VCC_3V3`（由 PWDN 脚经 R1045 使能） | `CAM1_VCC_3V3`（由 PWDN 脚经 R1046 使能） |

**⚠️ 命名陷阱（最容易接错摄像头的地方）**：pinmap 上 "RST" 与 "PWDN" 的语义是：

- 标 **PWDN** 的脚 = **连接器 3.3V 电源输出使能**（高=上电，低=断电，默认下拉接地）
- 标 **RST** 的脚 = **连接器的 POWER DOWN 控制**（经电平转换输出 3.3/0V）

而 DTS 里 `pwdn-gpios` 接的是 `GPIO3_C7`/`GPIO3_D4`（电源使能），`reset-gpios` 接的是
`GPIO3_D5`/`GPIO3_D6`（连接器 PWDN）。**照抄别的板子的 sensor dtsi 时，这两组很容易反**，
反了的现象是"探头时全是 0 / 上电即失败"或"读得到 ID 但出图全黑"。

> **2026-10-10 上板实测**：
> - 两条相机总线都有器件被烧死在 DT 里，但**当前没接摄像头**时 `i2cdetect -y 4` / `-y 5` **全空**
>   （`imx219@10`/`imx477@1a` 都不应答）→ 别把"扫不到"当故障，先看有没有插模组。
> - **Camera2（`i2c-5`）的 sensor 候选比本文档多**：除了 `imx219_1@10`、`imx477@1a`、`dw9763c@e`，
>   DT 里还有 **`s5k3l6b@10`、`s5k3p9b@10`**（与 imx219_1 同地址，同时只会在位一个）。
> - Camera1（`i2c-4`）= `imx219@10` + `imx477@1a` + `dw9763@e`。
> - 另有 `gc08a3@0x31`（`i2c-2`）—— 它是**第三条（非连接器）**链路上的 sensor，别和 J1001/J1002 混。
> - 板级工具名是 **`qpi-test`**（不是 `qpi-test_m2`）：`qpi-test camera on 0` 等，见 §4。

## 2. 当前 DTS 实现

`rk3576-quectel-pi-m2-linux.dtsi` 末尾的 Camera 段**同时保留了 IMX219 和 IMX477 的候选节点**：

```dts
&i2c4 { imx477_0: imx477@1a {...} }      /* Camera1 */
&i2c5 { imx477_1: imx477@1a {...} }      /* Camera2 */
&imx219   { status = "okay"; }           /* Camera1 候选 */
&imx219_1 { status = "okay"; ... CLK_MIPI_CAMERAOUT_M2 ... }  /* Camera2 候选 */
&csi2_dcphy0 { ... mipi_in_ucam0_imx219: endpoint@2 ... }     /* 给 imx219 加的独立 endpoint */
&csi2_dphy3 / &mipi3_csi2 / &rkcif_mipi_lvds3 { status = "okay"; }
&dw9763 { status = "okay"; }             /* VCM 马达驱动（若镜头模组带 AF） */
```

要点：

- **一个连接器同一时刻只能插一个 sensor**；两个候选节点靠不同 endpoint 共存，谁在位谁出图。
- `&mipi_in_ucam0`（DC-PHY0 port0）给 imx477，`mipi_in_ucam0_imx219`（同 port 的 endpoint@2，`reg = <2>`）给 imx219。
- `&mipi_in_ucam3` 在 M2 上 `/delete-property/ remote-endpoint`（未用）。
- 摄像头 3.3V 的供电在 DTS 里用 `vcc_camera` 表示（avdd/dvdd/dovdd 全指它）。
- `data-lanes = <2 1>` 表示 **2 lane 且 lane 顺序交换**（板级走线导致），换 sensor 时要按实际模组确认。

## 3. 适配一块新摄像头（标准流程）

1. **确认模组**：sensor 型号、I2C 地址、供电（1.8/2.8/3.3V）、lane 数、MCLK 频率、
   VCM（`dw9763`）是否需要。
2. **内核里要有驱动**：`kernel/drivers/media/i2c/<sensor>.c`；RK 官方 sensor 驱动 +
   `rockchip,camera-module-*` 属性即可，无需额外 dtsi 文件（M2 用的就是通用 sensor 节点）。
3. **复制并改一段**（以 Camera1 为例）：
   ```dts
   &i2c4 {
       mycam: mycam@<addr> {
           compatible = "vendor,mycam";
           reg = <0xXX>;
           clocks = <&cru CLK_MIPI_CAMERAOUT_M0>;      /* Camera1 用 M0 */
           assigned-clock-rates = <24000000>;          /* 按模组要求 */
           pinctrl-0 = <&cam_clk0m0_clk0>;             /* Camera1 */
           pinctrl-1 = <&cam0_reset_active>;           /* 见下方 pinctrl 命名 */
           pinctrl-2 = <&cam0_reset_sleep>;
           reset-gpios = <&gpio3 RK_PD5 GPIO_ACTIVE_HIGH>;  /* 连接器 PWDN */
           pwdn-gpios  = <&gpio3 RK_PC7 GPIO_ACTIVE_HIGH>;  /* 3.3V 电源使能 */
           power-domains = <&power RK3576_PD_VI>;
           avdd-supply = <&vcc_camera>; dvdd-supply = <&vcc_camera>; dovdd-supply = <&vcc_camera>;
           port { mycam_out: endpoint { remote-endpoint = <&mipi_in_ucam0>; data-lanes = <2 1>; ... }; };
       };
   };
   ```
   Camera2 对应换：`&i2c5`、`CLK_MIPI_CAMERAOUT_M2`、`cam_clk2m0_clk2`、`cam2_reset_*`、
   `reset-gpios = <&gpio3 RK_PD6 ...>`、`pwdn-gpios = <&gpio3 RK_PD4 ...>`、`remote-endpoint = <&mipi_in_ucam5>`。
   注意 M2 现有的 `imx219_1` / `imx477_1` 用的都是 `GPIO_ACTIVE_LOW/ACTIVE_HIGH` 两种极性写法的先例——
   **极性以你的模组规格为准**，不要照抄。
4. **确认 CSI 通道没被别的 sensor 抢**：同一 port 上多个 endpoint 只有在位那个会被枚举；
   若两个 sensor 都插着，`/dev/video*` 会多出来但只有一个能出图。
5. **编译 + 上板验证**：
   ```bash
   ./build.sh kernel
   # 上板
   dmesg | grep -iE "csi|dcphy|dphy|rkcif|mipi|imx|mycam"
   v4l2-ctl --list-devices
   media-ctl -p -d /dev/media0        # 看 entity 链路是否 link 上
   ```

## 4. 使用（板级 / 应用层）

```bash
# 板级自测（gst + waylandsink，板型 M2）
qpi-test camera on 0        # 预览 Camera1
qpi-test camera on 1        # 预览 Camera2
qpi-test camera off         # killall gst-launch-1.0
qpi-test camera shot 0      # 抓 jpg 到 /tmp/image
qpi-test camera view <file> # 看图
qpi-test camera mp4 0       # 录 H264 mp4 到 /tmp/video
qpi-test camera play <file> # 播放

# 手工预览（板级工具用的就是这条，注意必须带 Wayland 环境变量）
GST_V4L2_FORCE_LIBV4L2=0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/<uid> \
  gst-launch-1.0 -e v4l2src device=/dev/video33 io-mode=4 ! \
  "video/x-raw,format=NV12,width=<W>,height=<H>" ! waylandsink
```
`qpi-test` 内部把 Camera1/Camera2 映射到 `/dev/video33` 与 `/dev/video51`（以实际枚举为准，
用 `v4l2-ctl --list-devices` 核对）。

### 产测 / AT 指令

- `AT+CAMERA` — 双路摄像头**二维码识别产测**指令。
- 二维码脚本：板上 `/usr/bin/qr_scan_m2.sh`。

## 5. 扩展场景

- **零拷贝预览**：`GST_V4L2_FORCE_LIBV4L2=0` + `io-mode=4` 走零拷贝链路。
  没有这个环境变量时 gst 会走 libv4l2 拷贝路径，CPU 占用高。
- **ROS 2 虚拟摄像头**：需要内核开 v4l2loopback（`CONFIG_VIDEO_V4L2_LOOPBACK`，本仓库
  `rockchip_linux_defconfig` 里**未启用**），把真实摄像头转发到 `/dev/videoN` 给 ROS 节点
  （`web_video_server` / `depth_cam`）消费。
- **二维码/视觉产测**：`AT+CAMERA` + `qr_scan_m2.sh`。
- **双目**：两个连接器同时插两个同样的 sensor，分别出 `/dev/video33`、`/dev/video51`。

## 6. 已知坑

1. **AVDD/IOVDD 全指 `vcc_camera`**：M2 连接器只给一路 3.3V（由 PWDN 脚使能），
   如果模组需要独立 1.8V/2.8V，得确认模组自带 LDO，否则传感器 probe 会挂在电源上。
2. **`GPIO3_C7` / `GPIO3_D4`（电源使能）默认下拉接地** → 如果 DTS 里没引用/没拉高，
   连接器没有 3.3V，表现为 `i2cdetect` 扫不到/扫到 0x00。
3. **MCLK 复用命名**：Camera1 用 `CAM_CLK0_OUT_M0`(M0)，Camera2 用 `CAM_CLK2_OUT_M0`，
   dtsi 里 pinctrl 分别是 `cam_clk0m0_clk0` / `cam_clk2m0_clk2`；弄反了 sensor 会 probe 超时。
4. **`&mipi_in_ucam3` 在 M2 被删了 remote-endpoint**；若你的 sensor 挂在这条链上，需要自己补。
5. **Wayland 环境变量**：直接 `gst-launch` 不带 `WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR` 会报
   "failed to create window"。`qpi-test` 会自动探测 `/run/user/*/wayland-0`。
5b. **★ caps 里不要写 `framerate`**（2026-10-10 实测）：
   ```bash
   # ❌ 会失败：not-negotiated (-4)
   v4l2src device=/dev/video33 io-mode=4 ! "video/x-raw,format=NV12,width=1280,height=720,framerate=30/1" ! waylandsink
   # ✅ 去掉 framerate 即可
   v4l2src device=/dev/video33 io-mode=4 ! "video/x-raw,format=NV12,width=1280,height=720" ! videoconvert ! waylandsink
   ```
   报错原文：`Internal data stream error ... streaming stopped, reason not-negotiated (-4)`。
   **注意：抓帧（`filesink`）带 `framerate` 是没问题的**（`qpi-test camera shot` 里带 `1920x1080` 也能出图）；
   是**接显示 sink 时** Negotation 对不上。ISP 侧 NV12 输出不接受精确帧率约束。
6. 休眠相关：摄像动作与 S3 休眠冲突时先停视频再复测，
   同时看 `power-pm/SKILL.md`。
7. **Camera1 采集节点是 `/dev/video33`**（2026-10-10 实测，rkisp_mainpath）：`v4l2-ctl --list-devices` 里
   `rkisp_mainpath (platform:rkisp-vir0)` → `/dev/video33`，支持 UYVY/NV16/NV61/NV21/**NV12**/NM21/NM12，
   `32x32 ~ 1920x1080`（步进 8）。Camera2 映射的 `/dev/video51` **未验证**（模组没接）。
