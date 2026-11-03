---
name: simple-h1-kernel
description: "simple-h1 SDK: 内核构建 — 交叉工具链、config 生命周期、dtb/dtbo 合并、UKI 打包、模块与外置 ko"
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [qualcomm, qcs6490, quectel, simple-h1, kernel, dtb, dtbo, uki, module]
    related_skills: [simple-h1-build, simple-h1-driver]
---

# 内核构建与配置

## 1. 工具链与目录

| 项 | 值 |
|---|---|
| 内核编译器 | `toolchains/gcc/bin/aarch64-qcom-linux/aarch64-qcom-linux-gcc` (GCC 13.4.0) |
| `CROSS_COMPILE` | `aarch64-qcom-linux-` |
| `ARCH` | `arm64` |
| 源码 | `kernel/` (Linux 6.6.116) |
| 输出 (O=) | `build/kernel/` |
| 版本串 | `6.6.116-qli-1.7-ver.1.1` |

`source scripts/env.sh` 后这些变量都在环境里; 直接跑 `./scripts/build-kernel.sh` 也会自己加载。

注意: **这套工具链只能编内核**, 没有 libc sysroot, 不能链接用户态程序。应用交叉编译用
`toolchains/qcom-rootfs-toolchain`（qemu wrapper, 跑 prebuilds/sysroot 里的 Debian gcc-14）。

## 2. 编译

```bash
./scripts/build-kernel.sh          # Image + dtbs + modules + modules_install
./scripts/build-kernel.sh clean    # 删 build/kernel 后重编
JOBS=8 ./scripts/build-kernel.sh   # 指定并行度 (默认 nproc)
```

脚本固定做的事:

1. 首次构建若没有 `build/kernel/.config`, 从 `scripts/kernel-config` 拷一份;
2. `make O=build/kernel olddefconfig`;
3. `make O=build/kernel DTC_FLAGS="-@" Image dtbs` —— `-@` 生成 `__symbols__`,
   后面 `fdtoverlay` 合并 dtbo 必需;
4. `make O=build/kernel modules`;
5. `make INSTALL_MOD_PATH=build/modules-staging modules_install`。

## 3. 产物

| 产物 | 路径 |
|------|------|
| Image | `build/kernel/arch/arm64/boot/Image` |
| 板级 dtb | `build/kernel/arch/arm64/boot/dts/qcom/qcs6490-idp-pi.dtb` |
| 模块 | `build/modules-staging/lib/modules/6.6.116-qli-1.7-ver.1.1/` |
| UKI | `build/linux-qcm6490-idp.efi` (pack-efi.sh 生成) |

## 4. 配置管理

`scripts/kernel-config` 是基准配置 (完整 .config, 与出厂固件一致)。**不要手工追加片段**,
走命令:

```bash
buildmenuconfig       # 打开 menuconfig, 写入 build/kernel/.config
builddefconfig        # 用 scripts/kernel-config 覆盖 .config 后 olddefconfig
buildsavedefconfig    # 当前配置精简后写回 scripts/kernel-config (旧文件存 .bak)
```

- menuconfig 退出码不区分"保存/未保存", 不要断言已保存; 下次 `buildkernel` 沿用
  `build/kernel/.config` (增量编译), 想确认看 `build/kernel/.config` 里的目标项。
- `buildsavedefconfig` 先备份旧基准再写新文件, 顺序不能反 (否则旧基准丢失)。
- 内核带 `CONFIG_IKCONFIG_PROC=y` → 设备上 `zcat /proc/config.gz` 可核对实际配置。

## 5. 版本串

两处必须一致, 改一处就炸:

| 位置 | 作用 |
|------|------|
| `scripts/env.sh`: `KERNEL_VERSION` + `LOCALVERSION` | 只用来算 `KERNEL_RELEASE`, 供模块路径与 `ukify --uname` |
| `scripts/kernel-config`: `CONFIG_LOCALVERSION` | 内核真实后缀 (`uname -r`) |

`LOCALVERSION` 不能 export: 内核 Makefile 会读同名变量, 造成 `-qli-1.7-ver.1.1` 叠加两次。
`build-kernel.sh` 已 `unset LOCALVERSION` 兜底。

改版本串的连带影响: `overlay/lib/modules/<ver>/updates/` 下厂商预置 ko (yt6801 / r8168 /
wlan / qca6490 / iris_vpu / nt36xxx-i2c 等) 按版本串放置, 目录名不改就加载不到。

## 6. dtb / dtbo / UKI

打包链 (两个脚本, 各管一个分区):

