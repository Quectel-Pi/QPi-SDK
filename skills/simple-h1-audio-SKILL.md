---
name: simple-h1-audio
description: "simple-h1 SDK: 排查 H1 (QCS6490) 无声/喇叭断续/耳机不切换，用 journalctl 看 AGM/GSL、tinymix 配通路、核对 WCD9370+AW8010 DTS"
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [qualcomm, qcs6490, quectel, simple-h1, audio, wcd9370, aw8010, pal, agm, tinymix]
---

# H1 音频 — WCD9370 + AW8010 功放 + PAL/PipeWire/AGM

板级 DTS: `kernel/arch/arm64/boot/dts/qcom/qcs6490-idp-pi.dts`（2254 行，下文简称 DTS，行号已核对）。
Codec 驱动: `kernel/sound/soc/codecs/wcd937x.c`、`wcd937x-sdw.c`；APM/AFE: `kernel/sound/soc/qcom/qdsp6/`。

## 1. 硬件事实（原理图 p05 codec / p06 功放·MIC·喇叭座）

| 功能 | 器件 | 连接 / 引脚（DTS） |
|---|---|---|
| 音频 Codec | **WCD9370**（SoundWire codec，`qcom,wcd9370-codec`） | `reset-gpios=tlmm83`、`power-gpios=tlmm68`、`us-euro-gpios=tlmm8`（DTS:299-325） |
| Codec 供电 | `vdd-buck=vreg_l17b_1p7`、`vdd-rxtx/vdd-px=vreg_l18b_1p8`、`vdd-mic-bias=vreg_bob_3p296` | DTS:311-314 |
| MIC BIAS | MICBIAS1/2/3 = **1.8 V** | `qcom,micbias{1,2,3}-microvolt = <1800000>`（DTS:316-318） |
| 模拟 MIC | `AMIC1/2/3`（差分对） | 板载 MIC 与耳机麦各占一路 |
| 板载数字 MIC | **MSM261DDB020** MEMS | LPI DMIC1 |
| 扬声器功放 | **AW8010BFCR**（模拟功放，内核无独立驱动） | 使能 = `lpass_rx_macro` 的 `pa-gpios = tlmm142`（DTS:694-697；消费点 `kernel/sound/soc/codecs/lpass-rx-macro.c:3657`） |
| 模拟开关 | SGM3718YUWQ10G | 耳机/扬声器切换路径 |
| 喇叭座 | **`J0701` / `J0702`**（2-pin 1.25 mm） | — |
| 耳机座 | 3.5 mm（国标/美标） | `us-euro-gpios = tlmm8` 做国标/美标切换（pinctrl `us_euro_hs_sel` DTS:1594） |
| HDMI 音频 | LT9611 内置 I2S → **Primary MI2S（SD0）** | `hdmi_audio` + `hdmi-dai-link`（DTS:234-256） |
| DP 音频 | MDSS DP | `dp-dai-link`（DTS:222-232） |
| BT 音频 | A2DP / SCO | PipeWire 端口 `bta2dp-out` / `btsco-out` |

**⚠️ WSA 智能功放不可用**：`&swr2`（含 `left_spkr`/`right_spkr`，`sdw10217020200`，powerdown gpio63/62）
在本板 DTS 里是 `status = "disabled"; //for PCIE1`（DTS:1353-1354），SWR2 管脚让给了 PCIe1。
**H1 的喇叭走 AW8010 模拟功放，不是 WSA 数字功放**，对应的 `wsa-dai-link`/`vi-feedback-dai-link` 也被整段注释（DTS:159-172、209-220）。

### 声卡结构（`sound: sound`，DTS:137-256）

