# simple-h1 SDK 文档

## 固件结构 (QCS6490 / Quectel PI H1)

| 分区 | 文件 | 格式 | 内容 |
|------|------|------|------|
| efi | efi.bin | FAT16 (4K sector) | systemd-boot + UKI (Image+dtb+initramfs) |
| dtb | dtb.bin | FAT12 | combined-dtb.dtb (基dtb + dtbo 合并) |
| system | system.img | BTRFS | Debian 根文件系统 |

## 启动链路

```
UEFI (xbl) → systemd-boot (bootaa64.efi) → UKI (linux-qcm6490-idp.efi)
                                            ├─ .linux   内核 Image
                                            ├─ .dtb     合并后设备树
                                            ├─ .initrd  initramfs
                                            └─ .cmdline 内核参数
```

## 内核版本机制

- 内核: 6.6.116 (QCOM quectel 定制)
- 版本串: `6.6.116-qli-1.7-ver.1.1`
  - `-qli` 来自 LINUX_VERSION_EXTENSION (yocto)
  - `1.7-ver.1.1` 来自 DISTRO_VERSION
- 修改 scripts/env.sh 的 LOCALVERSION 和 scripts/kernel-config 的 CONFIG_LOCALVERSION 保持一致

## 设备树合并 (dtbo)

官方流程 (linux-qcom-mergedtb.bb):
```
qcs6490-idp-pi.dtb (带 __symbols__, DTC_FLAGS=-@)
  + qcm6490-graphics.dtbo
  + qcm6490-camera-rb3.dtbo
  + qcm6490-video.dtbo
  → combined-dtb.dtb
```

## 外置驱动 (不随内核编译, ko 预置)

| 驱动 | ko 位置 | 源码 |
|------|---------|------|
| yt6801 (rt6801 千兆网卡) | lib/modules/<ver>/updates/yt6801.ko | 不包含 (预置 ko) |
| r8168 | lib/modules/<ver>/updates/r8168.ko | 不包含 (预置 ko) |
| wlan (qca6490) | lib/modules/<ver>/updates/wlan.ko + qca6490.ko + cnss* | 不包含 (预置 ko) |
| quectel-wifi | lib/modules/quectel-wifi/updates/wlan.ko | 不包含 (预置 ko) |

这些 ko 来自官方固件 system.img, 编译匹配 6.6.116-qli-1.7-ver.1.1 内核。
若修改内核版本, 需重新从官方固件提取或自行编译。