```
qcs6490-idp-pi.dtb (带 __symbols__)
  + tools/uki/dtbo/qcm6490-graphics.dtbo
  + tools/uki/dtbo/qcm6490-camera-rb3.dtbo
  + tools/uki/dtbo/qcm6490-video.dtbo
  ── fdtoverlay ──► combined-dtb.dtb  ──► dtb.bin (::/combined-dtb.dtb)
                                     └──► UKI 的 .dtb section (efi.bin)
```

- `pack-dtb.sh`: 合并结果写到 `build/combined-dtb.dtb`, 再 `mcopy -o` 进
  `build/result/dtb.bin` 的 `::/combined-dtb.dtb`。
- `pack-efi.sh`: `ukify build --efi-arch=aa64 --stub=tools/uki/linuxaa64.efi.stub
  --linux=<Image> --initrd=tools/uki/initramfs-...cpio.gz --devicetree=<合并后 dtb>
  --cmdline=<scripts/env.sh KERNEL_CMDLINE> --uname=<KERNEL_RELEASE>`, 输出
  `build/linux-qcm6490-idp.efi`, 再替换 `build/result/efi.bin` 里
  `::/EFI/Linux/linux-qcm6490-idp.efi`。
- 三个 dtbo 缺任一个就不合并, 直接写基 dtb (不会报错, 要自己确认 `build/combined-dtb.dtb`
  的时间戳)。dtbo 不在本 SDK 内重新编译, `buildoverlays` 只做说明。
- **改 DTS 必须重打 efi.bin 和 dtb.bin 两个分区**: dtb 同时进 UKI 和 dtb.bin。

## 7. 模块

| 类型 | 做法 |
|------|------|
| 内核树内改成 `=m` | 重编内核, `modules_install` 落到 staging, 打包时合并进 `/lib/modules/<ver>/` |
| 内核树内改成 `=y` | 只进 Image, 必须重打 UKI |
| 厂商预置外置模块 | 源码不在本 SDK; 只能换 ko (放 `overlay/lib/modules/<ver>/updates/`) 或调 DTS/配置 |

树外模块编译 (需要先编过一次内核, 有 `build/kernel/Module.symvers`):

```makefile
obj-m := mydrv.o
KDIR  ?= <SDK根>/build/kernel
all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) ARCH=arm64 CROSS_COMPILE=aarch64-qcom-linux- modules
```

`.ko` 放到 `overlay/lib/modules/6.6.116-qli-1.7-ver.1.1/updates/` 就会被打进 system.img;
调试阶段可以直接 `adb push` 覆盖同一个 ko 后 `adb shell reboot`（`adb reboot` 无效）。

## 8. 加日志的策略

内核编译慢, 一次编译要把需要的日志加够:

```c
dev_info(dev, "[tag] enter: x=%d\n", x);     // 有 struct device *dev
pr_info("[tag] branch B, ret=%d\n", ret);    // 没有 dev
printk(KERN_INFO "[tag] %*ph\n", len, buf);  // 寄存器/hex dump
```

- 统一 `[tag]` 前缀, 方便 `dmesg | grep '\[tag\]'`。
- 本次配置 `CONFIG_DYNAMIC_DEBUG` **未开**, `dev_dbg()/pr_debug()` 会被编译掉, 现场看不到;
  验证完把 `dev_info` 删掉或降级, 别留在主线里。
- 驱动 probe 失败、时钟/regulator 取不到时, 先看 `dmesg | grep -iE 'probe|defer|EPROBE'`。

## 9. 陷阱

| 陷阱 | 说明 |
|------|------|
| 在 `kernel/` 里直接 `make` | 会污染源码树; 一律 `O=build/kernel` |
| 手工编辑 `build/kernel/.config` | 下次 `olddefconfig` 可能改掉; 用 menuconfig/savedefconfig |
| 改了 `scripts/kernel-config` 却不清 build | 增量编译会沿用旧 `.config`; 用 `builddefconfig` 覆盖 |
| `buildclean` 后直接 `pack-efi.sh` | Image 不存在, 报缺少文件 |
| `pack-efi.sh` 报 `No module named 'pefile'` | ukify 依赖 `python3-pefile`; `./tools/setup-deps.sh install` 装上再打包 |
| 只替换 efi.bin 不替换 dtb.bin | UKI 内 dtb 与独立 dtb 分区不一致, 行为看运气 |
| 用宿主 gcc 编内核 | 必须 `CROSS_COMPILE=aarch64-qcom-linux-` |
