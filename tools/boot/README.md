# M2 启动资源与显示兼容要求

## 配套 U-Boot

`uboot-m2.img` 为上游 M2 构建的 Rockchip FIT 启动固件，供当前内核自动识屏 DTB 使用。
它与 SDK 一起分发，不依赖开发者本机完整源码树；不是从网络动态下载的浮动版本。

- 来源：`/home/q/work/linux/RK3576_Linux6.1_BL01_v1.2.0/u-boot/uboot.img`
- 导入时仓库提交：`b1eaf88c5b1c554fabce8e5daa4cbc8fc9faa6f3`
- 导入时 u-boot 子树无已跟踪的未提交修改。
- 构建标识：`U-Boot 2017.09 (Oct 26 2026 - 11:24:06 +0800)`。
- FIT 板型：`rk3576-quectel-pi-m2`；`CONFIG_DEFAULT_DEVICE_TREE` 同名。
- 文件 SHA-256：`014ee0f8adfa35297c12a0e9d684ed8de43bb8d49987a5e588ae00321b595e55`。
- ATF 三段、OP-TEE 与内部 U-Boot DTB 的 FIT 哈希均与原底包相同。
  只替换配套启动包，不变更 loader、分区表或底包文件。
- 包含 `waveshare,m2-auto-panel` / `waveshare,m2-auto-backlight` 支持和
  DSI 设备未挂接时跳过显示的保护；相关上游提交为 `aeca11c363`。

本文件记录的是既有上游构建产物来源，不宣称它是从导入时 HEAD 全量重编的可复现构建。
**尚需硬件启动与显示回归，静态检查不能替代验收。**

## 为什么不能沿用旧启动包

旧底包 U-Boot 编译于 `Oct 22 2026 - 17:07:47`，早于自动识屏提交。
内核 DTB 新面板 compatible 为 `waveshare,m2-auto-panel`，旧 U-Boot 不支持，
导致 DSI 子设备未挂接。日志 PC `0x4026614c` 对应实际旧镜像指令
`ldr x22, [x0, #8]`，当 `x0=0` 时在内核启动之前产生 Synchronous Abort。
因此看到微雪背光字符串不能推断 U-Boot 已支持自动识屏。

## 选择与校验

`tools/build-kernel.sh` 按以下顺序选 U-Boot：

1. 显式环境变量 `QPI_UBOOT_IMAGE`。
2. 随 SDK 分发的 `tools/boot/uboot-m2.img`（校验配套 sha256 文件）。
3. 底包 U-Boot（仅在没有配套文件时兜底，仍须通过兼容性检查）。

打包会在修改产物目录之前检查：M2 板型标识，以及自动识屏 DTB 所需的两个
compatible 字符串。该检查是必要条件，不是签名认证或完整兼容性证明。
旧底包与自动识屏 DTB 的组合必须报错，不允许继续生成固件。

完整升级优先烧录新 `build/result/update.img`；其中同时含配套 uboot 和 boot。
只烧新 boot、保留旧 uboot 不能解决本次故障。
`build/result/uboot.img` 供熟悉当前分区布局的维护人员单独更新 U-Boot 使用；
不要擦除 loader 或修改分区表，也不要在未确认烧录目标时执行写入。