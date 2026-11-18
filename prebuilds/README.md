# prebuilds/ 目录说明

QPi M1/L1 SDK 为 system-only SDK，默认流程只重建 Kernel 模块并生成：

```text
out-system/system.img
```

SDK 不生成 `boot.img`、DTB 或 DTBO，`prebuilds/` 中也不再预置 DTB/DTBO
编译清单。

## 运行时文件

干净 SDK 中不预置大型基线镜像。`buildenv` 根据当前官方固件包或已连接开发板
准备构建所需文件：

| 文件 | 用途 |
|---|---|
| `system.img` | `buildsystem` 替换 Kernel 模块时使用的原始系统镜像 |
| `kernel[.perf].release` | 当前 baseline 的 Kernel release，用于模块目录和 vermagic 校验 |
| `ramdisk.cpio.lz4` | factory baseline 中用于派生 Kernel release；device baseline 不生成 |
| `Image` / `dtb.img` / `dtbo.img` | factory baseline 的只读参考副本，不由默认流程重建或交付 |
| `baseline.platform` | 记录各 baseline 文件对应的 Profile，防止切换平台后混用 |
| `device-baseline.meta` | 记录 device baseline 的 config、release、system 大小/SHA-256 等身份信息 |

这些运行时文件均已由根目录 `.gitignore` 排除。

## Profile 与 Kernel 配置

SDK 支持 8 个 Profile：SC200U/SC200E × Debian/Linux × Normal/Perf。

- `config/kernel.config`：Normal Profile 工作配置；
- `config/kernel.perf.config`：Perf Profile 工作配置；
- `kernel.release`：Normal baseline 的 Kernel release；
- `kernel.perf.release`：Perf baseline 的 Kernel release。

Kernel config 由 `buildenv` 从 factory boot IKCONFIG 或开发板 `/proc/config.gz` 初始化。
Kernel release 优先使用已校验的落盘值；没有时，factory baseline 可从 ramdisk 的
`lib/modules/<release>` 目录派生。

## 构建边界

`buildall` 只执行：

```text
buildkernel -> buildstage -> buildsystem -> out-system/system.img
```

`boot.img`、Kernel Image、DTB、DTBO 和 ramdisk 不属于默认交付物。
