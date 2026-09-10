# Quectel H1 SDK

Quectel PI H1 (QCS6490) 开发 SDK，支持两个核心功能，**脱离原生 SDK 实现**：

1. **内核编译打包** — 修改内核源码 → 编译 ko 驱动放 overlay → 内核二进制 + 设备树打包到启动镜像 (efi.bin)
2. **应用层自定义开发** — 开放文件系统镜像 (system.img, BTRFS)，通过 overlay 机制追加客户自定义应用/脚本/服务等文件

## 目录结构

```
qpi-h1/
├── kernel/               # 内核源码 (QCOM 6.6.116) + 编译产物
├── overlay/              # ★ 增量预置目录 (应用层文件覆盖; 目录结构 == 镜像内路径)
├── prebuilds/            # 预构建镜像
│   ├── system.img        #   原始根文件系统镜像 (BTRFS, 只读基准)
│   ├── efi.bin           #   启动分区底包 (FAT, UKI 所在)
│   ├── dtb.bin           #   设备树分区底包 (FAT)
│   ├── base_rootfs/      #   system.img 解出的基准目录 (可复现打包)
│   └── sysroot/          #   system.img 解出的应用编译 sysroot
├── tools/                # ★ 工具与脚本
│   ├── setup-env.sh      #   ★ 宿主环境部署 (WSL/Ubuntu/macOS 检测 + 装依赖)
│   ├── repair-toolchain.sh #  ★ 修复内核工具链 (去绝对路径, 可重定位)
│   ├── build-kernel.sh   #   内核编译打包 (kernel/boot/all/check/clean)
│   ├── build-rootfs.sh   #   应用层 overlay 打包 (extract/apply/repack/build/remove)
│   ├── extract-sysroot.sh#   提取 sysroot (免 root, btrfs restore)
│   ├── environment-setup.sh  # 交叉编译环境
│   ├── qfil/             #   ★ Windows 烧录后端 (fh_loader + QSaharaServer)
│   └── cmake/            #   CMake toolchain
├── scripts/              # 底层实现脚本 (build-kernel/pack-efi/pack-dtb/install-app)
│   ├── flash.sh          #   烧录入口 (自动区分 Linux/WSL 与 Windows)
│   └── flash.bat         #   Windows 烧录 (调用 tools/qfil 后端)
├── toolchains/           # 工具链
│   └── qcom-rootfs-toolchain/  # 应用交叉编译 qemu wrapper (sysroot 内 gcc-14)
├── hooks/                # pre-pack hooks (打包前镜像内容调整)
├── skills/               # AI skills (simple-h1-build / simple-h1-flash)
├── docs/                 # 文档 (templates 参考)
├── build.sh              # source 后注册 build* 命令，并导出交叉编译变量
└── Makefile              # 顶层便捷入口
```

## 环境部署（首次使用）

编译固件前先装齐宿主依赖。`tools/setup-env.sh` 会自动识别平台并安装所需软件包：

```bash
./tools/setup-env.sh            # 检测平台 + 安装依赖（幂等，可重复执行）
./tools/setup-env.sh check      # 只检测不安装（CI / 只读环境）
./tools/setup-env.sh --dry-run  # 只打印将要执行的命令
```

### 平台支持

| 平台 | 内核编译 | 固件打包 | 烧录 | 说明 |
|------|:-------:|:-------:|:----:|------|
| Ubuntu 22.04（物理机 / 虚拟机） | 支持 | 支持 | 支持 | **设计基准环境** |
| WSL2 + Ubuntu 22.04 | 支持 | 支持 | 受限 | Windows 下推荐；烧录需 usbipd-win 转发 USB |
| 其他 Debian 系 / Fedora / Arch | 支持 | 支持 | 支持 | 脚本自动适配包管理器 |
| macOS | 不支持 | 不支持 | 不支持 | 脚本直接终止并说明原因 |

> **为什么锁定 Ubuntu 22.04**：`tools/build-rootfs.sh` 按 `btrfs-progs 5.16` 的行为编写
> （22.04 自带 5.16.2）。更高版本行为不同，可能产出超大 `system.img` 导致烧录后设备起不来。
> 脚本会检测版本并在偏离时告警。

> **为什么 macOS 不行**：仓库自带的 `tools/qdl`、`tools/adb` 是 Linux x86-64 ELF 可执行文件，
> macOS 无法运行；打包链路还依赖 `mount -o loop` / `btrfs` / `fakeroot` / udev，macOS 均不具备。

### 安装内容

- **内核编译**：`gcc` `make` `bc` `bison` `flex` `libssl-dev` `libelf-dev` `libncurses-dev` `cpio` `kmod`
- **固件打包**：`btrfs-progs` `fakeroot` `mtools` `dosfstools` `device-tree-compiler`（fdtoverlay）`python3-pefile`（ukify 打包 UKI 必需）
- **应用交叉编译**：`qemu-user-static` + `binfmt-support`（binfmt 跑 sysroot 内 gcc-14）
- **烧录**：`usbutils` `libusb-1.0-0` `libxml2` `libzip`（qdl 运行时）
- **WSL2 额外**：加载 `btrfs` 内核模块并写入 `/etc/modules-load.d/`（开机自动加载）