| DAI link | 行号 | 内容 |
|---|---|---|
| `wcd-playback-dai-link` | 173-183 | `RX_CODEC_DMA_RX_0` → `wcd9370 0` + `swr0 0` + `lpass_rx_macro 0` |
| `wcd-capture-dai-link` | 185-195 | `TX_CODEC_DMA_TX_3` → `wcd9370 1` + `swr1 0` + `lpass_tx_macro 0` |
| `va-dai-link` | 197-208 | `VA_CODEC_DMA_TX_0` → `lpass_va_macro`（语音唤醒） |
| `dp-dai-link` | 222-232 | `DISPLAY_PORT-RX` → `mdss_dp` |
| `hdmi-dai-link` | 234-256 | `MI2S-LPAIF-RX-PRIMARY` → `hdmi_audio`，**必须带 `qcom,optional-dai-link`**（DTS:242） |

`audio-routing`（DTS:141-158）关键对：`IN1_HPHL↔HPHL_OUT`、`IN2_HPHR↔HPHR_OUT`、`IN3_AUX↔AUX_OUT`、
`AMIC2↔MIC BIAS2`、`TX DMIC0/1/2↔MIC BIAS1/2/3`、`VA DMIC0-3↔VA MIC BIAS1/3`。

### HDMI I2S 走 SD0（两侧必须一致）

- DTS 侧：`&msm_stub_codec { qcom,sd-lines = <0>; }`（DTS:2248-2254），注释即"LT9611 I2S data on SD0 (gpio98)"。
- 用户态 AGM 侧把 Primary MI2S 映射到 SD0；不一致 → HDMI 有声卡但没声音（或 `-131`）。
- 解析点：`kernel/sound/soc/qcom/qdsp6/q6afe-dai.c:995` 读 `qcom,sd-lines`。
- MI2S0 引脚（DTS:1199-1241）：`gpio96(mclk)/97(sclk)/98(data0)/99(data1)/100(ws)`，
  `&tlmm` 的 default pinctrl 就配成 MI2S 功能（"Default to MI2S function so HDMI I2S is always routed to LT9611"）。

## 2. 软件栈

```
应用 (pactl / paplay / parec / gst)
  └── PipeWire|PulseAudio ── PAL 插件（pw-pal / qcom-pal, 用户态）
        └── AGM / APM ── ADSP (adsprpcd)
              └── WCD9370 (SoundWire) / LPASS macros / AW8010 PA / LT9611 I2S
```
声卡名：`/proc/asound/cards` → `qcm6490-idp-snd-card`（`compatible = "qcom,qcm6490-sndcard"`，DTS:138-139）。
内核配置（`scripts/kernel-config`）：`CONFIG_SND_SOC_WCD937X=y`、`CONFIG_SND_SOC_WCD937X_SDW=y`、
`CONFIG_SOUNDWIRE_QCOM=y`、`CONFIG_SND_SOC_QDSP6*` 全 `=y`（含 `Q6APM`/`Q6APM_DAI`）→ 音频全内建，无 ko 需替换。

## 3. 使用（设备侧）

```bash
cat /proc/asound/cards                    # 期望: qcm6490-idp-snd-card
# 用户态命令按镜像选（实测两块镜像差别很大）:
#   Debian 镜像: 有 pactl / paplay / parec
#   qcom-wayland 镜像: 没有 pactl / paplay / parec, 只有 wpctl / pw-play
wpctl status                               # 实测 B: Sinks = "pal sink speaker" / "pal sink hdmi audio"
                                           #         Sources = "pal source handset mic"
pw-play /tmp/tone.wav                      # 实测 B: rc=0, dmesg 出现 rx_macro open/close wcd9370 pa
pactl list short sinks                     # 实测 A: low-latency0 / deep-buffer0 / offload0 / voip-rx0
pactl set-sink-port <idx> speaker          # 切输出端口（仅 Debian 镜像）
wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.5  # PipeWire 等价写法
```

> 下表是 Debian 镜像的 PulseAudio sink 名；**qcom-wayland 镜像只有两个 sink：`pal sink speaker` 与
> `pal sink hdmi audio`**，别照下表硬编码。

