---
name: simple-h1-display
description: "simple-h1 SDK: 排查 H1 (QCS6490) MIPI-DSI 屏 / LT9611 HDMI 桥 / Type-C DP 黑屏无显示，以及换屏适配与 DTS 改动下发"
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [qualcomm, qcs6490, quectel, simple-h1, display, dsi, hdmi, lt9611, drm]
---

# H1 显示 — MIPI-DSI 屏（微雪 8"）+ LT9611 HDMI 桥 + DP over Type-C

板级 DTS: `kernel/arch/arm64/boot/dts/qcom/qcs6490-idp-pi.dts`（全文 2254 行，下文简称 DTS；行号已逐条核对）。
驱动源码: `kernel/drivers/gpu/drm/msm_default/`（显示/GPU 实际编译目录）、`kernel/drivers/gpu/drm/bridge/`、`kernel/drivers/gpu/drm/panel/`。

## 1. 硬件事实（重点：H1 的 HDMI 不是 SoC 原生，是 LT9611 桥）

| 显示通道 | 硬件路径 | 连接器 | 说明 |
|---|---|---|---|
| **MIPI DSI 屏** | SoC **DSI0** → 4-lane DSI → 屏 | FPC **`J1103`**（原理图 p10） | 微雪 8.0" IPS 电容触摸屏，1280×800@60，4-lane D-PHY |
| **Micro HDMI** | SoC **DSI1/DSI2** → **LT9611UXC/UXD 桥** → HDMI | **`J2001`**（p19） | ⚠️ 不是 SoC 原生 HDMI，标称 4K@60 |
| **DP over Type-C** | MDSS **DP** → USB-C QMP PHY（DP Alt Mode） | **`J1501`** / `J2101` | DP 1.4，4K@60；经 SS mux |
| **eDP** | `&mdss_edp` → **同一个 `dp-connector` 节点** | 复用 DP 连接器描述 | 改之前先看 `dp_connector_in`（DTS:65-67 的 remote 是 `&mdss_edp_out`） |

**互斥**：Micro HDMI 与 MIPI 屏只能二选一 —— LT9611 走 DSI1/DSI2，屏走 DSI0，共用 MDSS DSI 资源：
- `mdss_dsi1_out → lt9611_uxc_in`、`mdss_dsi2_out → lt9611_uxd_in`：DTS:932-943
- `mdss_dsi0_out → panel_in`：DTS:948-952

DTS:236-243 的注释即厂商自证：*接 LCD panel 时 LT9611 不 probe（DSI 被 panel 占用），此链路被跳过，避免整个声卡 probe defer 导致无声卡；不接 panel 时 LT9611 正常注册 codec。*
另：**HDMI 屏的触摸走 USB**（屏的 USB 口接板子 USB-A），不是 I2C；DSI 屏触摸才是 `i2c3` 上的 goodix。

### LT9611 关键引脚（DTS:700-772 + 1143-1160）

| 信号 | GPIO / 资源 | 行号 |
|---|---|---|
| `reset-gpios` | `tlmm 158`（pinctrl `lt9611_rst_pin` DTS:1242） | 709 / 743 |
| `enable-gpios` | `tlmm 7`（LT9611_5V_EN，高有效） | 710 / 744 |
| `interrupts-extended` | `tlmm 44` 下降沿（`lt9611_irq_pin` DTS:1249） | 708 / 742 |
| `lt9611_1v2_vreg` | `tlmm 121`，源 `vreg_l17b_1p7`（供 U1902 SGM4568） | 1143-1152 |
| `lt9611_3v3_vreg` | `tlmm 46` | 1153-1160 |
| I2C 地址 | **0x2b = UXC**（DTS:704-705）、**0x41 = UXD**（DTS:738-740），贴哪个哪个 probe | — |

### DSI 屏关键引脚（`panel_ws: waveshare-panel@45`，DTS:781-796）

| 信号 | GPIO / 资源 |
|---|---|
| `switch-gpio` | `tlmm 6`（DTS:787） |
| `power-gpio` | `tlmm 54`（DTS:788） |
| `dsi-gpio` | `tlmm 15`（DTS:789） |
| `vddio_i2c-supply` | `vreg_l18b_1p8`（DTS:786） |
| 触摸 IRQ | `lcd_touch_default` = **gpio81**（DTS:1510-1515），三处 `interrupts-extended` 全被注释（DTS:802 / 812 / 821）→ 走 polling |
| 背光 | 屏侧 I2C 寄存器 0xab，写入 `0xff - brightness`（`kernel/drivers/gpu/drm/panel/panel-waveshare-dsi.c:489`） |

## 2. 软件栈

```
MDSS (msm_drm)
├── DSI0 ──► panel_ws (waveshare,8.0inch-panel) @i2c3 0x45  ← 8" DSI 屏
├── DSI1 ──► lt9611uxc @i2c0 0x2b ──► hdmi_con ──► J2001
├── DSI2 ──► lt9611uxd @i2c0 0x41 ──► hdmi_con
├── DP   ──► usb_1_qmpphy_dp_in（DP Alt Mode，DTS:923-926）
└── eDP  ──► dp_connector_in（DTS:963-968）
```

