# Quectel M2 SDK

Quectel PI M2 (RK3576) 开发 SDK，支持两个核心功能，**脱离原生 SDK 实现**：

1. **内核编译打包** — 修改内核源码 → 编译 ko 驱动放 overlay → 内核二进制 + 设备树打包到启动镜像
2. **应用层自定义开发** — 开放文件系统镜像，通过 overlay 机制追加客户自定义应用/脚本/服务等文件

## VS Code 插件开发

SDK 支持 VS Code 插件开发：

- 插件下载地址：https://marketplace.visualstudio.com/items?itemName=Quectel.quectelpi
- 插件使用说明文档：https://github.com/quectel-developer/qpi-vscode-extension-doc

## 目录结构

```
ai_sdk/
├── kernel/               # 内核源码 (6.1.118) + 编译产物
├── overlay/              # ★ 增量预置目录 (应用层文件覆盖 + 设备树 overlays)
├── prebuilds/            # 预构建镜像
│   ├── base_image/       #   固件底包 (rootfs.img/boot.img/parameter.txt 等)
│   └── sysroot/          #   M2 Debian rootfs.img 解出的应用编译 sysroot
├── tools/                # ★ 工具与脚本
│   ├── build-kernel.sh   #   内核编译打包 (kernel/boot/overlays/all/pack/check/clean)
│   ├── build-rootfs.sh   #   应用层 overlay 打包 (apply/remove/extract/repack)
│   ├── gen-package-file.sh   # 按 parameter.txt 生成固件打包清单 package-file
│   ├── sync-upstream.sh  #   同步上游核源码改动 (内核更新)
│   ├── environment-setup.sh  # 交叉编译环境
│   ├── cmake/            #   CMake toolchain
│   ├── boot/ pack_tools/ #   FIT/固件打包工具
│   └── kernel-Makefile   #   make menuconfig 等入口
├── toolchains/           # 工具链: 内核 Linaro 10.3 + M2 Debian rootfs wrapper
├── skills/               # AI skills (sdk-build/flash/overlays/board-test)
├── docs/                 # 文档 (examples/templates 参考)
├── build.sh              # source 后注册 build* 命令，并导出交叉编译变量
└── Makefile              # 顶层便捷入口
```

## 推荐入口：source build.sh

```bash
cd /home/q/work/test/ai_sdk
source build.sh

newapp myapp           # 从模板创建应用
buildapp docs/examples/myapp   # 编译应用
buildcheck              # 环境检查
buildkernel             # 编译内核
buildboot               # 生成 FIT boot.img
buildoverlays           # 编译 overlay/*.dts
buildrootfs             # 应用 overlay/ 到 rootfs 工作副本
buildall                # 完整生成 update.img (含内核编译)
buildpack               # 重编外置无线模块并打包 update.img (不编内核)
buildmenuconfig         # 内核 menuconfig
buildclean              # 清理构建产物
```

`source build.sh` 会导出 `SYSROOT`、`TOOLCHAIN`、`CMAKE_TOOLCHAIN_FILE`、`CROSS_COMPILE`、`CC/CXX` 等变量，后续进入 app 工程可直接 `make` 或运行 CMake。

M2 Debian 应用开发默认使用 `toolchains/m2-debian-rootfs-toolchain/`：它通过 qemu/binfmt 运行 `prebuilds/sysroot` 内的 Debian GCC 14.2 + binutils 2.44，和 `RK_DEBIAN_TRIXIE=y` 的 rootfs.img/glibc 2.41 匹配。内核编译仍使用官方源码树同款 Linaro `aarch64-none-linux-gnu` 10.3 工具链。

## 功能 1：内核编译打包

```bash
# 修改内核源码后编译
./tools/build-kernel.sh kernel      # 编译内核 + 内建 overlays
./tools/build-kernel.sh boot        # 生成 FIT boot.img
./tools/build-kernel.sh all         # 完整: 内核 + boot.img + overlays + update.img
./tools/build-kernel.sh pack        # 不编内核/overlays，重编配套外置无线模块并打包
./tools/build-kernel.sh check       # 环境检查
./tools/build-kernel.sh clean       # 清理

# 或使用顶层 Makefile（内部同样 source build.sh）
make check
make kernel
make all
make clean

# 产物
build/result/update.img             # 完整固件
kernel/boot.img                     # 启动镜像 (内核二进制 + 设备树)
build/overlays/*.dtbo               # 设备树 overlays (进 rootfs /boot/overlays/)
```

**ko 驱动**：编译的内核模块（`.ko`）放到 `overlay/` 对应路径（如 `overlay/lib/modules/...`），打包时随 rootfs 安装。

**`all` 与 `pack` 的区别**（首次编译内核很慢，之后是增量）：

| 命令 | 做的事 | 耗时 |
| --- | --- | --- |
| `all` / `buildall` | 编译内核 → FIT boot.img → overlays → 组装 → 打包 | 首次全量约 25+ 分钟，之后增量几分钟 |
| `pack` / `buildpack` | 组装 + 打包，**不编译内核/overlays** | 约 1 分钟（受 5.5GB 镜像读写限制） |

只想把现有 `boot.img` + 底包重新打成固件时用 `pack`。它会优先用 `kernel/boot.img`，
没有则沿用底包的 `boot.img`。

## 功能 2：应用层自定义开发

