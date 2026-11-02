# Quectel M2 SDK Skills（AI 技能包）

本目录为 Quectel M2 SDK 配套的 **AI 技能**（SKILL.md），供 AI 助手（VS Code Copilot / Claude Code 等）按需加载，覆盖 SDK 全生命周期操作。

## 技能列表

### 一、SDK 操作类（sdk-*）

| 技能 | 用途 | 目录 |
|------|------|------|
| **sdk-build** | 编译 app / kernel / overlays / 完整固件 | `sdk-build/` |
| **sdk-flash** | 烧录固件/分区 | `sdk-flash/` |
| **sdk-overlays** | 设备树 overlay 编写/编译/打包 | `sdk-overlays/` |
| **sdk-board-test** | 上板验证 / 冒烟测试 / ADB 部署 | `sdk-board-test/` |

### 二、M2 板级外设类（15 份）

按外设分类，内容为 **M2 实际硬件事实**（板级 DTS 核对 + 上板实测校订，2026-10-10）。
入口是 `peripherals-overview`，其余按外设进入。本 SDK 就是 M2 SDK，故目录直接用外设名，不再带板型前缀。

| 技能 | 覆盖 | 目录 |
|------|------|------|
| **peripherals-overview** | ★入口：外设→器件→连接器→GPIO、电源使能矩阵、板卡标识 | `peripherals-overview/` |
| **display** | MIPI-DSI 屏适配 + 触摸 + 原生 HDMI | `display/` |
| **camera** | 双 MIPI-CSI（IMX219/IMX477/S5K3L6B/S5K3P9B）+ 产测二维码 | `camera/` |
| **audio** | ES8389 codec + AW8010 功放 + 耳机检测 + HDMI/BT 音频 | `audio/` |
| **usb** | USB0 OTG 3.1SS + CH634M HUB + 3×USB-A + Type-C(仅供电) | `usb/` |
| **ethernet** | YT8531 + GMAC0 + 40Pin 第二路 RGMII1 | `ethernet/` |
| **wireless** | FCS960K/AIC8800 SDIO Wi-Fi + BT UART4 + FCT 射频 | `wireless/` |
| **storage** | eMMC/TF 卡(UHS-I，无热插拔)/exFAT/自动挂载/NVMe | `storage/` |
| **pcie** | PCIe0：5G 模组 HAT（Quectel MHI）/ NVMe 二选一 | `pcie/` |
| **rtc-keys** | AIP8563 RTC(@0x51) + PON/PWRKEY/VOL_UP/ADC 键 | `rtc-keys/` |
| **fan-thermal** | PWM1 风扇（hwmon）+ thermal 温控 | `fan-thermal/` |
| **led** | PWM0 板载指示灯（裸 PWM sysfs） | `led/` |
| **40pin** | 40Pin 引脚表 + `qpi-config` 功能复用 + 扩展 | `40pin/` |
| **power-pm** | 电源使能链 + S3 深睡唤醒 + 关机/重启 | `power-pm/` |
| **debug-fct** | DBG 串口 + 下载模式 + ADB + AT 全集 + qpi-test/FCT | `debug-fct/` |

说明：

- 分册之间的互引用写成 `<技能>/SKILL.md`，可直接点开。
- 分册只引用本仓库里真实存在的文件/路径；板上的文件用绝对路径（`/usr/bin/...`）标注"板上"。

### ★ 读这份库之前：本仓库的路径与入口

板级事实一律以本仓库的 `kernel/` + `tools/` + `overlay/` 为准：

| 要用的东西 | 本仓库位置 |
|---|---|
| 内核源码、板级 DTS、内核配置片段 | `kernel/`（`arch/arm64/boot/dts/rockchip/`、`arch/arm64/configs/`） |
| 构建入口 | `build.sh`（可直接 `./build.sh kernel`）+ `tools/build-kernel.sh` / `tools/build-rootfs.sh` |
| 内核配置片段清单 | `tools/build-kernel.sh` 的 `KERNEL_FRAGMENTS`；本仓库没有 defconfig |
| rootfs 文件覆盖 | `overlay/`（目录结构即 rootfs 路径） |
| 设备树 overlay | 内核内建 `kernel/arch/arm64/boot/dts/rockchip/*-disable.dts`、`-can0-enable.dts`；SDK 自有 `overlay/*.dts` |
| 烧录工具 | `tools/flash/{linux,mac,windows}/upgrade_tool`（rockusb） |
| dtbo 产物 | 打包写入 rootfs `/boot/overlays/`；板上实测在 `/usr/share/qpi-config/overlays/` |
| 板级工具（板上） | `/usr/sbin/qpi-config`、`/usr/bin/qpi-test`、`/usr/bin/bt-tty`、`/usr/bin/port_bridge` |

上板实测在 Debian 13.7 / 内核 `6.1.118-rt36` 上完成（本 SDK 版本串见 `tools/VERSION.txt`）。
**板载 dtb 的关键节点取值**：`/hdmi-sound` = `okay`、`/dp0-sound` = `disabled`、`/es8389-sound` = `okay`
（从 boot 分区取出 dtb 用 `fdtget` 读得）。DTS 取这两个值后，`kernel/` 编出的
`rk3576-quectel-pi-m2-linux.dtb` 与板载那份**逐字节相同**（302316 字节）。改完 DTS 可用
`make ARCH=arm64 rockchip/rk3576-quectel-pi-m2-linux.dtb` + `fdtget` 复核。

## 使用方式

`skills/` **不在 agent 的自动发现目录里**（Hermes 只认 `.hermes/skills/`、`.agents/skills/`），
需要**显式读取对应分册**再动手：按上表或 `description` 里的关键词选中分册，
读 `skills/<分册>/SKILL.md` 全文后照做。例如「编译固件」→ 读 `sdk-build/SKILL.md`；
「烧录板子」→ `sdk-flash/SKILL.md`；「喇叭没声」→ `audio/SKILL.md`。
不要凭分册标题猜用法，分册里写的是本仓库的实际命令与值。

## 与构建脚本的关系

```
用户需求 ──→ AI 加载 Skill ──→ 调用 SDK 脚本 / 工具
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
            tools/build-*.sh    烧录工具           adb
             (编译/打包)        (烧录)             (上板验证)
```

## 对齐《QPi 开发者罗盘》

本文档的 Skill 层对应罗盘设计中的 AI Skill 能力：

| 罗盘 Skill | 本 SDK 对应 |
|-----------|------------|
| SDLC 编排器 | （多 skill 组合：build → flash → board-test） |
| 需求评估 | （文档/模板查询） |
| 驱动/系统适配 | `sdk-overlays`（外设启用/禁用） |
| Bug 定位 | `sdk-build`（编译错误分析）+ 外设知识库 |
| 上板验证 | `sdk-board-test` |
| 竞品开源调研 | （非 SDK 范围） |

## 新增 Skill 规范

1. 创建目录 `skills/<skill-name>/SKILL.md`
2. 前置 YAML frontmatter 必须包含：
   - `name`：小写连字符命名，与目录名一致
   - `description`：**关键词丰富**的触发描述（含中英文触发词）
   - `metadata.version`：语义化版本
3. 正文用「何时使用 → 工作流程 → 常见坑」结构
