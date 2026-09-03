# simple-h1 — Quectel PI H1 (QCS6490) 简化 SDK

基于 Quectel PI H1 (QCS6490) 原生 SDK 裁剪的轻量 SDK，**脱离 Yocto/bitbake**，只保留两个核心功能：

1. **内核编译打包** — 修改内核源码 → 独立交叉编译 → ko 驱动放入 overlay → 内核 + 设备树打包进启动镜像 (efi.bin)
2. **应用层自定义开发** — 通过 overlay 机制向 system.img 追加/删除客户自定义应用、脚本、服务等文件，重新打包文件系统

## 目录结构

```
simple-h1/
├── kernel/            # 内核源码 (QCOM 6.6.116, 完整可编译)
├── overlay/           # ★ 文件系统增量目录 (打包时合并进 system.img)
│   └── lib/modules/6.6.116-qli-1.7-ver.1.1/updates/  # 外置驱动 ko (rt6801/wlan 等, 仅 ko 无源码)
├── apps/              # 预置源码 (github 开源项目等, make install 安装到 overlay)
├── prebuilds/         # 原始固件 (system.img / efi.bin / dtb.bin / 分区表 / firehose)
├── tools/             # adb / qdl / flash 工具 / ukify / stub / initramfs / dtbo
├── toolchains/        # 独立交叉编译链 (aarch64-qcom-linux-gcc 13.4.0)
├── skills/            # AI Agent skills
├── docs/              # 文档 / 原理图
├── scripts/           # 构建与烧录脚本 (见下)
└── build/             # 编译产物与最终输出 (build/output/)
```

## 与 QPi-SDK (M2) 命令兼容（推荐入口）

本 SDK 提供与 QPi-SDK (M2, RK3576) **同一套命令**的兼容层，两套 SDK 命令/脚本通用，
无需记忆两套用法（以 M2 为准，不改 M2，simple-h1 向上兼容）：

```bash
source build.sh          # 与 M2 的 build.sh 同款: 注册命令 + 打印帮助

newapp myapp             # 从模板创建应用 (docs/templates/, 创建到 apps/)
buildapp apps/myapp      # 编译应用 (自动识别 Makefile/CMake)
buildcheck               # 环境检查
buildkernel              # 编译内核 (Image + dtb + modules)
buildboot                # 打包启动镜像 (efi.bin + dtb.bin)
buildoverlays            # 设备树 overlays 说明 (simple-h1 为预置 dtbo)
buildrootfs              # 应用 overlay/ → build/output/system.img
buildall                 # 完整打包 (内核 + efi.bin + dtb.bin + system.img)
buildmenuconfig          # 内核 menuconfig
builddefconfig           # 恢复基准配置
buildclean               # 清理构建产物
```

或使用顶层 Makefile（目标集与 M2 一致）：

```bash
make check               # 环境检查
make kernel              # 编译内核
make all                 # 完整打包 (应用层改动: SKIP_KERNEL=1 make all)
make rootfs              # 打包 system.img
make clean               # 清理
```

脚本路径也兼容 M2 形态：

```bash
./tools/build-kernel.sh check|kernel|boot|overlays|all|clean|menuconfig|defconfig|savedefconfig
./tools/build-rootfs.sh check|apply|remove|extract|repack|clean
source tools/environment-setup.sh     # 等价于 source scripts/env.sh
```

> 命令内部映射到 `scripts/` 原生实现；`./scripts/*.sh` 直接调用仍然可用。
> 差异说明: M2 产物为 FIT boot.img + ext4 rootfs.img；simple-h1 产物为
> efi.bin (UKI) + dtb.bin + BTRFS system.img。两边的 buildrootfs apply 都
> 是"overlay → 新镜像"，remove 在 M2 直接删镜像文件、在 simple-h1 登记到
> overlay-remove.list（下次打包生效）。

## system.img 可复现打包模型 (目录级, 免挂载修改)

simple-h1 的 system.img 采用**目录级可复现**模型 (与 M2 的
extract/apply/repack 对齐), 不直接挂载修改镜像:

```
prebuilds/base_rootfs/   ← 基准目录 (从原始 system.img 提取一次, 只读)
     │  cp --reflink (每次构建)
     ▼
build/rootfs-staging/    ← base + overlay + 删除清单 + hooks (目录操作, 免 root)
     │  fakeroot + mkfs.btrfs --rootdir
     ▼
build/output/system.img  ← 全新生成 (内容由 base+overlay 决定, 可复现)
```

命令:

