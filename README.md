# QPi M1/L1 SDK

## 1. SDK 简介

QPi M1/L1 SDK 用于 Quectel SC200U/SC200E 开发板的 Linux Kernel 功能配置和内核模块开发。

通过 SDK，用户可以：

- 修改 Kernel 功能配置；
- 编译内核模块（`.ko` 文件）；
- 将编译后的模块更新到系统镜像 `system.img`；
- 将新的 `system.img` 安全烧录到开发板的备用系统分区。

SDK 支持 SC200U 和 SC200E，以及 Debian/Linux、Normal（标准版本）/Perf（性能版本），组合共 8 种。正常情况下不需要手工选择，执行 `buildenv` 后 SDK 会自动识别。

构建前所需的 Kernel 配置和原始 `system.img` 可以从官方固件包获取；如果没有固件包，也可以通过 ADB 从当前连接的开发板只读获取。

## 目录结构

```text
QPI-M1L1/
├── config/                      # 平台识别及 Kernel 配置
├── docker_env/                  # Docker 编译环境与容器入口
├── docs/                        # 使用文档、示例与第三方许可证
│   └── LICENSES/
│       └── THIRD_PARTY_NOTICES.md  # 第三方软件声明索引
├── fw/                          # 官方固件包放置目录
├── kernel/                      # Kernel 工作目录（由 buildenv 补全）
├── patches/                     # M1/L1 Kernel 补丁
├── prebuilds/                   # 运行时基线镜像与版本信息
├── tools/                       # 构建、环境准备及镜像处理脚本
│   ├── flash.sh                 # system.img 检查与烧录脚本
│   ├── compat/                  # 兼容构建入口
│   │   └── one_key_rebuild_kernel.sh
│   ├── diagnostics/             # Kernel 与模块兼容性诊断
│   ├── kernel-environment/      # Kernel 依赖准备资源
│   │   └── sources.lock        # 源码及构建依赖版本锁定
│   ├── maintenance/             # 内部源码与资源同步
│   └── verification/            # 镜像与模块验证
├── build.sh                     # SDK 构建命令入口（需 source）
├── apply_kernel_patches.sh      # Kernel 补丁应用入口
└── README.md                    # SDK 使用说明
```

> 干净 SDK 中的 `kernel/` 仅包含工作目录框架，`prebuilds/` 不包含完整的 Kernel 源码、工具链和基线镜像。执行 `buildenv` 后，SDK 才会按当前平台准备相关依赖。

## 2. 使用前准备

### 2.1 PC 端

准备一台 Linux/Ubuntu 主机，并确保具备：

- Git；
- Docker Engine（需自行下载安装），并确保当前用户可以正常运行 `docker` 命令。安装方法参见 [Docker Engine 安装教程](docs/DOCKER_INSTALL.md)；
- 足够的磁盘空间；
- 如需连接或烧录开发板，还需安装 ADB。

### 2.2 官方固件包或开发板

官方固件包不是必须的，可选择以下任一种方式。

**有官方固件包：**

将一份目标 M1/L1 官方固件包放入 `fw/`。目录中只保留一份有效固件包。

**没有官方固件包：**

1. 保持 `fw/` 中没有有效固件包；
2. 使用 USB 连接一台受支持的 M1/L1 开发板；
3. 确认 `adb devices` 可以识别设备；
4. 确保 ADB shell 具有所需的 root 权限。

SDK 会从开发板只读获取构建所需文件，不会写入开发板分区。

> 官方固件包与开发板同时存在时，SDK 始终优先使用官方固件包。多份有效固件或无效的显式固件配置会直接报错。

## 3. 快速开始

### 3.1 初始化

进入 SDK 根目录：

```bash
source build.sh
buildenv
```

`buildenv` 会自动：

- 检查并准备编译环境；
- 识别 SC200U/SC200E；
- 识别 Debian/Linux 和 Normal/Perf；
- 准备当前平台编译所需的 Kernel 配置和 `system.img`。

如果已经准备过同一个平台，再次执行 `buildenv` 会直接复用已有文件，不需要每次都重新下载工具或读取开发板。

### 3.2 修改 Kernel 功能

如需修改 Kernel 配置：

```bash
buildmenuconfig
```

在配置界面中可以将功能设置为：

- `<M>`：编译成内核模块 `.ko`；
- `<*>`：编译进 Kernel。

本 SDK 只生成并更新 `system.img`，不生成 `boot.img`、DTB 或 `dtbo.img`。如果希望通过默认流程更新某项功能，应优先使用该功能支持的 `<M>` 模块方式。

不需要修改 Kernel 配置时，可以跳过此步骤。

### 3.3 编译

执行：

```bash
buildall
```

编译完成后，最终需要使用的文件是：

```text
out-system/system.img
```

### 3.4 检查并烧录

先检查烧录计划：

```bash
./tools/flash.sh --dry-run
```

该命令只检查：

