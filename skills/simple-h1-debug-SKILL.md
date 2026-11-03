---
name: simple-h1-debug
description: "simple-h1 SDK: 板级调试 — 串口/adb 通道、dmesg/journalctl、panic 抓取、可用调试设施与本配置的缺项"
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [qualcomm, qcs6490, quectel, simple-h1, debug, adb, serial, dmesg, panic]
    related_skills: [simple-h1-kernel, simple-h1-driver]
---

# 板级调试通道

## 0. 先确认板上跑的是不是本 SDK 的镜像

```bash
uname -r          # SDK 产物应为 6.6.116-qli-1.7-ver.1.1
cat /proc/cmdline # SDK: root=/dev/disk/by-partlabel/system ... console=ttynull net.ifnames=0
ls /lib/modules   # 应只有一个与 uname -r 一致的目录
```

- 三条对不上（例如 `6.6.52-debug`、`root=/dev/sda3`、多出一个 `6.6.52-qli-1.3-ver.1.1` 目录），
  说明板子上跑的是别的镜像：**模块路径、预置 ko、cmdline 相关结论都不适用**，只能验证硬件与
  DTS 层事实；要验证 SDK 结论必须先烧 SDK 产物。
- 两个实测样本：
  * A = Debian 13 + `6.6.52-debug`，`root=/dev/sda3`，`console=ttyMSM0`，`/lib/modules` 多一个 `6.6.52-qli-1.3-ver.1.1`；
  * B = qcom-wayland 1.7-ver.1.1 + `6.6.116-qli-1.7-ver.1.1`，cmdline 与 SDK 完全一致（末尾多 `gnome.is_vm=0`），
    `/lib/modules` 只有 `6.6.116-qli-1.7-ver.1.1` 与 `quectel-wifi`。
- 本文“实测 A/B”标注即对应这两个镜像；**同一块板换镜像后，connector 名、模块名、用户态命令都会变**，按第 0 节先认镜像。

## 1. 调试串口

| 项 | 值 |
|---|---|
| 内核 console | `aliases { serial0 = &uart5; }` + `stdout-path = "serial0:115200n8"` (DTS:38/46) |
| 波特率 | 115200 |
| 其它串口 | `serial1 = &uart7` (蓝牙), `serial2 = &uart12`, `hsuart0 = &uart4` |

```bash
picocom -b 115200 /dev/ttyUSB0     # 或 minicom -D /dev/ttyUSB0 -b 115200
```

串口是唯一能在内核早启动、panic、卡死时看到输出的通道; 起不来优先接串口。

## 2. adb

`tools/adb` 是 Linux x86-64 动态链接二进制, **实测在未装 libadb 的宿主上直接报错**
`error while loading shared libraries: libadb.so.0`（`ldd tools/adb` 可见 libadb.so.0 / libbase.so.0 not found）。
先 `tools/adb devices`, 失败就改用系统 adb (`adb`, 来自 android-tools 或 Android SDK platform-tools)。下文用 `adb`。

```bash
adb devices
adb shell dmesg | tail -50
adb push x /tmp/ && adb shell "chmod +x /tmp/x && /tmp/x"
adb pull /var/log/syslog ./
```

**重启铁律**:

```bash
adb shell reboot        # 重启系统 (adb reboot 无效)
adb shell reboot edl    # 进 EDL (adb reboot edl 无效)
```

## 3. 日志

```bash
dmesg -w | grep -iE 'error|fail|probe|defer'     # 实时
journalctl -b -k --no-pager | tail -100           # 本次启动内核日志
journalctl -b --no-pager | grep -iE 'agm|audio|drm|lt9611'   # 用户态服务日志
zcat /proc/config.gz | grep -E 'CONFIG_<项>'      # 核对实际内核配置
```

- 音频/显示这类用户态组件 (AGM/PipeWire/gnome-shell) **dmesg 里几乎没有**, 必须看
  `journalctl`。
- 内核版本: `uname -r` 应为 `6.6.116-qli-1.7-ver.1.1`。
- 抓到的日志放仓库根 `log/` (已被 `.gitignore` 忽略), 不要散在 `build/` 里。

## 4. panic / 卡死

