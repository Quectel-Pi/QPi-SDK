---
name: simple-h1-driver
description: "simple-h1 SDK: 驱动定位 — DTS 节点↔驱动源码、include 链、子系统速查表、改设备树流程"
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [qualcomm, qcs6490, quectel, simple-h1, driver, dts, kernel-source]
    related_skills: [simple-h1-kernel, simple-h1-display, simple-h1-audio, simple-h1-camera, simple-h1-usb]
---

# 驱动与设备树定位

## 1. 板级设备树

唯一要改的文件: `kernel/arch/arm64/boot/dts/qcom/qcs6490-idp-pi.dts` (2254 行, 下文简称 DTS)。

include 链:

```
qcs6490-idp-pi.dts
├── qcm6490.dtsi            SoC 级节点 (含 qcs6490.dtsi 内容)
├── pm7250b.dtsi            PMIC 7250B
├── pm7325.dtsi             PMIC 7325
├── pm8350c.dtsi            PMIC 8350C (PWM 在这里, 风扇用 pwm3)
├── pmk8350.dtsi            PMIC K8350 (ADC/RTC)
└── dt-bindings/...         宏 (GPIO 标志、时钟 ID、ADC 通道)
```

顶层节点 (行号是本 SDK 内的实际位置, 改之前先 `sed -n` 看一眼):

| 节点 | 行 | 内容 |
|------|----|------|
| `hdmi_audio` | 55 | LT9611 与声卡共享的 HDMI codec 占位 |
| `dp-connector` | 59 | DP over Type-C 连接器 |
| `lt9611_1v2` | 83 | LT9611 1V2 regulator |
| `sound` | 137 | 声卡, `qcom,qcm6490-sndcard`, DAI link 与大表 audio-routing |
| `thermal-zones` | 255 | 温度区与 trips (含 BCL) |
| `wcd9370` | 299 | audio codec |
| `gpio-keys` | 327 | 按键 |
| `lt9611_codec` | 703 | LT9611UXC @i2c0 0x2b |
| `lt9611_uxd_codec` | 737 | LT9611UXD @i2c0 0x41 |
| `panel_ws` | 781 | 微雪 8" DSI 屏 @i2c3 0x45 (`waveshare,8.0inch-panel`) |
| `touch_gt` | 798 | GT911 触摸 @i2c3 0x14 (另有 `touch_ii` @0x41、`touch_gt2` @0x5d) |
| `rtl8111h_3v3_vreg` | 1123 | PCIe0 网卡 3V3 (名字是历史遗留, 实际供 YT6801) |
| `lt9611_3v3_vreg` | 1153 | LT9611 3V3 |
| `&pcie0` / `&pcie0_phy` | 1753 | PCIe0 (以太网卡所在总线) |
| `fanfan` | 2030 | `pwm-fan`, `pwms = <&pm8350c_pwm 3 65535>` |
| `&cci0_i2c0` → `imx219` | 2071 / 2072 | 摄像头 `sony,imx219` @0x10, 在 `#if USE_CAMX_ENABLE == 0` 内 |

补充: `aliases` 在 37-43 行 (`serial0 = &uart5`, `serial1 = &uart7`, `hsuart0 = &uart4`),
`chosen/stdout-path = "serial0:115200n8"` 在 45 行 —— 调试串口 115200 就是从这来的。

## 2. compatible → 驱动源码

```bash
cd kernel
# 1) 从 compatible 找 of_match 表
grep -rn 'qcom,qcm6490-sndcard' sound/soc/        # -> sound/soc/qcom/qcm6490.c:279
# 2) 再找 driver 注册
grep -rn 'platform_driver_register\|module_platform_driver' sound/soc/qcom/qcm6490.c
```

实测可用的几个例子:

| compatible | 驱动 |
|---|---|
| `qcom,qcm6490-sndcard` | `sound/soc/qcom/qcm6490.c` (机器驱动, 管 DAI link) |
| `qcom,wcd9370-codec` | `sound/soc/codecs/wcd937x.c` + `wcd937x-sdw.c` |
| `lontium,lt9611uxc` / `lt9611uxd` | `drivers/gpu/drm/bridge/lontium-lt9611uxc.c` / `-uxd.c` |
| `waveshare,8.0inch-panel` | `drivers/gpu/drm/panel/panel-waveshare-dsi.c` |
| `goodix,gt911` | `drivers/input/touchscreen/goodix.c` |
| `sony,imx219` | `drivers/media/i2c/imx219.c` + CAMSS (`drivers/media/platform/qcom/camss/`) |
| `pwm-fan` | `drivers/hwmon/pwm-fan.c` |

