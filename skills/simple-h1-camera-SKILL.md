---
name: simple-h1-camera
description: "simple-h1 SDK: 排查 H1 (QCS6490) 相机不出图/预览卡住/关闭后无法再开，判断 camx 与 camss 两套栈、改 sensor 与下发"
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [qualcomm, qcs6490, quectel, simple-h1, camera, imx219, camx, camss, csi, gstreamer]
---

# H1 相机 — 双 MIPI-CSI（IMX219）+ camx 与 camss 两套栈

板级 DTS: `kernel/arch/arm64/boot/dts/qcom/qcs6490-idp-pi.dts`（2254 行，下文简称 DTS，行号已核对）。
内核相机代码: `kernel/drivers/media/platform/qcom/camss/`（**树内只有 camss，没有 camx 的内核部分**）、
`kernel/drivers/media/i2c/imx219.c`。

## 1. 硬件事实（原理图 p09 两个 CSI 座）

| 项 | Camera 1 | Camera 2 |
|---|---|---|
| 连接器 | **`J1002`** | **`J1001`** |
| 接口 | 4-lane MIPI CSI（SoC CSIPHY 供 PHY） | 同左 |
| 专用 I2C | `CAM_I2C_SCL0/SDA0`（CCI0） | `CAM_I2C_SCL1/SDA1`（CCI1） |
| MCLK | `CAM0_MCLK`（`CAM_CC_MCLK0_CLK`） | `CAM1_MCLK` |
| 复位 | `reset-gpios = tlmm 20`（DTS:2076），pinctrl `cam2_default`/`cam2_suspend`（DTS:2078-2079） | p09 独立一路 |
| 电源使能 | `power-gpios = tlmm 61`（DTS:2075），负载开关 **ETA4555QGU** | 同族 |
| 供电轨 | `VREG_L3P_2P8`（2.8 V）+ `VREG_L4P_2P9`（2.9 V） | 同左 |
| 电平/EMI | `NM-SDMM0806U-2-900T`（部分**未贴 NM**，不要引用） | 同左 |

**只有一个 sensor 节点**：`imx219: camera@10` 挂在 `&cci0_i2c0`（DTS:2071-2093）。

```dts
&cci0_i2c0 {                                   // DTS:2071
    imx219: camera@10 {
        compatible = "sony,imx219";
        reg = <0x10>;                          // 7 位地址
        power-gpios = <&tlmm 61 0>;            // DTS:2075 摄像头电源使能
        reset-gpios = <&tlmm 20 0>;            // DTS:2076 复位
        clocks = <&camcc CAM_CC_MCLK0_CLK>;
        assigned-clock-rates = <24000000>;     // 24 MHz MCLK
        port { imx219_ep: endpoint {
            remote-endpoint = <&csiphy0_ep>;
            data-lanes = <1 2>;                // 实际 2-lane
            link-frequencies = /bits/ 64 <456000000>;
        }; };
    };
};
```
⚠️ 地址口径：DTS 用 7 位 **`0x10`**，camx 日志打 8 位 **`0x20`**（`0x10<<1`）——**同一个器件**，别当两路。

**这段默认不参与编译**：整块被 `#if USE_CAMX_ENABLE == 0` 包住（DTS:2045，`#endif` 在 2094），
而 `kernel/include/dt-bindings/camera/quec-cam-select.h:4` 是 `#define USE_CAMX_ENABLE 1`
（该头文件在 DTS:25 被 include）→ 条件为假，**camss 侧 imx219 配置是死代码**。
另外 `scripts/kernel-config` 里 `# CONFIG_VIDEO_IMX219 is not set`，而 `CONFIG_VIDEO_QCOM_CAMSS=m`。
⇒ 要走 camss/V4L2 栈，**两处都要改**（头文件改 0 + 打开 `CONFIG_VIDEO_IMX219`）再重编。

## 2. 两套栈（同一硬件，二选一）

| | **camx（默认）** | camss / V4L2 |
|---|---|---|
| 用户态 | `qtiqmmfsrc`（GStreamer 插件）+ `cam-server` | `v4l2src` + media-ctl / v4l2-ctl |
| 组件 | camx 库、CHI-CDK、cam-server | 内核 `kernel/drivers/media/platform/qcom/camss/` |
| ISP | **IFE / IPE / BPS**（QCS6490 独有，判定标志） | 无 |
| DTS 开关 | `USE_CAMX_ENABLE = 1`（当前） | `USE_CAMX_ENABLE = 0` |
| sensor 配置来源 | 预置 dtbo `tools/uki/dtbo/qcm6490-camera-rb3.dtbo`（含 `qcom,cam-sensor*`、`cam_sensor_mclk*`、`cam_sensor_active_rst*` pinctrl；**二进制，本 SDK 无源码**） | DTS:2045-2094 + `imx219.c` |

`./scripts/pack-efi.sh` 会用 `fdtoverlay` 把 `qcm6490-camera-rb3.dtbo` 叠到板级 dtb 上再进 UKI，
结果写在 `build/merged-qcs6490-idp-pi.dtb`——**要看 camx 实际拿到哪些 sensor 节点就看它**。

