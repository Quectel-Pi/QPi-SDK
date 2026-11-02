---
name: audio
description: "Quectel PI M2 音频：ES8389 codec（I2C2 @0x10）+ AW8010 功放 + 耳机检测（HPH_DET/SARADC4）+ 板载 MEMS MIC + BT PCM/HDMI 音频；DTS 结构、ASoC 声卡与 mixer 使用、无声/录音小/POP 音排查。当用户说「M2 喇叭没声」「耳机检测不对」「录音很小」「POP 音」「换 codec」「HDMI 音频」「BT 音频」时使用。WHEN: M2 audio, ES8389, AW8010, headphone detect, ALSA mixer, POP noise, audio DTS, 喇叭无声, 录音, 耳机. DO NOT USE FOR: 高通 PAL/ACDB 音频（用 qualcomm-android-audio-hal-debugging），设备树 overlay 打包（用 sdk-overlays）。"
license: MIT
metadata:
  author: Quectel PI M2 外设 SKILL 库
  version: "1.0.0"
  board: Quectel PI M2 (RK3576 / QSM610ZAP-WF)
---

# M2 音频 SKILL — ES8389 + AW8010 + 耳机检测 + BT/HDMI 音频

适用：Quectel PI M2（`quectel,pi-m2-rk3576`）。板级音频文件：`rk3576-quectel-pi-m2-audio.dtsi`。

## 1. 硬件事实

| 功能 | 器件 | 连接/引脚 |
|---|---|---|
| 音频 Codec | **ES8389**（U0901，EVEREST，24-QFN） | I2C **addr 0x10**（7bit）挂 **I2C2** |
| 数据通路 | SAI1（M0）I2S | `SAI1_MCLK/SCLK/LRCK/SDO2/SDI0`（模组 pin 304..308） |
| MCLK | `mclkout_sai1` = 12.288MHz（DTS） | — |
| 喇叭功放 | **AW8010BFCR**（U0903，2.85W Class-D） | 输出 VOP/VON → **J0901**；使能 = `SPK_SD_3V3`（模组 pin299 = `GPIO4_B2`） |
| 板载 MIC | MEMS MIC（U0902） | 接 ES8389 MIC 输入 |
| 耳机座 | J0902（PJ35A063，3.5mm，6Pin） | 耳机检测 = `HPH_DET_3V3`（模组 pin358 = `GPIO2_D6`） |
| 耳机按键/ADC | SARADC4 | 见下方 io-channels |
| Codec 电源 | `CODEC_PWTR_EN` = `GPIO0_C6`（模组 pin40）= **Codec DVDD 使能** | Codec 的 VCC3V3 由模组 LDO4_3V3 供，**需手动开** |
| BT 语音 | SAI2（M0）PCM ↔ FCS960K PCM | `BT_SAI2_*`（模组 pin 231..234） |
| HDMI 音频 | `&hdmi_sound`（`okay`） | 支持；`aplay -l` 有 `card N: rockchiphdmi`，见 §5 |

**⚠️ 注意**：Codec 有**两路**供电（DVDD 与 VCC3V3）。VCC3V3 来自模组 LDO4_3V3，
DTS 里没自动开，只靠 pinmap 提示"需要手动开启此电源供电"；排查"Codec probe 不到/I2C 无响应"时先量这两路。

## 2. DTS 结构（`rk3576-quectel-pi-m2-audio.dtsi`）