```bash
# 把客户自定义文件放进 overlay/ (目录结构 == rootfs 路径)
# 例: overlay/etc/xxx.conf → /etc/xxx.conf; overlay/opt/app → /opt/app

# 应用 overlay 到文件系统镜像
./tools/build-rootfs.sh apply               # → build/rootfs-overlay.img
./tools/build-rootfs.sh remove /opt/xxx     # 删除镜像中文件
./tools/build-rootfs.sh extract <img> <dir> # 解压镜像
./tools/build-rootfs.sh repack <dir> <img>  # 重新打包
```

## 环境

```bash
# 交叉编译环境，推荐 source 顶层 build.sh
source build.sh
# 或 CMake 工程: -DCMAKE_TOOLCHAIN_FILE=tools/cmake/aarch64-m2-debian-toolchain.cmake
```

Makefile 示例默认按当前目录结构查找 `prebuilds/sysroot` 和 `toolchains/`。

应用工具链选择顺序：`QPI_CROSS_COMPILE` 显式指定 > SDK 内置 M2 Debian rootfs wrapper > 宿主 `aarch64-linux-gnu-` > SDK 自带 Linaro 10.3。普通应用建议保持默认；只有调试旧 sysroot 或特殊工具链时再设置 `QPI_CROSS_COMPILE`。

## AI Skills

`skills/` 提供 SKILL.md 技能包（AI 助手按关键词自动加载）：
- `sdk-build`：编译 app/kernel/overlays/固件
- `sdk-flash`：rkdeveloptool 烧录
- `sdk-overlays`：设备树 overlay 管理
- `sdk-board-test`：上板验证/冒烟测试

## 应用开发（创建 + 编译）

### 方式 A：用 SDK 命令（推荐）

```bash
cd /home/q/work/test/ai_sdk
source build.sh

# 1. 创建应用（从 hello 模板复制，已替换项目名/打印内容）
newapp myapp

# 2. 编译应用（自动识别 Makefile/CMake）
buildapp docs/examples/myapp

# 3. 产物
#    docs/examples/myapp/myapp   (aarch64 可执行文件)
```

指定模板：`newapp myapp gpio`，可用模板：hello / gpio / serial / pwm / i2c / camera / network / thread / sysinfo / rtc / nvme / pcie。

### 方式 B：Makefile

```bash
make newapp NAME=myapp          # 创建
make app DIR=docs/examples/myapp # 编译
```

### 方式 C：手动创建

在任意目录建 `main.c` + `Makefile`（参考 `docs/templates/hello/`），然后：

```bash
cd /home/q/work/test/ai_sdk
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
# Makefile 示例
CC      ?= aarch64-none-linux-gnu-gcc
SYSROOT ?= /home/q/work/test/ai_sdk/prebuilds/sysroot
CFLAGS  ?= --sysroot=$(SYSROOT) -I$(SYSROOT)/usr/include
LDFLAGS ?= --sysroot=$(SYSROOT) -L$(SYSROOT)/usr/lib/aarch64-linux-gnu
TARGET = myapp
all: $(TARGET)
$(TARGET): main.c
	$(CC) $(CFLAGS) $< -o $@ $(LDFLAGS)
clean:
	rm -f $(TARGET)
```



## 上游源码同步

`kernel/` 提取自完整源码仓库的 `kernel-6.1/`，当前同步点记录在 `tools/upstream/base.txt`。
上游有新提交时**不要直接 rsync 覆盖**，用同步脚本（只同步上游跟踪的源文件，本地定制做三方合并）：

```bash
./tools/sync-upstream.sh report          # 只读预检: 待同步提交/冲突风险/新配置片段
./tools/sync-upstream.sh apply --dry-run # 只读预演: 预检 + 变更清单, 不写盘
./tools/sync-upstream.sh apply           # 执行同步(冲突/未备案改动会在写盘前中止)
./tools/sync-upstream.sh snapshot        # 改过 kernel/ 后重新采集本地定制
```

同步成功后旧 `.config` 自动备份，下次构建重新生成配置；必需片段缺失时停止，
不静默丢掉新特性。配置入口已按上游统一，不使用 `rockchip-debug.config`。
完整固件打包使用官方外置 AIC8800 SDIO 驱动及固件，不使用内核目录中另一套默认配置模块；
模块和固件均回读校验，不能仅凭 vermagic 判断兼容。
自动识屏设备树必须搭配支持它的 U-Boot：打包优先使用 SDK 自带的
[配套启动固件及说明](tools/boot/README.md)，不修改底包；旧 U-Boot 会被检查拒绝。
升级必须同时更新 U-Boot 和 boot，不能仅烧录 boot 分区。
详见 [同步记录与发布回归要求](docs/upstream-sync.md)。

**本地资源不提交**：`prebuilds/` 和 `demo/` 整目录被忽略，不随 SDK 提交。
同步脚本不执行暂存、提交或推送；构建产物也不应进入提交。

## 打包清单 package-file

`afptool` 打包固件时用 `prebuilds/base_image/package-file` 决定“哪个文件落到哪个分区”。
若该文件缺失，`build-kernel.sh` 会自动按 `parameter.txt` 补齐；也可手动执行：

```bash
./tools/gen-package-file.sh           # 生成
./tools/gen-package-file.sh --print   # 只看内容
./tools/gen-package-file.sh --force   # 强制重写
```

## 详细文档

- `overlay/README.md` — overlay 机制说明
- `tools/build-kernel.sh` — 内核打包脚本 (查看头部注释)
- `tools/build-rootfs.sh` — 应用层打包脚本 (查看头部注释)
- `skills/README.md` — AI 技能包说明
