---
name: simple-h1-usb
description: "simple-h1 SDK: Type-C(USB3+DP Alt)/双 A 口 HUB 的 DTS 与 dwc3 驱动核对、qusb PID 切换、ADB 掉线恢复"
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [qualcomm, qcs6490, quectel, simple-h1, usb, typec, dwc3, qusb, adb]
    related_skills: [simple-h1-pcie, simple-h1-build, simple-h1-flash]
---

# simple-h1 USB — Type-C(USB3.1 + DP) / 双 A 口 HUB / 复合模式

## 0. 能力边界

| 部分 | 本 SDK 里能不能改 |
|---|---|
| `usb_1`/`usb_2`、HS 与 USB3+DP PHY、EUD、extcon、SBU mux | **能**，驱动都在 `kernel/` 内 |
| Type-C CC 检测芯片 SGM7220 | DTS 节点在，`kernel/` 里**没有**它的驱动；实际角色/朝向走 `pmic-glink` |
| `qusb` 复合模式工具 | 镜像自带可执行文件，**本 SDK 不含源码**，只能按设备侧命令用 |

## 1. 硬件事实

| 接口 | 控制器 / 方案 | 连接器 | 说明 |
|---|---|---|---|
| **Type-C** | `usb_1`(dwc3) + `usb_1_qmpphy`（USB3 **+ DP**） | **`J1501`** | USB 3.1 扩展口 + DP over Type-C + PD 供电入口 |
| Type-C 供电 | **CH223 / CH224** PD 控制器 | `J1501` | 需 **PD 9V/3A 或 5V/5A** 适配器 |
| CC/角色检测 | **SGM7220** @ `i2c1 0x47` | — | `option-gpio=tlmm10`、`int-gpio=tlmm95`、`cc-id-gpio=tlmm127` |
| PD/角色框架 | `pmic-glink`（`qcom,sm8350-pmic-glink`） | `J1501` | `orientation-gpios=tlmm140`，`power-role/data-role = dual` |
| SBU（DP AUX）切换 | `gpio-sbu-mux`（DIO32221MP10） | — | `enable-gpios=tlmm165`、`select-gpios=tlmm166` |
| **双 USB-A** | `usb_2`(dwc3, HS) → **CH334** USB2.0 HUB | **`J1801`** | 仅 Host，**最高 480 Mbps** |
| A 口插拔检测 | `usb_typeb_detect`（`linux,extcon-usb-gpio`） | — | `vbus-gpio=tlmm125`、`id-gpio=tlmm27`（input + pull-up） |
| EUD（底层调试） | `&eud { usb-role-switch; }` | Type-C | 走 `eud_con`/`eud_ep` 端点对 |
| 40Pin 常开电 | `pin40_en_vreg` → **tlmm 9** | — | `regulator-always-on`，1.8V（⚠ 与 PCIe1 `device_oe_en` 同脚） |

DTS（`kernel/arch/arm64/boot/dts/qcom/qcs6490-idp-pi.dts`）：`:27`（删 `usb_2_dwc3`）、
`:91-136`（pmic-glink）、`:655-666`（EUD 端点）、`:831-854`（被注释掉的 `fsa4480`）、
`:1666`（删 `usb_1_dwc3`）、`:1668-1712`（`&usb_1`）、`:1714-1720`（`usb_1_hsphy`）、
`:1722-1737`（`usb_1_qmpphy` 及出/DP 入）、`:1772-1799`（`&usb_2`）、`:1801-1807`（`usb_2_hsphy`）、
`:1810-1847`（SGM7220）、`:1849-1877`（A 口检测脚 + extcon）、`:1880-1927`（SBU mux）、
`:1930-1940`（pin40）。

## 2. 关键 DTS 与改写注意

```dts
&usb_1 {
    phys = <&usb_1_hsphy>, <&usb_1_qmpphy QMP_USB43DP_USB3_PHY>;
    maximum-speed = "super-speed";
    snps,dis_u2_susphy_quirk;  snps,dis_enblslpm_quirk;
    snps,dis-u2-entry-quirk;   snps,dis-u1-entry-quirk;
    dr_mode = "otg";  usb-role-switch;  qcom,enable-rt;
};
&usb_2 {                          // A 口
    maximum-speed = "high-speed";  dr_mode = "host";
    phys = <&usb_2_hsphy>;
};
```

- `usb_1_dwc3` / `usb_2_dwc3` 子节点被 **`/delete-node/`** 删掉，控制器改写成扁平节点
  （自定 `reg`/`interrupts-extended`/`iommus`）。**不要照 `qcm6490.dtsi` 的原始定义推理**。
- 那 4 个 `snps,*quirk` 是这块板跑稳的必要条件（U1/U2 entry、susphy、enblslpm），不是冗余。
- `usb_2` 的 `usb-role-switch` 已注释，**A 口固定 Host**。
- `usb_1_qmpphy` 带 `orientation-switch`；DP 通路 `mdss_dp_out → usb_1_qmpphy_dp_in`，
  SBU 走 `gpio-sbu-mux`。**`fsa4480` 那段在 `&i2c1` 里整段被注释**（`:831-854`），
  不要以为有外部 redriver。
- SGM7220 的 `port/endpoint@0..2` 三个 `remote-endpoint` 全被注释；它当前只是 I2C 从设备节点，
  **角色切换由 pmic-glink 决定**。

