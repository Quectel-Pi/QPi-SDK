---
name: sdk-flash
description: "烧录 Quectel M2 固件（rkdeveloptool 开源链路）。覆盖：检测设备（Maskrom/Loader 模式）、查看分区表、烧录完整 update.img 或单分区（boot/rootfs/uboot）、烧录前干跑验证。当用户说「烧录」「刷机」「flash」「rkdeveloptool」「烧固件」「刷update.img」「写boot分区」时使用。WHEN: flash, rkdeveloptool, burn firmware, update.img flash, partition write, 烧录, 刷机, 刷固件. DO NOT USE FOR: 编译固件（用 sdk-build skill），JIRA 工单修复（用 jira-fix-helper）。"
license: MIT
metadata:
  author: GitHub Copilot
  version: "1.0.0"
---

# Quectel M2 烧录助手（rkdeveloptool）

> M2 用 Rockchip 开源烧录工具 rkdeveloptool，区别于高通 QFIL 闭源，是 M2 差异化卖点。

## 前置条件

- 已安装 `rkdeveloptool`（安装: https://github.com/rockchip-linux/rkdeveloptool）
- 板子进入 **Maskrom/Loader 模式**（按住 RECOVERY 键再上电/复位）
- 串口/USB 已连接主机

## 工作流程

1. **检查工具**：`make check` 确认编译环境，`rkdeveloptool ld` 确认烧录工具和设备
2. **检测设备**：确认板子被识别（Loader 模式显示设备，Maskrom 模式为空需先 `rkdeveloptool db MiniLoaderAll.bin` 加载 loader）
3. **查看分区表**：`parameter.txt` 里的 mtdparts 定义分区（persist/nvdata/uboot/misc/boot/recovery/backup/rootfs/oem/userdata）
4. **烧录**（两种方式）：
   - 完整固件：loader 引导后 `rkdeveloptool wl 0 update.img` 整包写入
   - 单分区：`rkdeveloptool wl <分区起始扇区> <分区镜像>`（如 boot.img 写 boot 分区）
5. **验证**：`rkdeveloptool rd 0 <长度> <输出文件>` 读取校验

## 关键命令

```bash
# 检测设备
rkdeveloptool ld

# Maskrom 模式加载 loader
rkdeveloptool db prebuilds/base_image/MiniLoaderAll.bin

# 整包烧录
rkdeveloptool wl 0 build/result/update.img

# 单独烧 boot 分区 (boot 分区起始 0x1A000 扇区单位, 见 parameter.txt)
rkdeveloptool wl 0x1A000 build/result/boot.img

# 校验
rkdeveloptool rd 0 0x1000 check.bin
```

## 分区表参考（M2 Debian）

```
mtdparts=:0x00010000@0x00002000(persist),0x00002000@0x00012000(nvdata1),
0x00002000@0x00014000(nvdata2),0x00002000@0x00016000(uboot),
0x00002000@0x00018000(misc),0x00020000@0x0001A000(boot),
0x00040000@0x0003A000(recovery),0x00010000@0x0007A000(backup),
0x067B2000@0x0008A000(rootfs),0x00040000@0x0683C000(oem),
-@0x0687C000(userdata:grow)
```

> 注意：`wl` 的分区偏移单位是 **扇区（512B）**，parameter.txt 中 `@` 后是 512B 扇区号。

## 常见坑

- **Maskrom 下直接 `wl` 会失败**：必须先 `db` 加载 loader
- **烧错分区清数据**：烧 rootfs/boot 不影响 persist（SN/MAC），烧 userdata 会清数据
- **USB 权限**：无权限时加 udev 规则或 `sudo`
- **建议先干跑**：确认 loader 和镜像路径正确再实烧