本配置 **`# CONFIG_PSTORE is not set`**, 没有 `/sys/fs/pstore`, panic 现场不会落盘;
只能靠串口抓, 或者 panic 后设备进 900e (9008 相关) 重新进 EDL 全盘烧录恢复。

```bash
# 手上只有 dmesg 文本时, 用树内脚本还栈帧
cd kernel
scripts/decode_stacktrace.sh vmlinux < log/panic.txt
# 已知地址时
scripts/faddr2line vmlinux <symbol>+0x...
```

`CONFIG_DEBUG_INFO=y`, 所以只要能拿到对应那次构建的 `build/kernel/vmlinux`,
符号能对上; 换了内核就必须用同一份 vmlinux。

## 5. 本配置可用的调试设施

| 设施 | 状态 | 用法 |
|------|------|------|
| `dmesg` / printk | 可用 | 主力手段 |
| `sysrq` (`CONFIG_MAGIC_SYSRQ=y`) | 可用 | `echo t > /proc/sysrq-trigger` (任务栈, 实测会在 dmesg 留痕), `echo m` (内存), `echo c` (强制崩溃); 值按镜像: 实测 A=438 / B=16 |
| `debugfs` (`CONFIG_DEBUG_FS=y`) | 可用 | `/sys/kernel/debug/...` (clk_summary、dri/0/bridge_chains 等) |
| ftrace 框架 (`CONFIG_FTRACE=y`) | 基本不可用 | `available_tracers` 实测**只有 `nop`**; 函数/调度/irqsoff 跟踪器都没开 |
| kprobe (`CONFIG_KPROBES=y`) | 可用 | tracefs 的 kprobe_events 可挂动态探针 |
| `CONFIG_DYNAMIC_DEBUG` | **未开** | `dev_dbg()/pr_debug()` 被编译掉, 现场看不到 |
| `CONFIG_DEVMEM` | **未开** | 没有 `/dev/mem`, 不能用 devmem2 读寄存器 |
| `CONFIG_PSTORE` | **未开** | 没有持久化 panic 日志 |

所以"不改内核就想加日志"的手段有限: 首选加 `dev_info/pr_info` 重编 (见 `simple-h1-kernel`),
次选 kprobe 事件。

## 6. 常用运行态检查

```bash
cat /proc/device-tree/model                 # 板型
ls /sys/class/drm/                          # 显示连接器
cat /proc/asound/cards; cat /proc/asound/pcm # 声卡
lsmod; modinfo <模块>                       # 模块
for c in /sys/class/thermal/thermal_zone*; do \
  echo "$c $(cat $c/type) $(cat $c/temp)"; done
cat /sys/kernel/debug/clk/clk_summary | head -40
```

显示通路判断以 `/sys/kernel/debug/dri/0/bridge_chains` 为准 (详见 `simple-h1-display`)。

## 7. 抓屏

```bash
adb shell "pgrep -a gnome-shell"     # 确认 GNOME 会话
adb shell "sudo -u <登录用户> DISPLAY=:0 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u <登录用户>)/bus \
  gnome-screenshot -f /tmp/shot.png"
adb pull /tmp/shot.png log/
```

- 需要板上装了 `gnome-screenshot` —— **实测镜像里没有**（`command -v gnome-screenshot` 为空），要先 apt 装; GDM 登录界面禁止截图。
- 没有截图工具时的替代: `gst-launch-1.0 v4l2src device=/dev/video32 ! jpegenc ! filesink location=/tmp/f.jpg` 只能抓编码器帧, 抓桌面意义不大, 通常直接接显示器看。
- 命令行看不到图时, 直接把 png 拉回主机看。

## 8. 陷阱

| 陷阱 | 说明 |
|------|------|
| `adb reboot` | 不生效, 必须 `adb shell reboot` |
| 依赖 pstore 抓 panic | 本配置没开, 白等; 接串口 |
| 用宿主 `uname -r` 当设备版本 | 模块路径会错; 用 `adb shell uname -r` |
| `dev_dbg` 打点 | 编译时被丢弃, 现场没有输出 |
| 拿旧 vmlinux 解新 panic | 地址对不上, 必须同一构建产物 |
| 日志写在 `/tmp` | 重启即丢; 需要留档就拉到主机 `log/` |