```dts
es8389_sound: es8389-sound {
    compatible = "rockchip,multicodecs-card";
    rockchip,card-name = "rockchip-es8389";
    rockchip,mic-source-switch;                 /* 允许运行期切板载MIC/耳麦 */
    hp-det-gpio = <&gpio2 RK_PD6 GPIO_ACTIVE_HIGH>;   /* 被文件后半段覆盖为同一值 */
    io-channels = <&saradc 4>;  io-channel-names = "adc-detect";  /* 后半段覆盖 */
    keyup-threshold-microvolt = <595000>; poll-interval = <100>;
    spk-con-gpio = <&gpio4 RK_PB2 GPIO_ACTIVE_HIGH>;  /* 喇叭 PA 使能 */
    rockchip,pre-power-on-delay-ms = <30>;
    rockchip,post-power-down-delay-ms = <40>;
    rockchip,format = "i2s"; rockchip,mclk-fs = <256>;
    rockchip,cpu = <&sai1>; rockchip,codec = <&es8389>;
    rockchip,audio-routing = "Headphone","HPOL", "Headphone","HPOR", "Speaker","HPOL", "Speaker","HPOR";
    pinctrl-0 = <&hp_det &speak_pa_en_active>;
    play-pause-key { label="playpause"; linux,code=<KEY_PLAYPAUSE>; press-threshold-microvolt=<33000>; };
    vol-up-key    { label="vol_up";    linux,code=<KEY_VOLUMEUP>;   press-threshold-microvolt=<110000>; };
    vol-down-key  { label="vol_down";  linux,code=<KEY_VOLUMEDOWN>; press-threshold-microvolt=<195000>; };
};

&i2c2 {                                /* 400kHz，与 RTC 共用 */
    es8389: es8389@10 { compatible = "everest,es8389"; reg = <0x10>;
        clocks = <&mclkout_sai1>; assigned-clock-rates = <12288000>;
        pinctrl-0 = <&sai1m0_mclk>; };
};

codec_vdd3v3: codec_vdd3v3 {           /* GPIO0_C6 使能 Codec DVDD */
    compatible = "regulator-fixed"; gpio = <&gpio0 RK_PC6 GPIO_ACTIVE_HIGH>; regulator-always-on;
};

&sai1 { rockchip,sai-tx-route = <2 1 0 3>; pinctrl-0 = <&sai1m0_lrck &sai1m0_sclk &sai1m0_sdi0 &sai1m0_sdo2>; };
&sai2 { /* BT PCM */ };
&hdmi_sound { status = "okay"; };        /* HDMI 音频，见 §5 */
&sai6 { status = "okay"; rockchip,sai-tx-route = <0 1 2 3>; };

pdmics / pdm_mic_array → status = "disabled"（M2 不用 PDM 麦阵）
bt_sco / bt_sound        → "delta,dfbmcs320" + simple-audio-card，format = "dsp_b"
```

要点：
- `io-channels = <&saradc 4>` — 耳机/按键共用一个 ADC 通道（多级电阻分压），
  `press-threshold-microvolt` 分别是 33mV / 110mV / 195mV（playpause / vol_up / vol_down），
  `keyup-threshold-microvolt = <595000>`。**这些阈值是经验值，换耳机座/改硬件后必须实测重标**。
- 文件里 `es8389_sound` 节点被**定义两次片段覆盖**（前半段 `saradc 3`，后半段 `saradc 4`），
  改的时候注意别只改一处。

## 3. 使用

```bash
# 声卡/路由
aplay -l ; arecord -l ; amixer -c 0 controls | head -40
# 板级自测（M2 用 es8389-sound，pulseaudio 路径见 /usr/share/alsa-card-profile/mixer/...-es8389-m2.conf）
qpi-test audio headset     # 耳麦录音 + 耳放回放（8 步流程，会打印每步）
qpi-test audio speaker     # 板载 MIC 录音 + 耳放回放

# 手工
amixer -c 0 cset name='PGAL Select' '<val>'      # 输入源选择（耳机麦/板载麦）
amixer -c 0 cset name='ADCL PGA Volume' 6        # 18dB
amixer -c 0 cset name='ADCL Capture Volume' 230  # +19.5dB
parecord -d <dev> --file-format=wav /tmp/a.wav & sleep 5; kill -INT %1
paplay /tmp/a.wav
```

### 应用层

- **PulseAudio / PipeWire 配置**（板上路径，均已核对存在）：
  - `/usr/share/alsa-card-profile/mixer/profile-sets/quectel-pi-m2-es8389.conf`
  - `/usr/share/alsa-card-profile/mixer/paths/analog-{output-es8389-m2,input-internal-mic-es8389-m2,input-headset-mic-es8389-m2,output-headphones-es8389-m2}.conf`
  - `/usr/share/pulseaudio/alsa-mixer/profile-sets/quectel-pi-m2-es8389.conf`
    及 `/usr/share/pulseaudio/alsa-mixer/paths/` 下同名 paths
  - `/usr/share/wireplumber/scripts/quectel/bluetooth-mic-gain.lua`（BT 麦增益）
  - HDMI：`/usr/share/alsa/ucm2/rockchip-hdmi1/`（UCM）
