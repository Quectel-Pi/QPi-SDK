# Overlay（增量预置目录）

本目录是 M2 SDK 的**增量预置目录**，支持两种内容：

## 1. 应用层文件覆盖（客户自定义应用/脚本/服务）

目录结构 == rootfs 根路径，打包时自动写入文件系统镜像。

```
overlay/
├── etc/                    # → /etc
│   └── test-overlay.conf   #   配置文件
└── opt/
    └── test-app.sh         #   可执行脚本 (自动加 0755)
```

**使用**：

```bash
# 把客户自定义文件放进 overlay/ 对应路径
# 应用 overlay 到文件系统镜像 (输出 build/rootfs-overlay.img)
./tools/build-rootfs.sh apply

# 或删除镜像中的文件
./tools/build-rootfs.sh remove /opt/xxx

# 或解压/重新打包
./tools/build-rootfs.sh extract <img> <dir>
./tools/build-rootfs.sh repack <dir> <img>
```

## 2. 设备树 Overlays（.dts → .dtbo）

放 `.dts` 文件，编译为 `.dtbo` 并写入 rootfs `/boot/overlays/`。

```bash
./tools/build-kernel.sh overlays    # 仅编译设备树 overlays
./tools/build-kernel.sh all         # 完整打包 (overlays 进 /boot/overlays/)
```

内核已内建 5 个 overlay（随内核编译自动生成）：
`i2c3/i2c7/pwm2/spi1/uart1` disable

**写一个新 overlay**：

```dts
/dts-v1/;
/plugin/;

/ {
    fragment@0 {
        target-path = "/";
        __overlay__ {
            /* 自定义节点 */
        };
    };
};
```

## 注意

- **应用层文件**目录结构 = rootfs 路径，可执行文件自动加 0755
- **设备树 overlay** 是 `overlay/*.dts` 源码，与普通文件区分；`build-rootfs.sh apply` 会跳过 `.dts/.dtbo` 和本 README，`build-kernel.sh all` 会把编译后的 `.dtbo` 写入 rootfs `/boot/overlays/`
- 打包始终用工作副本，**不污染** `prebuilds/base_image/` 底包
