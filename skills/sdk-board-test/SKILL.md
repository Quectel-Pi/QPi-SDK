---
name: sdk-board-test
description: "在 Quectel M2 板卡上做上板验证/冒烟测试。覆盖：ADB/串口连接板子、部署编译产物（hello 等 app 到 /opt/m2-app）、运行验证输出、检查系统信息（uname/os-release）、外设连通性快速验证（i2cdetect/ls /dev）。当用户说「上板验证」「烧录后测试」「板子冒烟」「adb部署」「跑一下hello」「验证固件」「部署app到板子」时使用。WHEN: board test, smoke test, adb deploy, run on device, verify firmware, 上板验证, 冒烟测试, adb shell. DO NOT USE FOR: 烧录固件（用 sdk-flash skill），编译（用 sdk-build skill）。"
license: MIT
metadata:
  author: GitHub Copilot
  version: "1.0.0"
---

# Quectel M2 上板验证助手

> 编译完固件烧录后，在板子上快速验证系统是否正常、app 能否运行。

## 前置条件

- 板子已烧录固件并启动（ADB 或串口可达）
- ADB：`adb devices` 能看到设备

## 工作流程

1. **连接确认**

```bash
adb devices                    # ADB 设备列表
adb shell uname -a             # 内核版本 (应含 aarch64)
adb shell cat /etc/os-release  # 系统版本 (Debian)
```

2. **部署 app 产物**（产物由 app 工程自身 Makefile/CMake 输出）

```bash
adb push docs/examples/hello/hello /tmp/hello
adb shell chmod +x /tmp/hello
adb shell /tmp/hello           # 运行, 预期输出 "hello from Quectel M2..."
```

3. **验证固件内容**（确认打包是否生效）

```bash
# 检查 overlay 是否写入
adb shell ls /boot/overlays/

# 检查 app 是否安装进 rootfs
adb shell ls /opt/m2-app/

# 检查内核版本与编译时间
adb shell uname -a
```

4. **外设快速验证**

```bash
adb shell i2cdetect -l         # I2C 总线列表
adb shell ls /dev/i2c-*        # I2C 设备节点
adb shell ls /dev/ttyS* /dev/ttyUSB*  # 串口
```

## 常见坑

- **app 无法运行（No such file）**：检查是否 `chmod +x`，或动态库缺失（交叉编译动态链接）
- **权限**：/opt/m2-app 下文件属 root，用 `adb root` 或 su 执行
- **overlay 没生效**：确认是重打包后的固件（仅编译内核不打包不生效）
- **串口 vs ADB**：串口需正确波特率（通常 115200）；ADB 更稳定适合自动化

## 验证清单（冒烟）

- [ ] `uname -a` 显示 aarch64 + 预期内核版本
- [ ] `cat /etc/os-release` 显示 Debian
- [ ] hello 程序可运行并输出
- [ ] `/boot/overlays/` 有预期 dtbo
- [ ] 外设节点存在（I2C/串口/GPIO）