`scripts/kernel-config` 里的相关开关（改显示前先确认，编出来的东西是否真进了镜像）：

| 配置 | 值 | 含义 |
|---|---|---|
| `CONFIG_DRM_MSM` | `=m` | msm_drm 是模块，模块由 `./scripts/pack-system.sh` 打进 system.img 的 `/lib/modules/6.6.116-qli-1.7-ver.1.1/` |
| `CONFIG_DRM_MSM_MDSS` / `_DP` / `_DSI` | `=y` | DP/DSI 后端 |
| `CONFIG_DRM_LONTIUM_LT9611UXC` / `LT9611UXD` | `=m` / `=m` | 两条桥驱动（`kernel/drivers/gpu/drm/bridge/lontium-lt9611uxc.c`、`lontium-lt9611uxd.c`） |
| `CONFIG_DRM_LONTIUM_LT9611` | 未开 | 并行 DSI 版本桥，H1 不用 |
| `CONFIG_WAVESHARE_DSI_PANEL_BL` | `=y` | 微雪屏 + 背光（`panel-waveshare-dsi.c`） |
| `CONFIG_TOUCHSCREEN_GOODIX` | `=m` | GT911（`kernel/drivers/input/touchscreen/goodix.c`） |

## 3. 上板判据（两个 I2C 节点同时存在，别误判）

> **实测 A**（Debian 13 / 6.6.52-debug）：只有 `card0-DP-1` / `card0-DSI-1`，`modes = 1920x1080`，
> `bridge_chains → lt,lt9611uxc`，`panel0-backlight = 78/255`，dmesg 有 `ws_panel_i2c_write ... 0xad: -6`。
> **实测 B**（qcom-wayland / 6.6.116-qli-1.7-ver.1.1）：出现 `card0-HDMI-A-1 connected` + `card0-DP-1/DP-2`，
> `bridge_chains → lt,lt9611uxd`，dmesg 有 `lt9611uxc 0-002b: Waiting for LT9611UXD probe`。
> **同一块板换镜像，connector 名与生效的桥都会变** —— 不要按名字、更不要按“必然 UXC”下结论。

`/sys/bus/i2c/devices/0-002b`（UXC）与 `0-0041`（UXD）会同时出现在设备上，实际只贴一颗：

- UXD 先 probe 失败是**预期噪声**：`lt9611uxd 0-0041: Failed to write unlock register: -6`（`lontium-lt9611uxd.c:1109`）
  → `failed to read chip id.`（同文件 1354）→ 驱动放弃。
- UXD 若要真用，需要 `/lib/firmware/LT9611UXD.bin`（`lontium-lt9611uxd.c:31` + 224 `request_firmware`），缺文件直接失败。
- **判定当前生效变体**：看 `bridge_chains` 的 `OF:` 是 `hdmi-bridge@2b:lontium,lt9611uxc` 还是 `@41:lontium,lt9611uxd`；
  对应驱动还会打 `LT9611 revision:`（`lontium-lt9611uxc.c:826`）。
- **判定"哪条桥在点亮"**：`/sys/kernel/debug/dri/0/bridge_chains` 找 `lt,lt9611uxc`（比 sysfs 名可靠）。
- connector 名随 DT/镜像变（实测 A 只有 DP-1/DSI-1；实测 B 有 HDMI-A-1 + DP-1/DP-2），且 DSI/HDMI 节点上挂的
  可能是桥而不是屏；以 `bridge_chains` + dmesg + `modes` 为准（屏原生 1280×800，显示器 EDID 报其它分辨率）。

## 4. 设备侧命令（本 SDK 无 fps/截图脚本，全部走 adb）

```bash
for c in /sys/class/drm/card*-*/status; do echo "$c: $(cat $c)"; done   # 连接器状态
cat /sys/class/drm/card0-DSI-1/modes                                   # 当前 mode / EDID 特征
cat /sys/kernel/debug/dri/0/bridge_chains                              # 活跃 encoder→bridge 链
dmesg | grep -iE "lt9611|dsi|panel|msm_drm|edid"
ls /sys/class/backlight/            # 背光节点名; 实测 B 未接 DSI 屏时该目录为空 (只有 HDMI 出图)
cat /sys/class/backlight/*/brightness; cat /sys/class/backlight/*/max_brightness
```

```bash
adb shell "for c in /sys/class/drm/card*-*/status; do echo \$c: \$(cat \$c); done"
adb shell dmesg | grep -iE "lt9611|dsi|panel|msm_drm|edid"
adb shell "echo 200 > /sys/class/backlight/<节点>/brightness"   # 需 root（su）
```

