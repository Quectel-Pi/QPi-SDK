---
name: sdk-overlays
description: "管理 Quectel M2 设备树 overlays（Rockchip dtbo 机制）。覆盖：编写 overlay .dts、编译为 .dtbo、打包进固件 rootfs /boot/overlays/、板端启用/禁用 overlay、内核内建 overlay 参考（i2c3/i2c7/pwm2/spi1/uart1 disable）。当用户说「设备树overlay」「写overlay」「禁用i2c」「禁用串口」「dtbo」「overlay怎么用」「设备树覆盖」「启用外设」时使用。WHEN: device tree overlay, dtbo, dtc, disable uart, disable i2c, overlay compile, 设备树覆盖, overlay管理. DO NOT USE FOR: 内核驱动开发（直接改 kernel/ 源码），外设参数问题（用 m2-peripherals-guide）。"
license: MIT
metadata:
  author: GitHub Copilot
  version: "1.0.0"
---

# Quectel M2 设备树 Overlay 管理

> M2 基于 Rockchip RK3576，支持标准设备树 overlay（`.dtbo`）机制，运行时动态启用/禁用外设，无需改内核。

## 目录与产物

```
ai_sdk/
├── overlay/                     # ★ 自定义 overlay 放这里 (.dts)
│   └── example-overlay.dts      #   示例节点
└── build/overlays/              # 编译产物 (.dtbo)
```

内核内建 overlay（编译时自动产出，见 `kernel/.../dts/rockchip/Makefile`）：

| overlay | 作用 |
|---------|------|
| `rk3576-quectel-pi-m2-i2c3-disable.dtbo` | 禁用 I2C3 |
| `rk3576-quectel-pi-m2-i2c7-disable.dtbo` | 禁用 I2C7 |
| `rk3576-quectel-pi-m2-pwm2-disable.dtbo` | 禁用 PWM2 |
| `rk3576-quectel-pi-m2-spi1-disable.dtbo` | 禁用 SPI1 |
| `rk3576-quectel-pi-m2-uart1-disable.dtbo` | 禁用 UART1 |

## 工作流程

1. **写 overlay**：在 `overlay/` 新建 `<name>.dts`

```dts
/dts-v1/;
/plugin/;

/ {
    fragment@0 {
        target-path = "/";
        __overlay__ {
            /* 你的节点 */
        };
    };
};
```

2. **编译**：`./tools/build-kernel.sh overlays`
3. **打包进固件**：`./tools/build-kernel.sh all`（overlays 自动写入 rootfs `/boot/overlays/`）
4. **板端启用**：在 `/boot/extlinux/extlinux.conf` 的 FDT 后追加 overlay 列表，或手动加载：

```bash
# 板子上 (overlay 已随固件在 /boot/overlays/)
# 方式 A: extlinux.conf 追加
#   fdt /overlays/rk3576-quectel-pi-m2-i2c3-disable.dtbo
# 方式 B: 运行时测试 (需 /configfs/device-tree 支持)
```

## 参考：内核内建 overlay 源码

```bash
cat kernel/arch/arm64/boot/dts/rockchip/rk3576-quectel-pi-m2-i2c3-disable.dts
```

典型 disable overlay 结构（用 `target` 引用节点 + status 改 disabled）：

```dts
/dts-v1/;
/plugin/;

/ {
    fragment@0 {
        target = <&i2c3>;
        __overlay__ {
            status = "disabled";
        };
    };
};
```

## 常见坑

- **`/plugin/` 必须声明**：否则 dtc 按普通 dtb 编译，无法作为 overlay 加载
- **`-@` 编译选项**：需要符号表支持 fragment，build.sh 已自动处理
- **改 overlay 后必须重打包**：overlays 编译进 rootfs，只编内核不打包不会生效
- **disable 类 overlay**：适合有硬件冲突时禁用外设，避免与其它模块争引脚