- **`qpi-test` 里的 sink/source 名**：
  `alsa_output.platform-es8389-sound.analog-stereo` / `alsa_input.platform-es8389-sound.analog-stereo`，
  port 名 `analog-output-headphones-es8389-m2` / `analog-input-internal-mic-es8389-m2`。
  这些名字必须与实际 `.conf` 对上，否则 `pactl set-sink-port` 会静默失败。
- **播放器**：GNOME 录音机（gnome-sound-recorder）默认安装。

## 4. 常见问题 → 排查顺序

| 现象 | 先看哪里 |
|---|---|
| `aplay -l` 没声卡 | `i2cdetect -y 2` 是否有 0x10；`CODEC_PWTR_EN`(GPIO0_C6) 与模组 LDO4_3V3 两路电；dmesg 里 es8389 probe |
| 有卡但没声音 | `spk-con-gpio`(GPIO4_B2) 是否被拉高；音量是否 0dB；ALSA 路由（`rockchip,audio-routing`） |
| 耳机插了但还从喇叭出 | `HPH_DET`(GPIO2_D6) 电平；**插入时应用层必须关 PA**（pinmap 明确要求） |
| 耳机录音/板载录音声音太小 | 提 `ADCL/ADCR PGA Volume`（6=18dB）与 `ADCL/ADCR Capture Volume`（230=+19.5dB） |
| 喇叭有 POP 音 | pinmap 建议：**播完音频后关闭 PA**；`rockchip,post-power-down-delay-ms` 调大 |
| 默认音量偏大 | 默认已从 0dB 改为 -6dB，并在 ALSA 路径里固定 DAC 音量 |
| 按键（耳机线控）不响应 | `io-channels = <&saradc 4>` 与阈值（33000/110000/195000 µV）实测重标 |

## 5. 扩展场景

- **蓝牙通话/音乐**：`SAI2 ↔ FCS960K PCM`（`bt_sound`, format `dsp_b`）。上电时序和 rfkill 见
  `wireless/SKILL.md`。
- **HDMI 音频（支持，默认开启）**：`rk3576-quectel-pi-m2-audio.dtsi:170` 是 `&hdmi_sound = okay`，
  配合同文件 `&sai6`（`okay`、`rockchip,sai-tx-route = <0 1 2 3>`）与 `&hdmi`（`okay`）即可出卡：
  `aplay -l` 有 `card N: rockchiphdmi`，播放走 `rockchip-hdmi1` UCM。
  这是整条 include 链里唯一一处 `&hdmi_sound` 覆盖（`rk3576-evb.dtsi` 定义该节点时没写 status，默认就绪），
  没有别的 dtsi / overlay 会关掉它；`DRM_DW_HDMI_I2S_AUDIO`、`SND_SOC_ROCKCHIP_I2S_TDM`
  在 `rockchip_linux_defconfig` 里已 `=y`，不用动配置。
  本仓库编出的 dtb 与板载 boot 分区那份逐字节相同（`/hdmi-sound` = okay）。
  排查：① `cat /proc/device-tree/hdmi-sound/status` 应为 `okay`；② `aplay -l | grep -i hdmi`；
  ③ 未接 HDMI 屏时声卡仍在，只是没有 sink 输出。
- **USB 声卡/耳机**：走 USB HUB（`usb/SKILL.md`），无需 DTS 改动。
- **多路同时输出**：`es8389_sound` 用 `rockchip,multicodecs-card`，可以加 DAI link 做 HDMI + Codec 同播，
  但要注意时钟域（SAI1 vs HDMI 内部时钟）。
- **换 Codec**（比如换成 ES8316）：参考板上 `/usr/share/alsa/ucm2/rockchip-es8316/` 的 UCM，
  DTS 上把 `rockchip,codec`、I2C 地址、`audio-routing` 全换，别只改一处。

## 6. 不要做的事

- 不要用 `sed` 改 `*-audio.dtsi`（文件里有同名节点被覆盖两次，全局替换会改错地方）。
- 不要把另一块板的 audio dtsi 抄过来：M2 的 PA 使能脚、耳机检测脚、电源使能脚都不同
  （另一块板用的是 `CODEC_PWTR_EN` 之外的另一套映射）。
- 不要假定 `SPK_SD_3V3` 还可以当 `PCIE1_RST_N` 用 —— M2 上它**就是**喇叭 PA 使能
  （DTS 里专门把 `vbus5v0_typec_evb` 停掉、删掉 `u2phy1_otg` 的 vbus-supply 来腾出 `GPIO4_B2`）。
