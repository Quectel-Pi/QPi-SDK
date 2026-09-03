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
│   ├── build-kernel.sh   #   内核编译打包 (kernel/boot/all/check/clean)
│   ├── build-rootfs.sh   #   应用层 overlay 打包 (extract/apply/repack/build/remove)
│   ├── extract-sysroot.sh#   提取 sysroot (免 root, btrfs restore)
│   ├── environment-setup.sh  # 交叉编译环境
│   └── cmake/            #   CMake toolchain
├── scripts/              # 底层实现脚本 (build-kernel/pack-efi/pack-dtb/install-app)
├── toolchains/           # 工具链
│   └── qcom-rootfs-toolchain/  # 应用交叉编译 qemu wrapper (sysroot 内 gcc-14)
├── hooks/                # pre-pack hooks (打包前镜像内容调整)
├── skills/               # AI skills (simple-h1-build / simple-h1-flash)
├── docs/                 # 文档 (templates 参考)
├── build.sh              # source 后注册 build* 命令，并导出交叉编译变量
└── Makefile              # 顶层便捷入口
```

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
./scripts/flash.sh        # 自动: adb shell reboot edl → 9008 → qdl (UFS)
```

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

- `tools/build-kernel.sh` — 内核打包脚本 (查看头部注释)
- `tools/build-rootfs.sh` — 应用层打包脚本 (查看头部注释)
- `hooks/README.md` — pre-pack hooks 机制说明
- `skills/` — AI 技能包说明