### 需要厂商单独分发的资源

以下内容**不在仓库内**（被 `.gitignore` 排除），缺失时无法产出可烧录固件：

| 路径 | 内容 | 缺失影响 |
|------|------|---------|
| `toolchains/gcc/` | 内核交叉工具链 `aarch64-qcom-linux` 13.4 | `buildkernel` 自检直接失败 |
| `prebuilds/` | `system.img` / `efi.bin` / `dtb.bin` / `base_rootfs` / `sysroot` | 无法打包镜像；`buildapp` 退回宿主工具链 |

请向 Quectel 获取后按原路径放置。

## 推荐入口：source build.sh

```bash
cd <SDK_ROOT>
source build.sh

newapp myapp           # 从模板创建应用
buildapp apps/myapp    # 编译应用
buildcheck             # 环境检查
buildkernel            # 编译内核
buildboot              # 打包启动镜像 (efi.bin + dtb.bin)
buildoverlays          # 设备树 overlays
buildrootfs            # 打包 system.img (base + overlay)
buildall               # 完整打包 (内核 + 启动镜像 + system.img)
buildmenuconfig        # 内核 menuconfig
buildclean             # 清理构建产物
```

`source build.sh` 会导出 `SYSROOT`、`TOOLCHAIN`、`CMAKE_TOOLCHAIN_FILE`、`CROSS_COMPILE`、`CC/CXX` 等变量，后续进入 app 工程可直接 `make` 或运行 CMake。

H1 应用开发默认使用 `toolchains/qcom-rootfs-toolchain/`：它通过 qemu/binfmt 运行 `prebuilds/sysroot` 内的 Debian GCC 14.2 + binutils，与 system.img 内的 glibc 完全匹配。内核编译使用 `aarch64-qcom-linux` 13.4 工具链（位于 `toolchains/gcc/`，独立分发，需自行放置）。

## 功能 1：内核编译打包

```bash
# 修改内核源码后编译
./tools/build-kernel.sh kernel      # 编译内核 (Image + dtb + modules)
./tools/build-kernel.sh boot        # 打包启动镜像 (efi.bin + dtb.bin)
./tools/build-kernel.sh all         # 完整: 内核 + 启动镜像 + system.img
./tools/build-kernel.sh check       # 环境检查
./tools/build-kernel.sh clean       # 清理

# 或使用顶层 Makefile（内部同样 source build.sh）
make check
make kernel
make all
make clean

# 产物
build/output/efi.bin                # 启动镜像 (UKI: Image + dtb + initramfs)
build/output/dtb.bin                # 设备树 (combined-dtb.dtb)
build/output/system.img             # 根文件系统 (base + overlay 重新打包)
```

**ko 驱动**：编译的内核模块（`.ko`）放到 `overlay/` 对应路径（如 `overlay/lib/modules/6.6.116-qli-1.7-ver.1.1/updates/`），打包时随 system.img 安装。

## 功能 2：应用层自定义开发

```bash
# 把客户自定义文件放进 overlay/ (目录结构 == 镜像内路径)
# 例: overlay/etc/xxx.conf → /etc/xxx.conf; overlay/usr/local/bin/app → /usr/local/bin/app

# 打包 system.img (目录级可复现: base + overlay → staging → 全新生成, 免 root)
./tools/build-rootfs.sh build               # = apply + repack → build/output/system.img
./tools/build-rootfs.sh apply               # 合成 staging (base + overlay + hooks)
./tools/build-rootfs.sh repack              # staging → system.img (fakeroot + btrfs)
./tools/build-rootfs.sh extract             # 一次性: system.img → prebuilds/base_rootfs
./tools/build-rootfs.sh remove /opt/xxx     # 登记删除 (overlay-remove.list)
```

## 环境

```bash
# 交叉编译环境，推荐 source 顶层 build.sh
source build.sh
# 或 CMake 工程: -DCMAKE_TOOLCHAIN_FILE=tools/cmake/aarch64-qcom-rootfs-toolchain.cmake
```

Makefile 示例默认按当前目录结构查找 `prebuilds/sysroot` 和 `toolchains/`。

应用工具链选择顺序：`QPI_CROSS_COMPILE` 显式指定 > SDK 内置 qcom-rootfs-toolchain (qemu wrapper) > 宿主 `aarch64-linux-gnu-`。普通应用建议保持默认。sysroot 缺失时先执行 `./tools/extract-sysroot.sh`（从 system.img 提取，免 root，符号链接原生保留）。

## 烧录

```bash
./scripts/flash.sh            # 默认 UFS
./scripts/flash.sh emmc
```

`scripts/flash.sh` 会按平台自动选择后端：

