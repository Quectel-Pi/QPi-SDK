---
name: simple-h1-flash
description: "simple-h1 SDK 烧录: USB EDL 模式烧录固件"
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [qualcomm, qcs6490, quectel, flash, edl, qdl]
---

# simple-h1 烧录指南

## 一键烧录

```bash
cd /home/igni/Downloads/debian/simple-h1
./scripts/flash.sh        # UFS (默认)
./scripts/flash.sh emmc   # eMMC
```

脚本自动: 检测 ADB → `adb shell reboot edl` → 等待 9008 → qdl 烧录。

## 手动烧录

```bash
# 1. 进入 EDL (必须 adb shell reboot edl!)
adb shell reboot edl

# 2. 等待 9008 设备
lsusb | grep 05c6:9008

# 3. 执行 qdl
cd build/output
sudo ../tools/qdl -s ufs -i . \
  prog_firehose_Qcm6490_ddr.elf \
  partition_ufs/rawprogram[0-5].xml partition_ufs/patch[0-5].xml
```

## 故障排除

| 现象 | 处理 |
|------|------|
| qdl: failed to claim USB interface | 断电板子→重新上电→确认进 EDL→重试 |
| 等待 9008 超时 | 检查 USB 连接; `adb shell reboot edl`; 或断电重上电 |
| 烧录中断 | 断电→重新进 EDL→重新烧录 |

**禁止**: 不要修改 flash.sh，不要 kill 进程。