- 当前正在运行哪个系统槽；
- 准备写入哪个备用槽；
- 目标分区是否可以安全写入；
- `system.img` 与目标分区是否匹配。

它不会真正写入开发板。确认输出正常后再执行：

```bash
./tools/flash.sh
```

默认烧录备用槽，不自动切槽或重启。只有显式使用 `--switch` 时，才会在烧录校验成功后切槽并重启。

## 4. 最常用的完整流程

第一次使用：

```bash
source build.sh
buildenv
buildmenuconfig    # 如果不需要修改 Kernel 配置，可以跳过
buildall
./tools/flash.sh --dry-run
```

确认烧录计划无误后：

```bash
./tools/flash.sh
```

命令说明：

| 命令 | 作用 |
|---|---|
| `source build.sh` | 加载 SDK 命令 |
| `buildenv` | 自动准备当前平台的编译环境 |
| `buildmenuconfig` | 修改 Kernel 功能，可选 |
| `buildall` | 编译并生成 `system.img` |
| `./tools/flash.sh --dry-run` | 检查烧录计划，不实际烧录 |
| `./tools/flash.sh` | 正式烧录 `system.img` |

打开新终端后，需要重新进入 SDK 根目录并执行 `source build.sh`；同一终端内无需重复执行。

## 5. 重新编译或更换开发板

### 情况 1：还是当前开发板，只想重新编译

```bash
buildclean
buildenv
buildall
```

`buildclean` 只删除上一次的编译结果。已经准备好的平台文件、Kernel 配置和编译工具会保留，因此不需要全部重新准备。

### 情况 2：更换开发板或系统版本

以下情况应使用 `buildclean --all`：

- SC200U 切换到 SC200E，或反向切换；
- Debian 切换到 Linux，或反向切换；
- Normal 切换到 Perf，或反向切换；
- 更换官方固件包；
- 更换需要重新读取构建文件的开发板。

执行：

```bash
buildclean --all

# 更换 fw/ 中的官方固件包，或连接新的目标开发板

buildenv
buildmenuconfig    # 可选
buildall
```

`--all` 会同时清除上一平台保存的构建基础文件，下一次 `buildenv` 会重新识别和准备。已经下载且校验正确的 Kernel 源码、SDK Patch、编译工具和下载缓存会保留。

> **切换开发板、系统、Normal/Perf 或官方固件包前，必须先执行 `buildclean --all`。不要混用上一平台的 Kernel 配置或系统镜像。**

## 6. 常用命令

| 命令 | 什么时候使用 |
|---|---|
| `buildenv` | 首次使用，或清理后重新准备环境 |
| `buildenv --check` | 只检查现有环境，不下载或初始化 |
| `buildmenuconfig` | 需要修改 Kernel 功能时 |
| `buildall` | 完成推荐的全部编译流程 |
| `buildclean` | 同一平台重新编译 |
| `buildclean --all` | 更换开发板、系统、Normal/Perf 或固件 |
| `./tools/flash.sh --dry-run` | 烧录前检查，不写设备 |
| `./tools/flash.sh` | 正式烧录新的 `system.img` |

如果 Docker 报权限错误，可执行：

```bash
sudo usermod -aG docker $USER
newgrp docker
```

`newgrp docker` 会进入新的 shell，请重新进入 SDK 根目录并执行 `source build.sh`。

## 7. 编译结果在哪里

用户通常只需要关注：

| 路径 | 用途 |
|---|---|
| `fw/` | 可选，用于放置一份官方固件包 |
| `config/` | 当前使用的 Kernel 配置 |
| `out-modules/` | 编译生成的内核模块 |
| `out-system/` | 最终系统镜像输出 |
| `docs/` | 详细技术文档 |

最终烧录文件：

```text
out-system/system.img
```

构建过程中会生成 Kernel `Image` 作为编译副产物，但 SDK 不生成或更新 `boot.img`、DTB 和 `dtbo.img`。

## 8. 常见问题

### 没有官方固件包，可以使用吗？

可以。保持 `fw/` 中没有有效固件包，连接一台受支持且 ADB shell 具有 root 权限的开发板，然后执行 `buildenv`。

### 每次执行 buildenv 都会重新读取开发板吗？

不会。相同平台的文件已经完整准备好时会直接复用。

### 修改为 <*> 后为什么只烧录 system.img 不生效？

`<*>` 会把功能编译进 Kernel，而本 SDK 不生成包含 Kernel 的 `boot.img`。对于支持模块方式的功能，请优先选择 `<M>`。

### 更换另一块板后应该怎么做？

先执行 `buildclean --all`，再更换固件或连接目标开发板，然后重新执行 `buildenv` 和 `buildall`。

### tools/flash.sh --dry-run 会写入设备吗？

不会。它只检查当前槽、备用槽、目标分区和镜像大小，不会烧录、切槽或重启。

## 9. 高级说明

### 9.1 平台内部名称

SDK 内部使用以下 8 个名称：

```text
200u-debian
200u-debian-perf
200u-linux
200u-linux-perf
200e-debian
200e-debian-perf
200e-linux
200e-linux-perf
```