> **实测**（同板，USB 接主机做 adb）：`/sys/class/typec/port0/data_role = device`、`power_role = sink`；
> UDC `a600000.usb` 状态 `configured`；`lsusb -t` 只看到 480M 的一条总线 + 4 口 HUB（USB3 主机口未启用时正常）；
> `qusb showpid` 可列出 A4A1/4EE7/901C/901D/9015/9024 等 PID 组合。

## 3. 设备侧诊断

```bash
lsusb -t ; ls /sys/bus/usb/devices/
cat /sys/class/usb_role/*/role 2>/dev/null          # host / device / none
cat /sys/class/typec/port0/data_role 2>/dev/null
dmesg | grep -iE "dwc3|qmp|typec|pmic_glink|xhci|hub|extcon"
lsusb | grep -i "1a86\|hub"                         # A 口: root hub + 2 下游口
cat /sys/class/udc/*/state 2>/dev/null ; ls /sys/class/power_supply/
```

ADB / 重启（**板上铁律**）：

```bash
adb devices
adb shell reboot        # ⚠️ 必须走 adb shell, `adb reboot` 在这块板不管用
adb shell reboot edl    # 进 EDL
./scripts/flash.sh
```

## 4. qusb：复合模式（PID）

```bash
which qusb ; qusb            # 先确认工具在, 无参输出 usage
qusb bind              # 绑定 configfs 与 gadget
qusb unbind            # 解绑
qusb setpid <PID>      # 立即切换
qusb setpid -p <PID>   # 设为默认（持久化）
qusb showpid           # 列出全部支持的 PID 组合（权威清单）
qusb persist <PID>     # 只持久化
```

> 这版工具 usage 里**没有 `init`**；需要"挂 configfs + 建节点"的效果就直接 `qusb bind`。
> **不要在 adb 会话里贸然 `qusb unbind`**：adb 自己就走 gadget，会把自己踢下线
> （先备好串口或 ssh 回连）。PID 组合因镜像而异，**以 `qusb showpid` 实际输出为准**。

**USB 模拟网卡**：

```bash
qusb showpid | grep -i ncm        # 选一个含 NCM + ADB 的 PID
qusb setpid <PID> ; ifconfig -a   # 设备侧出现 usb0
ip addr add dev usb0 192.168.0.5/24
# 主机侧: ip addr add dev <网卡> 192.168.0.6/24 ; ping 192.168.0.5
```

## 5. 内核侧可改点

| 目标 | 源码 |
|---|---|
| dwc3 核心 / gadget | `kernel/drivers/usb/dwc3/core.c`、`core.h`、`gadget.c` |
| QCOM glue（模式、PHY 选择） | `kernel/drivers/usb/dwc3/dwc3-qcom.c` |
| USB3+DP 组合 PHY | `kernel/drivers/phy/qualcomm/phy-qcom-qmp-usb.c` |
| SBU mux | `kernel/drivers/usb/typec/mux/gpio-sbu-mux.c` |
| A 口 extcon | `kernel/drivers/extcon/extcon-usb-gpio.c` |
| PD/角色 | `kernel/drivers/soc/qcom/pmic_glink.c` + `kernel/drivers/usb/typec/` |

内核选项（`scripts/kernel-config`）：`CONFIG_USB_DWC3=y`、`CONFIG_USB_DWC3_QCOM=y`、
`CONFIG_PHY_QCOM_QMP_USB=y`、`CONFIG_TYPEC=y`、`CONFIG_TYPEC_MUX_GPIO_SBU=m`、
`CONFIG_USB_ROLE_SWITCH=y`、`CONFIG_EXTCON_USB_GPIO=y`、`CONFIG_USB_CONFIGFS=y`。
改完下发：`./scripts/build-kernel.sh` 后，内建 (`=y`) 改动走 `pack-efi.sh` + `pack-dtb.sh`；
编成模块 (`=m`, 如 `TYPEC_MUX_GPIO_SBU`) 还要 `pack-system.sh` 把 ko 并进 system.img。直接 `./scripts/build-all.sh` 最省事。

## 6. 已知坑

1. **`adb reboot` 无效**，必须 `adb shell reboot`。
2. **改 `phys`/`dr_mode` 前先看那 4 个 quirk**：删掉容易 U1/U2 entry 挂死或 suspend 不唤醒。
3. **`usb_1_dwc3_hs` 端点仍被 `eud_ep` 引用**（`:1710-1712`），动端点会连带影响 EUD 调试通路。
4. **A 口永远 480 Mbps**：CH334 是 USB2.0 HUB，硬件限制，不要按 USB3 预期。
5. **Type-C 出图与 USB3 不能同时满速**：共用 QMP PHY 通道，由 SBU mux 切 AUX。
6. **`pin40_en_vreg`(tlmm9) 与 PCIe1 `device_oe_en`(tlmm9) 撞脚**，插 PCIe1 设备时留意。
7. **PID 里不含 ADB 就连不上 adb**：切错（纯 DIAG / 纯 MASS_STORAGE）后要串口登录再
   `qusb setpid`；持久化值在 `/etc/usb/usb_pid`，异常时可删该文件回默认。

## 7. 扩展

- **USB 摄像头（UVC）/ 声卡（UAC2）**：选带 UVC / UAC2 的 PID 组合，`lsusb -t` 看等时带宽、
  `aplay -l` 看卡号。
- **Type-C 接 USB 网卡**：比 A 口快（A 口只有 480 Mbps）。
- **改 PCIe 后回归 USB**：PCIe/USB3/DP 在 SoC 层共享部分 SerDes 资源（见 `simple-h1-pcie`）。