| 运行环境 | 烧录方式 |
|---------|---------|
| Linux / WSL2 | `tools/qdl`（libusb，需 udev 规则） |
| Windows | `tools/qfil/` 的 QFIL 后端，经 `scripts/flash.bat` 调用 |
| macOS | 不支持，直接报错退出 |

设备须先进入 **EDL (9008)**：正常运行的系统执行 `adb shell reboot edl`；panic 状态断电重上电并按住 EDL 组合键。

Windows 下可跳过 shell 直接运行批处理：

```bat
scripts\flash.bat            :: 默认 UFS
scripts\flash.bat emmc
```

Windows 侧后端（`QSaharaServer.exe` + `fh_loader.exe`）随仓库分发，静态链接、无额外 DLL 依赖，
详见 `tools/qfil/README.md`。

WSL2 下 USB 默认不直通，若要直接在 WSL 内烧录需用 `usbipd-win` 转发 Qualcomm 9008 设备；
否则建议在 Windows 侧跑 `scripts\flash.bat`（编译/打包仍在 WSL 内完成）。

## 路径覆盖

`scripts/env.sh` 的目录均可用环境变量覆盖，便于把镜像或产物放到其他位置（例如大容量磁盘、共享目录）：

```bash
OUT_DIR=/data/qpi/out ./scripts/build-all.sh          # 产物输出到别处
PREBUILDS_DIR=/data/qpi/prebuilds ./scripts/flash.sh  # 原始镜像放在别处
BUILD_DIR=/data/qpi/build ./tools/build-rootfs.sh build
```

可覆盖项：`KERNEL_SRC`、`KERNEL_OUT`、`OVERLAY_DIR`、`PREBUILDS_DIR`、`TOOLS_DIR`、
`TOOLCHAIN_DIR`、`BUILD_DIR`、`OUT_DIR`；`tools/build-rootfs.sh` 额外支持
`SRC_IMG`、`BASE_ROOTFS`、`STAGING`、`OUT_IMG`、`SYSTEM_IMG_SIZE`、`SYSTEM_IMG_UUID`。

## 交叉工具链（厂商分发）

内核工具链 `toolchains/gcc/` 由厂商单独分发，其二进制在打包时被打上了**原机器的绝对路径**
作为 ELF 解释器（Yocto uninative 机制），直接拷贝到其他机器会报：

```
error while loading shared libraries: libc.so.6: cannot open shared object file
```

`tools/repair-toolchain.sh` 就地修复为可重定位：

```bash
./tools/repair-toolchain.sh           # 修复 <SDK>/toolchains/gcc
./tools/repair-toolchain.sh /path/to/sdk
```

做法：把解释器指向本机探测到的系统加载器，并把 RPATH 设成 `$ORIGIN` 相对路径，
从而不依赖任何硬编码路径。修复后工具链可整目录复制到任意位置照常使用。

## AI Skills

`skills/` 提供 SKILL.md 技能包（AI 助手按关键词自动加载）：
- `simple-h1-build`：内核编译打包 + overlay 文件系统定制
- `simple-h1-flash`：EDL 模式烧录

## 应用开发（创建 + 编译）

### 方式 A：用 SDK 命令（推荐）

```bash
cd <SDK_ROOT>
source build.sh

# 1. 创建应用（从 hello 模板复制，已替换项目名/打印内容）
newapp myapp

# 2. 编译应用（自动识别 Makefile/CMake，产出 aarch64 可执行文件）
buildapp apps/myapp

# 3. 安装到 overlay (随 system.img 打包)
./scripts/install-app.sh apps/myapp

# 4. 重新打包
buildrootfs     # 或 SKIP_KERNEL=1 buildall
```

指定模板：`newapp myapp hello`。模板位于 `docs/templates/`。

### 方式 B：Makefile

```bash
make newapp NAME=myapp          # 创建
make app DIR=apps/myapp         # 编译
```

### 方式 C：手动创建

在任意目录建 `main.c` + `Makefile`（参考 `docs/templates/hello/`），然后：

```bash
cd <SDK_ROOT>
source build.sh
buildapp <你的工程目录>
```

```c
// main.c 示例
#include <stdio.h>
int main(void) {
    printf("Hello from my app!\n");
    return 0;
}
```

```makefile
# Makefile 示例 (source build.sh 后 CC/CFLAGS 已由 SDK 导出)
TARGET = myapp
all: $(TARGET)
$(TARGET): main.c
	$(CC) $(CFLAGS) $< -o $@ $(LDFLAGS)
clean:
	rm -f $(TARGET)
```

## 详细文档

- `tools/setup-env.sh` — 宿主环境部署（平台检测 + 依赖安装，见头部注释）
- `tools/build-kernel.sh` — 内核打包脚本 (查看头部注释)
- `tools/build-rootfs.sh` — 应用层打包脚本 (查看头部注释)
- `hooks/README.md` — pre-pack hooks 机制说明
- `skills/` — AI 技能包说明