这些名称由 `buildenv` 自动选择，不建议通过环境变量手工覆盖。

### 9.2 构建基础文件和识别规则

Kernel 配置、原始系统镜像、Kernel 版本及其校验信息在内部统称为构建基线。SDK 同一时间只维护一套当前构建基线，完整且校验一致时直接复用，不会覆盖用户通过 `buildmenuconfig` 保存的修改。

官方固件包存在时，从固件中的 boot image 提取 IKCONFIG 并恢复配套文件；没有官方固件包时，从唯一合法的 root ADB 设备读取 `/proc/config.gz`、Kernel 版本和当前运行槽的 system 分区。

系统类型使用精确 ID 识别：

- `debian` 对应 Debian；
- `qti-distro-fullstack-debug` 和 `qti-distro-fullstack-perf` 对应 Linux。

Linux 系统名称中的 `debug/perf` 不单独决定 Kernel 构建类型。Normal/Perf 由 Kernel 版本和 `CONFIG_LOCALVERSION` 共同判断：

- Normal：`uname -r=5.15.180-gki-consolidate`，且 `CONFIG_LOCALVERSION="-gki-consolidate"`；
- Perf：`uname -r=5.15.180`，且 `CONFIG_LOCALVERSION=""`。

不会根据 `CONFIG_PERF_EVENTS`、CPU governor、命令行中的 `performance` 或系统名称单独判断 Perf。Normal 使用 `config/kernel.config`，Perf 使用 `config/kernel.perf.config`。

### 9.3 Kernel 来源、构建工具和 Patch

SDK 发布包不预置 `kernel/msm-kernel` 和受管理的第三方 Kernel 构建资源。`buildenv` 根据 `tools/kernel-environment/sources.lock` 中锁定的版本，从 CodeLinaro/Google 官方来源下载或复用所需资源。

CodeLinaro msm-kernel 固定 revision：

```text
f278c736182df6de50199aee950bcfc9ad4e9eab
```

随后按固定顺序应用：

1. `0001-sdk-kernel-build-and-config-integration.patch`
2. `0002-qualcomm-bengal-scuba-platform-support.patch`
3. `0003-m1-l1-display-touch-and-runtime-dt-support.patch`
4. `0004-m1-l1-board-and-peripheral-support.patch`
5. `0005-realtek-r8152-vendor-driver.patch`
6. `0006-kernel-security-and-general-backports.patch`

不要手工选择、跳过或调整 Patch 顺序。已有且 revision/digest 正确的资源直接复用；缺失时才下载。半应用 Patch、版本错误或有未知修改的受管理目录会被拒绝，不会无条件覆盖。

### 9.4 单步编译

`buildall` 的内部流程为：

```text
buildkernel -> buildstage -> buildsystem
```

需要单独排查时，可以按顺序执行：

```bash
buildkernel
buildstage
buildsystem
```

- `buildkernel`：编译 Kernel Image 和内核模块；
- `buildstage`：整理 first-stage 和 second-stage 模块；
- `buildsystem`：运行 depmod，并把需要更新的模块写入 `system.img`。

只执行 `buildkernel` 不会更新最终的 `system.img`。

### 9.5 公开版构建边界

公开版采用仅更新系统镜像的 system-only 模式：

- 只生成并交付 `out-system/system.img`；
- 不提供 boot/DT 构建命令，不重新生成或更新 `boot.img`、Kernel Image、DTB 或 `dtbo.img`；
- Kernel 构建固定跳过 DT 编译，`buildall` 不要求用户提供 Qualcomm DT 源码；
- 已移除的 audio/camera/graphics/wlan/video 等 vendor 外部模块在原始系统镜像中保持原厂版本；
- `stage/first` 中属于早期启动路径的模块不会由默认流程更新，默认交付主要使用 `stage/second`；
- 新模块必须与原厂 Kernel 的 release、vermagic、`CONFIG_MODVERSIONS`、导出符号和 CRC 兼容，最终功能仍需在目标开发板验证。

### 9.6 清理细节和维护接口

默认 `buildclean` 清理构建输出，保留当前构建基础文件和 Kernel 配置。`buildclean --all` 还会清除当前 config、platform、kernel release、system image 及其 metadata，但保留源码、6 个 Patch、工具链、`tools/kernel-environment/sources.lock` 和下载缓存。

以下接口不属于普通用户默认流程：

| 接口 | 用途 |
|---|---|
| `restore_baseline` | 官方固件恢复路径使用的内部辅助接口 |
| `buildramdisk` | 保留的 ramdisk 单步接口 |
| `tools/compat/one_key_rebuild_kernel.sh` | 兼容的官方固件辅助入口 |
| `tools/maintenance/sync_kernel.sh` | 内部维护用：同步 Kernel 源码 |

## 10. 详细技术文档

- [第三方许可证索引](docs/LICENSES/THIRD_PARTY_NOTICES.md)