## 3. 使用（设备侧）

### 3.1 前提（不做就"预览看不到画面"）

```bash
export GST_PLUGIN_PATH=/usr/lib/gstreamer-1.0:$GST_PLUGIN_PATH   # 缺它必报 No such element 'qtiqmmfsrc'
# 实测 A（Debian 镜像）: 不加这行 gst-inspect-1.0 qtiqmmfsrc 判 MISSING, 加上后 rc=0
# 实测 B（qcom-wayland）: 插件目录本就是默认搜索路径, 不加也能找到; 报 No such element 时再补这行
# 仅 adb/ssh 远程终端才需要下面两行
export DISPLAY=:0
FILE_PATH=$(sudo find /run/user/1001 -type f -name '.mutter-*' | head -n 1)
[ -n "$FILE_PATH" ] && export XAUTHORITY="$FILE_PATH"
```
之后用 **`sudo -E`** 跑（`-E` 保留刚 export 的环境）。sink 拿不到 surface 时管道**静默卡住、0 帧不报错**，最难查。

### 3.2 预览 / 录像 / 拍照

```bash
# 预览（实测 B 上这台板没接摄像头，qmmf 直接报 Failed to Open Camera + pipeline doesn't want to preroll；
#        有摄像头时才可能进入 PLAYING，失败时先确认硬件而不是改管道）
sudo -E gst-launch-1.0 -e qtiqmmfsrc name=camsrc ! \
  'video/x-raw,format=NV12,width=1280,height=720,framerate=30/1' ! autovideosink

# 预览 + 硬编 H.264 → /opt/11.mp4
sudo -E gst-launch-1.0 -e qtiqmmfsrc name=camsrc video_1::type=preview ! \
  'video/x-raw,format=NV12,width=1280,height=720,framerate=30/1' ! \
  tee name=t ! queue ! videoconvert ! autovideosink \
  t. ! queue ! v4l2h264enc capture-io-mode=5 output-io-mode=5 \
  extra-controls="controls,video_bitrate=6000000,video_bitrate_mode=0;" ! \
  queue ! h264parse ! mp4mux ! filesink location=/opt/11.mp4

# 预览 + 拍照（连拍改 max-files=n）
sudo -E gst-launch-1.0 -e qtiqmmfsrc name=camsrc ! \
  'video/x-raw,format=NV12,width=1280,height=720,framerate=30/1' ! \
  tee name=t ! queue ! videoconvert ! autovideosink \
  t. ! queue ! videoconvert ! jpegenc ! multifilesink location=shot-%05d.jpg max-files=1

# 回放（镜像缺 avdec_h264，用硬解）
gst-launch-1.0 -e filesrc location=/opt/11.mp4 ! qtdemux ! queue ! h264parse ! \
  v4l2h264dec capture-io-mode=5 output-io-mode=5 ! autovideosink
```
- 出现 `PLAYING` 才算跑起来；`Ctrl+C` 停。
- ⚠️ `qtiqmmfsrc` **不给 caps 时默认 `image/jpeg 640x480@30`**（厂商 cam2file 类裸管道出的就是它）；要 NV12/720p 必须显式给 caps。
- ⚠️ 镜像**没有 `waylandsink`**，凡用它一律换 `videoconvert ! autovideosink`。
- 单路时**不要加** `camera=0/1`（会 `pipeline doesn't want to preroll`）；两路都插时才用它做**单路索引**。

### 3.3 USB 摄像头（UVC，主节点 `/dev/video2` + metadata `/dev/video3`）

```bash
gst-launch-1.0 v4l2src device=/dev/video2 ! image/jpeg,width=1280,height=720,framerate=30/1 ! jpegdec ! videoconvert ! autovideosink
gst-launch-1.0 -e v4l2src device=/dev/video2 io-mode=2 ! video/x-raw,format=YUY2,width=1280,height=720,framerate=10/1 ! videoconvert ! autovideosink
```

### 3.4 硬件自检（镜像缺 i2cdetect / v4l2-ctl / media-ctl，用替代写法）

```bash
cat /sys/bus/i2c/devices/*/name                 # 替代 i2cdetect
gst-device-monitor-1.0                          # camx 栈可用来源
dmesg | grep -iE "sensor_id|CAM_START_DEV|CAM_ACQUIRE|camss|camx|csiphy|cci|imx219"
ls /dev/video*                                  # camss 栈出 videoN；camx 走 QMMF，不一定有 v4l2 节点
journalctl -u cam-server --no-pager | tail -50
lsmod | grep -iE "qcom_camss|cam" ; modinfo qcom-camss | head -5   # 模块名 qcom-camss.ko
# 实测 A: camx 模块名 camera; video0=cam-req-mgr, video1=cam_sync, video32/33 无名
# 实测 B: camx 模块名 camera_qcm6490; 多出 video10; 同样没有 qcom-camss
#         两镜像都有 cam-cpas/cam-isp/cam-csiphy-driver/cam-sensor-driver 等 subdev 与 /dev/media0~2
#         两镜像 cam-server 均 active; 实测 B 的 camx-v4l2-bridge@0.service = failed（不影响 qmmf 通路）
```