## 3. 子系统源码速查

| 子系统 | 主要路径 |
|--------|----------|
| 显示/GPU | `drivers/gpu/drm/msm/`, `drivers/gpu/drm/msm/adreno/`, `drivers/gpu/drm/bridge/` |
| 音频 DSP | `sound/soc/qcom/qdsp6/` (q6apm/q6afe), `sound/soc/qcom/qcm6490.c` |
| 音频 codec | `sound/soc/codecs/{wcd937x,lpass-rx-macro,lpass-tx-macro,lpass-va-macro}.c` |
| 摄像头 | `drivers/media/platform/qcom/camss/`, `drivers/media/i2c/` |
| USB | `drivers/usb/dwc3/`, `drivers/usb/typec/ucsi/`, `drivers/phy/qualcomm/` |
| PCIe | `drivers/pci/controller/dwc/pcie-qcom.c` |
| 串口/I2C/SPI | `drivers/tty/serial/qcom_geni_serial.c`, `drivers/i2c/busses/i2c-qcom-geni.c`, `drivers/spi/spi-geni-qcom.c` |
| GPIO/pinctrl | `drivers/pinctrl/qcom/pinctrl-sc7280.c`, `pinctrl-msm.c` |
| 存储 | `drivers/ufs/host/ufs-qcom.c`, `drivers/mmc/host/sdhci-msm.c` |
| 电源/regulator | `drivers/regulator/qcom-rpmh-regulator.c`, `drivers/regulator/`, `drivers/mfd/` |
| 热/风扇 | `drivers/thermal/qcom/`, `drivers/hwmon/pwm-fan.c` |
| 远端处理器 | `drivers/remoteproc/qcom_q6v5_pas.c` (ADSP/CDSP) |
| 时钟/互连 | `drivers/clk/qcom/`, `drivers/interconnect/qcom/` |
| 网卡/无线 | **源码不在本 SDK**: 只以 `overlay/lib/modules/<ver>/updates/` 预置 ko 提供 |

## 4. 改设备树的流程

1. 定位节点: `grep -n '<节点名或compatible>' kernel/arch/arm64/boot/dts/qcom/qcs6490-idp-pi.dts`;
2. 改完编译验证 (语法错误在 dtbs 阶段暴露):
   ```bash
   ./scripts/build-kernel.sh
   # 只看 dtb 是否生成
   ls -l build/kernel/arch/arm64/boot/dts/qcom/qcs6490-idp-pi.dtb
   ```
3. 反查编译结果 (确认改的节点真的进了 dtb):
   ```bash
   dtc -I dtb -O dts build/kernel/arch/arm64/boot/dts/qcom/qcs6490-idp-pi.dtb 2>/dev/null \
     | grep -A15 '<你的节点名>'
   ```
4. 板上看运行态: `/proc/device-tree/` 下的节点与属性是二进制, 用 `hexdump -C` 或
   `ls /proc/device-tree/` 逐级看; 驱动侧看 `dmesg | grep -i <驱动名>`。
5. 打包: 改了 DTS 要重打 **efi.bin 与 dtb.bin 两个分区** (`./scripts/build-all.sh`)。

## 5. 陷阱

| 陷阱 | 说明 |
|------|------|
| 这个 DTS 用 C 预处理器 | 有 `#if USE_CAMX_ENABLE == 0` / `#include <dt-bindings/...>`; 被 `#if` 包住的节点默认可能不生效, 改前先确认宏值 |
| IMX219 有两套栈 | `USE_CAMX_ENABLE != 0` 时走 CAMX 的外部 dtsi, DTS 里这段 camss 节点不生效 |
| dtbo 会覆盖基 dtb | `tools/uki/dtbo/*.dtbo` 在打包时叠加; 与基 dtb 冲突的属性以 dtbo 为准 |
| 改 `.dtsi` 影响面大 | qcm6490.dtsi / pm*.dtsi 是 SoC/PMIC 级定义, 板级差异一律写在 `qcs6490-idp-pi.dts` |
| regulator 名字误导 | `rtl8111h_3v3_vreg` 实际给 YT6801 用; 按 DTS 引用关系判断, 不要按名字猜 |
| 只看源码不看运行态 | 必须结合 `dmesg` 实际输出下结论 |