| sink | 用途 |
|---|---|
| `low-latency0` | 低延迟（交互/提示音） |
| `deep-buffer0` | 普通音乐/视频 |
| `offload0` | 压缩格式直通（mpeg/aac） |
| `voip-rx0` | 通话 |

> **实测**：`/proc/asound/pcm` 只有 3 个 PCM（RX-0 播放 / TX-3 采集 / VA-TX-0），HDMI 与 DP 的 DAI link
> 没有独立 PCM 节点；`pactl list short sinks` = low-latency0 / deep-buffer0 / offload0 / voip-rx0，
> sources = regular0 / regular2 / voip-tx0，与上表一致；tinymix 里 `AUX_RDAC Switch`、`RX_MACRO RX0 MUX`、
> `RX INT2_1 MIX1 INP0`、`LO Switch` 四个控制名都存在（共 218 个控件）。

## 4. 调试（dmesg 几乎没有音频日志，必须 journalctl）

```bash
journalctl -b --no-pager | grep -iE 'agm|audio|adsp|afe|gpr|glink|pcm|codec|i2s|mi2s'
journalctl -b --no-pager | grep -iE 'configure_i2s_ep|configure_codec_dma|graph_start|graph_prepare|sd_line|lpaif'
journalctl -u pipewire --no-pager | tail -50
cat /proc/asound/pcm
tinymix controls | grep -iE 'MI2S|CODEC_DMA|DISPLAY_PORT|HDMI'   # 必须带子命令: get/set/controls/contents
# ADSP/CDSP 按 name 认, 编号随加载顺序变 (实测 ADSP=3000000.remoteproc, CDSP=a300000.remoteproc)
for r in /sys/class/remoteproc/remoteproc*; do echo "$r $(cat $r/name) $(cat $r/state)"; done
# 实测 A: 只有 2 个 (3000000=ADSP / a300000=CDSP); 实测 B: 4 个, ADSP=remoteproc2, CDSP=remoteproc3
# -> 编号会变, 一律按 name 认
cat /sys/kernel/debug/clk/clk_summary | grep -iE 'mi2s|lpaif|lpass_i2s'
```

**手测播放（先停 PipeWire，否则抢 ADSP）**：
`agmplay` 会**直接抢 ADSP**：PipeWire 在跑时实测报
`mixer_plugin_open: failed to open plugin, err: -131` → `Failed to open mixer`，
而且 **agmplay 失败时仍返回 0**，别用退出码判断成败。

```bash
systemctl stop gdm 2>/dev/null; sleep 2
killall -9 pipewire pipewire-pulse wireplumber 2>/dev/null; sleep 2
ps -ef | grep -i pipe | grep -v grep          # 确认已停

tinymix set "AUX_RDAC Switch" "1"             # speaker 通路必须先设，否则失败
tinymix set "RX_MACRO RX0 MUX" "AIF1_PB"
tinymix set "RX INT2_1 MIX1 INP0" "RX0"
tinymix set "LO Switch" "1"
agmplay /tmp/test.wav -D 100 -d 100 -i "CODEC_DMA-LPAIF_RXTX-RX-0"   # speaker
agmplay /tmp/test.wav -D 100 -d 100 -i "MI2S-LPAIF-RX-PRIMARY"       # HDMI（不需 tinymix）
agmplay /tmp/test.wav -D 100 -d 100 -i "DISPLAY_PORT-RX"            # DP
```

### AGM 错误码

| 错误码 | 含义 | 排查方向 |
|---|---|---|
| `-110` | GSL 等 ADSP 上电超时 | ADSP 未就绪；见坑 1（开机第一声） |
| `-131` | AR_ENOTREADY，ADSP 拒绝配置 | I2S 参数 / `sd_line_idx` / ACDB 拓扑 |
| `-22` | EINVAL | 采样率/声道数/位宽/Channel Map mixer 不存在 |
| `-19` | ENODEV | PCM 设备号不对 |
| `-5` | EIO | PCM 设备打不开 |