- HDMI 支持热插拔；MIPI / DP 不支持，插拔间隔建议 ≥5s。
- 本镜像未装 `modetest`，看 connector/模式只能用 sysfs + debugfs。
- 播视频若要硬解：`gst-launch-1.0 filesrc location=/tmp/t.mp4 ! qtdemux ! h264parse ! v4l2h264dec capture-io-mode=5 output-io-mode=5 ! videoconvert ! autovideosink`
  （镜像缺 `avdec_h264` 软解插件；缺 `waylandsink`，一律用 `autovideosink`；软渲染不稳时 `export LIBGL_ALWAYS_SOFTWARE=1`）。

## 5. 改动如何下发

| 改动内容 | 命令 | 产物 |
|---|---|---|
| 只改 DTS | `./scripts/build-kernel.sh` → `./scripts/pack-dtb.sh` → `./scripts/pack-efi.sh`（UKI 里也带 dtb） | `dtb.bin` + `efi.bin` |
| 改 DTS + 内核驱动 | `./scripts/build-kernel.sh` → `./scripts/pack-efi.sh` → `./scripts/pack-system.sh` | `efi.bin` + `system.img`（模块） |
| 一次性都做 | `./scripts/build-all.sh`（只打包：`SKIP_KERNEL=1 ./scripts/build-all.sh`） | `build/result/*` |
| 烧录 | `./scripts/flash.sh`（先 `adb shell reboot edl`） | — |

⚠️ `./scripts/pack-efi.sh` 会把 `tools/uki/dtbo/` 下的 `qcm6490-graphics.dtbo`、`qcm6490-camera-rb3.dtbo`、
`qcm6490-video.dtbo` 用 `fdtoverlay` 叠到你的 dtb 上再进 UKI。**dtbo 是预置二进制**，本 SDK 不含其源码；
改 DSI/DP 节点若被 dtbo 覆盖，请先看 `build/merged-qcs6490-idp-pi.dtb` 的实际内容。

## 6. 适配新屏（少改一处就黑屏）

1. 接口确认：DSI FPC `J1103` 是 4-lane；非微雪屏要新写 panel 驱动，放进 `kernel/drivers/gpu/drm/panel/`
   并加进同目录 `Makefile` + `Kconfig`（微雪屏参考 `panel-waveshare-dsi.c`）。
2. DTS 四处必改：
   - `panel_ws@45`（DTS:781-796）的 `compatible` / `reg`（屏侧 I2C 地址）/ 三个 GPIO；
   - `&mdss_dsi0_out`（DTS:948-952）的 `data-lanes`（当前 `<0 1 2 3>`）；
   - `&mdss_dsi`（DTS:928-946）`vdda-supply = vreg_l6b_1p2` 与 `&mdss_dsi_phy`（DTS:954-957）`vdds-supply = vreg_l10c_0p88`；
   - 触摸：换 IC 改 `touch_gt@14`（DTS:798-809）的 `compatible`/`reg`，并补 `interrupts-extended`（见坑 5/6）。
3. 分辨率写在 panel 驱动的 mode 表里，运行期不可调。
4. 验证：`adb shell "cat /sys/class/drm/card*-*/status"` + `adb shell dmesg | grep -iE "dsi|panel"`。

## 7. 已知坑

1. **HDMI 音频链路必须带 `qcom,optional-dai-link`**（DTS:242）。接 LCD panel 时 LT9611 不 probe，
   链路若为必需项则**整张声卡 probe defer → 连本地喇叭也没声**。
2. **DP 的 next_bridge 循环依赖会阻塞主显示**：DP probe 必须非阻塞 + 异步轮询 + DP 失败不致命；
   改 `kernel/drivers/gpu/drm/msm_default/dp/` 时保留这套逻辑。
3. **GPU/显示驱动只改 `msm_default` 目录**（`kernel/drivers/gpu/drm/msm_default/`），
   `kernel/drivers/gpu/drm/msm/` 不是实际编译的那份。
4. **DP HPD/ISR 与 DSI bonded pclk** 两处修复不要回退（回退表现：DP 热插拔死机 / DSI 花屏）。
5. **GT911 走 polling，关机/重启会崩 I2C 适配器**：goodix 的 polling 模式必须保留 shutdown 回调
   停 timer/work。要改中断（坑 6）必须同时处理这一条。
6. `interrupts-extended` 在 `touch_gt`/`touch_ii`/`touch_gt2` 三处都被注释（DTS:802/812/821），
   即当前是 polling 而非中断。
7. **HDMI 与 DSI 不能双显**；要双屏只能 DSI + DP（Type-C），DP 还依赖 USB-C 链路（SBU/PD）。
8. **DSI 屏侧 4 处供电任选其一**（Type-C / I2C 供电口 / 5V 口 / 顶针接 40Pin）——接错或都不接就是纯黑屏，
   先量电再怀疑驱动。
9. GDM 相关：`key_event_handler` 与 `gdm` 曾因双向 `Conflicts` 互斥导致 gdm start job 被删（开机不进桌面）。
   调整 systemd 单元依赖时不要把这条互斥关系重新引入。
