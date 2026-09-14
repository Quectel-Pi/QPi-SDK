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
cd <SDK_ROOT>
source scripts/env.sh     # 原生入口
# 或推荐: source build.sh   (与 QPi-SDK/M2 命令兼容层, 自动 source env.sh)
```

### 固件底包 (prebuilds/, 不入库, 必须先获取)
```bash
./tools/fetch-prebuilds.sh fetch   # 下载 + 校验 + 解压 (缺什么补什么)
./tools/fetch-prebuilds.sh check   # 只检查缺失
./tools/fetch-prebuilds.sh md5     # 对照厂商 md5 检查本地包是否最新
./tools/fetch-prebuilds.sh verify  # 厂商 md5 + 压缩包 CRC 双重校验
# 等价: source build.sh && buildfetch fetch   /   make prebuilds
```
- 官方固定地址 (可用 QPI_PREBUILDS_URL 覆盖, 指向厂商最新底包):
  `https://developer.quectel.com/doc/files/quectel_pi/Quectel_Pi_H1_WF_Debian_RD2_Latest.zip`
- **完整性以厂商 md5 为准** (同目录 `..._Latest_md5.txt`):
  * **打包 system.img 之前自动校验**: 联网失败 -> 用本地继续; md5 一致 -> 继续;
    md5 变了 -> 下载新的替换本地再打包; 已更新但下载失败 -> 中止
    (`QPI_ALLOW_STALE=1` 强行用旧底包; `QPI_NO_REFRESH=1` 跳过检查)
  * fetch 时: 本地 md5 不一致即重下; 下载完成后强制按厂商 md5 校验
  * 替换时旧原版保留为 `system.img.prev`; 派生的 base_rootfs/sysroot 移到 `.prev` 并重建
- **新产物不覆盖原版**: 生成的 system.img 只写 `build/result/system.img`;
  `prebuilds/system.img` 全程只读 (若两者设为同一路径, build-rootfs.sh 报错拒绝)
- 约 3.2 GiB, 断点续传; 缓存 `download/`; 本地 sha256 记录 `tools/prebuilds.sha256`
  (仅复现用, 属自我引用, 不能证明与厂商源一致)
- 缺底包的症状: `buildenv` 报"缺少 prebuilds/system.img"; `buildrootfs`/`buildall` 报
  "无可用基准目录"; `buildboot` 裸报 `cp: cannot stat .../efi.bin`
- buildenv 的 [2/4] 段: 交互终端询问后下载; 非交互默认不下载 (免数 GB 下载挂住扩展/CI),
  非交互要自动下载设 QPI_AUTO_FETCH=1, 彻底禁用设 QPI_NO_FETCH=1

> M2 兼容命令 (同一套命令在 simple-h1 与 QPi-SDK/M2 通用):
> source build.sh 后 → buildenv/buildfetch/buildkernel/buildboot/buildoverlays/buildrootfs/
> buildall/buildmenuconfig/builddefconfig/buildclean/newapp/buildapp; 或
> make check|prebuilds|kernel|boot|rootfs|all|clean|...; 或 ./tools/build-kernel.sh <子命令>
> / ./tools/build-rootfs.sh <子命令>。映射: buildkernel→scripts/build-kernel.sh,
> buildboot→pack-efi.sh+pack-dtb.sh, buildrootfs→tools/build-rootfs.sh build,
> buildall→(内核+pack-efi+pack-dtb+build-rootfs, SKIP_KERNEL=1 语义保留),
> buildenv→依赖安装+底包下载+sysroot+校验。

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
./scripts/install-app.sh projects/<app目录> [PREFIX=/opt/xxx]
```

### 全量打包
```bash
SKIP_KERNEL=1 ./scripts/build-all.sh   # 仅打包镜像 (快)
./scripts/build-all.sh                 # 完整 (含内核编译)
```
输出: `build/result/{efi.bin, dtb.bin, system.img}` + 烧录所需全部文件

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