典型错误链：`configure_i2s_ep → Graph cfg cmd failure → -131`；
`configure_codec_dma_ep → Invalid mixer control → -22`；`pcm_plug_open: failed to open plugin → -5`。

## 5. 已知坑

| 症状 | 根因 / 处理 |
|---|---|
| 开机后第一次开流失败 → **整个会话扬声器无声**（`pw-play` 返回 0） | 用户态 PAL 插件的 `pal_stream_start()` 失败后走 cleanup 直接返回，而它只在状态**跳变**到 STREAMING 时被调用 → 永不重试。日志特征：`ar_osal_signal_timedwait ... rc = 110` → `gsl_graph_open_sgids_and_connections: Graph open failed:21` → `pal_stream_start ... status -110`。**修复点在 PAL 插件（用户态）**，本 SDK 只能 overlay 替换已有库，不能在此重编；临时绕法：`systemctl restart wireplumber pipewire` 或切一次默认 sink。 |
| **扬声器播放断续/单声道** | speaker 通路必须是双声道：`RX1` + `INT2_2` 与 PAL 双声道配置匹配，只配单声道就会断续 |
| **扬声器底噪** | 需 DAC 采样沿对齐（wcd938x 系列口径）+ 播放结束关闭 AUX DAC |
| **播放后耳机无声** | HPH 上电要恢复 VNEG/BUCK 电源轨 |
| **GNOME 声音面板看不到输入设备** | PAL 采集源 `priority.session` 未生效 |
| **插拔耳机/HDMI/DP 后默认通道不对** | 需守护进程在插拔后写 PAL 默认通道并**回读校验**（被 wireplumber 回写覆盖会静默失效） |
| **GDM 登录后 PipeWire 卡死** | PAL 初始化需串行化 + 按需延迟 |
| **USB-C DP 口没声音** | PAL 端点配置失败要按非致命处理 + ACDB 的 DP 校准参数要对 |
| **完全没声卡（连本地喇叭也没声）** | LCD panel 模式下 `hdmi-dai-link` 不是 optional → 整卡 probe defer（DTS:242，见 display 技能坑 1） |
| **BT 连上了却没声音** | 看 `pactl list sinks` 里 `bta2dp-out`/`btsco-out` 是否 available（需 BT 连上） |

**排查顺序（先拿数据再改代码）**：
```bash
adb shell "cat /proc/asound/cards"
adb shell "pactl list short sinks ; pactl list short sources"
adb shell "wpctl status"
adb shell "dmesg | grep -iE 'wcd9370|swr|pal|agm|lpass|adsp'"
adb shell "journalctl -b --no-pager | grep -iE 'agm|pal_stream|graph_open|sd_line|configure_'"
```

## 6. 适配 / 扩展

- **换 Codec**：WCD9370 是 SWR 器件，换同族（WCD9380/9385）改 `compatible`（DTS:300）+
  `qcom,rx-device`/`qcom,tx-device`（DTS:320-321）+ ACDB 标定；换 I2S 类 Codec 要重写 DAI link，
  并复核 `hdmi-dai-link` 的 optional 逻辑。
- **耳机国标/美标**：`us-euro-gpios = tlmm8`（DTS:308，pinctrl `us_euro_hs_sel` 默认下拉），改检测逻辑别漏这个脚。
- **多路同播**：PAL 按 stream 选 sink（low-latency / deep-buffer / offload）；HDMI + 本地同播要确认
  MI2S(SD0) 与 WCD9370 时钟域不冲突。
- **语音唤醒**：`va-dai-link` + `lpass_va_macro` 已配（DTS:197-208），还需 ADSP 侧模型文件。
- **ACDB 标定数据**在用户态镜像的 `/usr/share/alsa` 与 PAL 配置里，本 SDK 通过 overlay 替换，不在此编译。
- 改 DTS 后下发：`./scripts/build-kernel.sh` → `./scripts/pack-dtb.sh` → `./scripts/pack-efi.sh`（UKI 里也带 dtb）；改内建 codec 驱动走 `./scripts/build-all.sh`。