```bash
./tools/build-rootfs.sh extract   # 一次性: system.img → prebuilds/base_rootfs
./tools/build-rootfs.sh apply     # base + overlay → build/rootfs-staging (免 root)
./tools/build-rootfs.sh repack    # staging → system.img (fakeroot 保属主)
./tools/build-rootfs.sh build     # = apply + repack  (buildrootfs 同)
```

要点:
- base_rootfs 提取: 有 sudo 走 mount+rsync (保真属主); 无 sudo 走 btrfs restore (免 root)
- overlay/ 与 hooks/ 在目录级应用, 全程免 root (hooks 的 IMG_MNT=staging)
- 打包用 fakeroot 伪装属主 + mkfs.btrfs --rootdir, UUID 固定为原镜像 UUID
- 镜像大小: 默认按原镜像 (SYSTEM_IMG_SIZE 可调); 注意 btrfs-progs 5.16 的
  --rootdir 会按内容自动扩展 (9.2GB 内容 → ~16.7GB 镜像), 若需严格控大小
  请用新版 btrfs-progs (≥6.x, -b 参数对 rootdir 生效)
- 旧挂载模型保留在 scripts/pack-system.sh (legacy, 需要 root)

## 快速开始

### 0. 环境

```bash
cd simple-h1
source scripts/env.sh          # 设置环境 (工具链 PATH、版本号等)
```

> 编译内核需要: `make`、`bc`、`bison`、`flex`、`libssl-dev`、`libelf-dev` 等宿主工具
> 打包镜像需要: `sudo` (挂载 loop 镜像)、`rsync`、`fdtoverlay` (dtc 包)
> 脚本会提示输入 sudo 密码; 若需免交互, 可先 `sudo -v` 缓存凭证

### 1. 编译内核 (可选, 已内置官方 .config)

```bash
./scripts/build-kernel.sh          # 编译 Image + dtb + modules
./scripts/build-kernel.sh clean    # 清理后重新编译
```

产物:
- `build/kernel/arch/arm64/boot/Image` — 内核二进制
- `build/kernel/arch/arm64/boot/dts/qcom/qcs6490-idp-pi.dtb` — 设备树
- `build/modules-staging/lib/modules/6.6.116-qli-1.7-ver.1.1/` — ko 驱动

### 2. 修改 overlay (应用层自定义)

在 `overlay/` 下按根文件系统路径放置文件，例如:

```
overlay/
├── usr/local/bin/myapp          # 自定义应用
├── etc/systemd/system/myapp.service
├── lib/modules/6.6.116-qli-1.7-ver.1.1/updates/my_driver.ko   # 自定义 ko
└── overlay-remove.list          # (可选) 要删除的文件清单, 每行一个路径
```

**从源码安装应用** (github 开源项目等):

```bash
# 将项目源码放入 apps/<app>/, 要求含 Makefile (install 目标)
./scripts/install-app.sh apps/myapp            # make install DESTDIR=overlay/usr/local
./scripts/install-app.sh apps/myapp PREFIX=/opt/myapp
```

### 3. 全量打包

```bash
SKIP_KERNEL=1 ./scripts/build-all.sh   # 只打包镜像 (推荐日常使用)
./scripts/build-all.sh                 # 完整流程 (含内核编译)
```

输出到 `build/output/`:
- `efi.bin` — 启动分区 (UKI: 内核 Image + dtb + initramfs)
- `dtb.bin` — 设备树分区 (combined-dtb.dtb)
- `system.img` — 根文件系统 (已合并 overlay)

### 4. 烧录

```bash
./scripts/flash.sh        # 自动: adb shell reboot edl -> 9008 -> qdl 烧录 (UFS)
```

## 内核版本

- 内核: `6.6.116` (QCOM quectel 定制源码, 位于 `kernel/`)
- 版本串: `6.6.116-qli-1.7-ver.1.1` (与官方固件一致, 见 `scripts/env.sh`)
- 外置驱动 (rt6801/yt6801、wlan/qca6490 等) 不随内核编译, 直接以 ko 形式预置在 overlay

## 与原生 SDK 的差异

| 项目 | 原生 SDK | simple-h1 |
|------|---------|-----------|
| 构建系统 | Yocto/bitbake | 纯 make + 脚本 |
| 内核编译 | bitbake virtual/kernel | `build-kernel.sh` (独立交叉工具链) |
| 启动镜像 | esp-qcom-image (vfat) | ukify 打包 UKI → 更新 efi.bin |
| 应用定制 | recipe/IMAGE_INSTALL | overlay 文件合并 (rsync) |
| 依赖 | 40G+ 源码/缓存 | 源码 1.6G + 原始镜像 14G |