## 4. 适配新 sensor

1. **camx 路线（默认栈）**：sensor 需 xml + camx overlay 配置，节点由预置 dtbo 提供，**不是纯 DTS 工作**；本 SDK 只能 overlay 替换用户态配置，或整套换预置 dtbo。
2. **camss 路线（本 SDK 可完整改）**：改 `kernel/include/dt-bindings/camera/quec-cam-select.h` 为 0 →
   打开 `scripts/kernel-config` 的 `CONFIG_VIDEO_<SENSOR>` →
   改 DTS:2071-2093（`reg`/`reset-gpios`/`power-gpios`/`clocks`/`data-lanes`/`link-frequencies`）+
   `&camss` 的 csiphy `data-lanes`（DTS:2058-2062，当前 `<0 1>`）。
3. 供电必须拉高（tlmm61），否则 I2C 扫不到；2.8 V/2.9 V 来自 `VREG_L3P_2P8`/`VREG_L4P_2P9`。
4. 下发：`./scripts/build-kernel.sh` → `./scripts/pack-dtb.sh` + `./scripts/pack-efi.sh` + `./scripts/pack-system.sh`（camss 模块）；只改 overlay 用 `SKIP_KERNEL=1 ./scripts/build-all.sh`。

## 5. 已知坑

1. **两套栈不要混用**：camx 镜像里 `cci0`/`camss` 节点虽 okay，sensor 不在 camss 上注册，`v4l2-ctl` 找不到设备属正常；camss 镜像里 `qtiqmmfsrc` 不可用。
2. **cam-server 变僵尸后 reboot 会卡死（最危险）**：`ps` 见 `[cam-server] <defunct>`、`State: Z`，
   dmesg 见 `CAM_WARN: cam_isp_subdev_close: CRM is ACTIVE, close should be from CRM`；随后 reboot 卡住，
   systemd 报 `Job cam-server.service/stop running (2min/3min)`，dmesg 报 `INFO: task cam-server:xxxx blocked for more than 241 seconds.`（D 状态，`SIGKILL` 无效）→ **只能断电**。
   根因（有内核栈）：`__mutex_lock` → `cam_mem_mgr_deinit+0x88`，mem-mgr 清理 active buffer 时自死锁。
   触发点：非正常关闭（sink 拿不到 surface → 管道静默卡住 → `kill -INT` 收不掉 → 改 `SIGKILL` 兜底）。
   规避：手动调试一律 `kill -INT <gst pid>` + `wait`，或用厂商 cam2file 服务收尾；
   **不要 `kill -9`/`pkill` cam-server 或 camx 线程**；见僵尸先 `systemctl stop cam-server`，stop 也卡住就直接断电。
3. **正常出图时也会刷的噪声，别追**：`GetUnalignedBufferSize() ... NOT Implemented in LE!`、`[STATS_AEC] Input BG stats grid has invalid sizes (0, 0)!`、
   `caeccore ... Unhandled AEC set input type NN`、`Failed to get AANR_ATF Chromatix`、`Failed to populate Gyro data`、内核 `CAM_WARN: cam_vfe_bus_acquire_wm ... Override width 1640 with expected 1648`。
   **判据是"有没有帧"**：`journalctl -u cam-server | grep "OnFrameAvailable"` 或 `chiFrameNum` 递增。
4. `CAM_WARN: cam_req_mgr_close: release invoked ... open_cnt: 1` 在**干净 stop 时也会打印**，不能凭它判故障。
5. **两个 CSI 座插同型号 sensor** 时 I2C 地址相同（0x10），必须确认两路 CCI 是独立总线，否则第二路 probe 失败。
6. **`NM-*` 器件不要引用**（p09 上 `NM-SDMM0806U-2-900T`、部分 `NM-10K` 未贴）。
7. **相机与 DSI 屏的 HDMI 链路互斥**：预览必须有显示输出；用 DSI 屏时 LT9611 那条链路不 probe（见 display 技能）。
8. "GNOME 相机无设备"曾由 PAL 音频权限连带 PipeWire 崩溃引起 —— 先确认 PipeWire 在跑。

## 6. 相关外置模块（视频编码走 iris_vpu，源码不在本 SDK，只能设备侧看与替换）

```bash
modinfo iris_vpu | head -5 ; lsmod | grep -E "iris_vpu|msm_kgsl" ; dmesg | grep -iE "iris|kgsl|venus"
# 替换：新 ko 放进 overlay/lib/modules/6.6.116-qli-1.7-ver.1.1/updates/
#       → SKIP_KERNEL=1 ./scripts/build-all.sh → ./scripts/flash.sh
# 版本串不一致的 ko 不会被加载（vermagic 检查）
```