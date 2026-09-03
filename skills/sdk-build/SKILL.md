---
name: sdk-build
description: "使用 Quectel M2 SDK 编译 app / kernel / 完整固件。覆盖：交叉编译 app（Makefile/CMake 工程）、编译内核（defconfig + fragments → Image → FIT boot.img）、编译设备树 overlays（.dts → .dtbo）、完整打包 update.img。当用户说「编译app」「编译内核」「编译固件」「make firmware」「build.sh」「SDK怎么编译」「交叉编译」「编译设备树overlay」「出update.img」「打固件包」时使用。WHEN: sdk build, cross compile, app build, kernel build, firmware build, update.img, build.sh, overlays, dtbo, 编译, 打包固件, 交叉编译. DO NOT USE FOR: 单个 C 工程编译不涉及本 SDK（用 app-demo-build skill），JIRA 工单修复（用 jira-fix-helper），外设参数问题（用 m2-peripherals-guide）。"
license: MIT
metadata:
  author: GitHub Copilot
  version: "1.0.0"
---

# Quectel M2 SDK 编译助手

> 用当前一级目录 SDK 脚本完成 M2 的 app / kernel / overlays / 固件构建。

## 关键路径

```
ai_sdk/
├── kernel/                  # 内核源码
├── overlay/                 # rootfs 文件覆盖 + 设备树 overlay 源码
├── prebuilds/               # 底包和 sysroot
├── toolchains/              # aarch64 工具链
└── tools/                   # ★ 构建脚本
```

## 编译方式速查

| 需求 | 命令 |
|------|------|
| 加载 SDK/交叉编译环境 | `source build.sh` |
| 编译内核 + 内建 overlays | `./tools/build-kernel.sh kernel` |
| 生成 FIT boot.img | `./tools/build-kernel.sh boot` |
| 仅编译设备树 overlays | `./tools/build-kernel.sh overlays` |
| **完整固件** (kernel+boot+overlays+update.img) | `./tools/build-kernel.sh all` |
| 应用 rootfs overlay | `./tools/build-rootfs.sh apply` |
| 环境检查 | `make check` 或 `./tools/build-kernel.sh check` |
| 清理 | `make clean` |

## 工作流程

1. **先跑环境检查**：`make check`（确认 SDK/工具链/底包/打包工具就绪）
2. **按用户需求编译**：
   - app：`source build.sh` 后在 app 工程内 `make` 或 `cmake -DCMAKE_TOOLCHAIN_FILE=$CMAKE_TOOLCHAIN_FILE`
   - kernel：`./tools/build-kernel.sh kernel`（保留用户定制 .config；`FORCE_DEFCONFIG=1` 强制重置）
   - overlays：`./tools/build-kernel.sh overlays`（`overlay/*.dts` → `.dtbo`，打包时写入 rootfs `/boot/overlays/`）
   - rootfs：`./tools/build-rootfs.sh apply`（`overlay/` 文件覆盖写入工作副本）
   - firmware：`./tools/build-kernel.sh all`（完整流程，产物在 `build/result/`）
3. **产物位置**：
   - app：由 app 工程自身 Makefile/CMake 输出
   - kernel：`kernel/boot.img`
   - overlays：`build/overlays/*.dtbo`
   - rootfs overlay：`build/rootfs-overlay.img`
   - 固件：`build/result/update.img`

## 环境变量

- `JOBS=n` 并行编译数
- `FORCE_DEFCONFIG=1` 强制重新生成内核 .config
- `TOOLCHAIN_DIR=<目录>` 指定工具链目录
- `OVERLAY_DIR=<目录>` 指定 rootfs overlay 目录

## 常见坑

- **交叉编译环境**：app 工程先 `source build.sh`，CMake 工程使用 `$CMAKE_TOOLCHAIN_FILE`
- **rootfs 不污染底包**：写入始终发生在 `build/` 工作副本，`prebuilds/base_image/rootfs.img` 只作为输入
- **overlays**：内核内建 overlay（i2c3/i2c7/pwm2/spi1/uart1 disable）随 kernel 编译自动产出，自定义 overlay 放 `overlay/*.dts`
