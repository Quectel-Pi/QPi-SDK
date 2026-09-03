---
name: simple-h1-build
description: "simple-h1 SDK: 内核编译打包 + overlay 文件系统定制"
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [qualcomm, qcs6490, quectel, simple-h1, kernel, overlay, build]
---

# simple-h1 SDK 构建指南

## 核心概念

simple-h1 脱离 Yocto，仅两个功能：
1. **内核编译打包** → efi.bin (UKI: Image + dtb + initramfs)
2. **overlay 文件系统定制** → system.img

## 常用命令

### 环境
```bash
cd /home/igni/Downloads/debian/simple-h1
source scripts/env.sh     # 原生入口
# 或推荐: source build.sh   (与 QPi-SDK/M2 命令兼容层, 自动 source env.sh)
```

> M2 兼容命令 (同一套命令在 simple-h1 与 QPi-SDK/M2 通用):
> source build.sh 后 → buildcheck/buildkernel/buildboot/buildoverlays/buildrootfs/
> buildall/buildmenuconfig/builddefconfig/buildclean/newapp/buildapp; 或
> make check|kernel|boot|rootfs|all|clean|...; 或 ./tools/build-kernel.sh <子命令>
> / ./tools/build-rootfs.sh <子命令>。映射: buildkernel→scripts/build-kernel.sh,
> buildboot→pack-efi.sh+pack-dtb.sh, buildrootfs→pack-system.sh,
> buildall→build-all.sh (SKIP_KERNEL=1 语义保留)。

### 内核编译
```bash
./scripts/build-kernel.sh          # 编译 Image + dtb + modules
./scripts/build-kernel.sh clean    # 清理重编
```
- 产物: `build/kernel/arch/arm64/boot/Image`
- DTB: `build/kernel/arch/arm64/boot/dts/qcom/qcs6490-idp-pi.dtb`
- 模块: `build/modules-staging/lib/modules/6.6.116-qli-1.7-ver.1.1/`

### 应用层定制 (overlay)
在 `overlay/` 按根文件系统路径放文件即可。示例：
- `overlay/usr/local/bin/xxx` — 应用
- `overlay/etc/systemd/system/xxx.service` — 服务
- `overlay/lib/modules/6.6.116-qli-1.7-ver.1.1/updates/xxx.ko` — 驱动模块
- `overlay/overlay-remove.list` — 删除清单（每行一个路径，支持 # 注释）
- `hooks/*.sh` — 打包前钩子（root 执行，chmod/cp/ln 等最后调整，见 `hooks/README.md`）

从源码安装应用:
```bash
./scripts/install-app.sh apps/<app目录> [PREFIX=/opt/xxx]
```

### 全量打包
```bash
SKIP_KERNEL=1 ./scripts/build-all.sh   # 仅打包镜像 (快)
./scripts/build-all.sh                 # 完整 (含内核编译)
```
输出: `build/output/{efi.bin, dtb.bin, system.img}` + 烧录所需全部文件

### 烧录
```bash
./scripts/flash.sh     # adb shell reboot edl → 9008 → qdl (UFS)
```

## 注意事项

- 编译由用户手动执行；Agent 修改源码/overlay 后提示用户编译
- 内核编译约 10-30 分钟；纯 overlay 打包约 2-3 分钟
- 内核版本串固定为 `6.6.116-qli-1.7-ver.1.1`，改 `scripts/env.sh` 的 LOCALVERSION 可变更
- 外置驱动 (yt6801/r8168/wlan/qca6490 等) 已在 overlay 中预置 ko，不随内核编译
- 烧录需 sudo；设备进 EDL 用 `adb shell reboot edl`（不是 `adb reboot edl`）
- system.img 为 btrfs，挂载修改后 umount 即可，无需重新 mkfs
