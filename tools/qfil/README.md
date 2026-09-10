# QFIL 烧录后端 (Windows)

本目录是 **Windows 下烧录固件** 所用的 QFIL 后端，来自 Qualcomm QPST 安装包
(`C:\Program Files (x86)\Qualcomm\QPST\bin`)。

| 文件 | 作用 |
|------|------|
| `QSaharaServer.exe` | Sahara 协议：把 firehose 程序 (`prog_firehose_Qcm6490_ddr.elf`) 推给处于 EDL(9008) 的设备 |
| `fh_loader.exe` | Firehose 协议：按 `rawprogram*.xml` / `patch*.xml` 分区表把镜像写入 UFS/eMMC |

> 仅后端两个可执行文件，不含 QFIL 图形界面。二者为静态链接，导入表只有
> `KERNEL32.dll`，**无任何额外 DLL 依赖**，可脱离 QPST 独立运行，合计约 740 KB。

## 用法

Windows 上直接运行批处理（或从 Linux/WSL 的 `scripts/flash.sh` 自动转交）：

```bat
scripts\flash.bat            :: 默认 UFS
scripts\flash.bat emmc
```

`scripts/flash.sh` 会检测平台：Linux/WSL 走 `tools/qdl`；Windows 走本目录后端
并经 `scripts/flash.bat` 调用；macOS 直接报错退出。

## 前置条件

1. 设备已进入 **EDL (9008)** 模式
   - 正常运行的系统：`adb shell reboot edl`（注意不是 `adb reboot edl`）
   - panic 状态：断电重新上电并按住 EDL 组合键
2. 已安装 Qualcomm USB 驱动（QPST 或 LIBUSB 驱动包）
3. 固件已打包完成：`build/result/` 下存在
   `prog_firehose_Qcm6490_ddr.elf`、`efi.bin`、`system.img`、`dtb.bin` 及 `partition_ufs/`

## 等效手工命令

```bat
QSaharaServer.exe -p COM5 -s 13:prog_firehose_Qcm6490_ddr.elf -v 1
fh_loader.exe --port=COM5 --sendxml=partition_ufs\rawprogram0.xml,partition_ufs\patch0.xml,... ^
              --search_path=. --noprompt --memoryname=ufs --loglevel=1
```

## 许可说明

`fh_loader.exe` / `QSaharaServer.exe` 为 Qualcomm 专有软件，版权归 Qualcomm
Technologies, Inc.。随 QPST 分发，仅限在授权设备上用于固件烧录。
