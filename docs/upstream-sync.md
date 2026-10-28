# 上游同步与 SDK 发布检查

## 同步范围与基线（2026-10-28）

- 上游：`/home/q/work/linux/RK3576_Linux6.1_BL01_v1.2.0`，分支 `SMARC_SH603ZA_buildroot`。
- 本次从 `0362838ecd40472c3b407476dfe83078d07adc44` 同步到
  `b1eaf88c5b1c554fabce8e5daa4cbc8fc9faa6f3`；状态以 `tools/upstream/base.txt` 为准。
- 上游区间涉及内核 45 个提交、1379 个文件（含合并提交），新增 9、修改 1369、重命名 1。
- 同步对象仅为目标提交跟踪的 `kernel-6.1/`，映射为 SDK `kernel/`。
  不读取上游未提交工作区；上游未跟踪的 `quectel-swap.config` 不自动纳入。
- 补齐历史提取漏掉的 108 个文件，包括 `tools/build/` 下 100 个构建辅助源码。
- **`prebuilds/` 和 `demo/` 全目录忽略，保留本机内容，不纳入提交。**
  历史已跟踪的 `prebuilds/.gitkeep` 仅为空占位文件，本次不修改、不暂存。
- 同步工具不会执行暂存、提交、推送。提交须另走团队确认流程。

同步前的内核源码、旧配置、同步状态和工作区补丁已备份在仓库外：
`/home/q/work/test/qpi-before-sync-20261028.rUr55V/`。
该路径仅为本机回滚备份，不是 SDK 构建依赖。

## SDK 保留的定制

同步后的 `tools/upstream/local/` 保存四个定制文件：

| 路径（相对 kernel） | 定制 |
| --- | --- |
| `arch/arm64/boot/dts/rockchip/rk3576-quectel-pi-m2-audio.dtsi` | HDMI 音频节点默认 disabled |
| `arch/arm64/boot/dts/rockchip/rk3576-quectel-pi-m2-linux.dtsi` | DP 音频节点默认 okay，其余采用上游 |
| `arch/arm64/configs/quectel-overlays.config` | SDK 既有 overlay 运行时定制 |
| `.gitignore` | 内核子树生成物忽略规则 |

container/exfat/joystick 片段和 `rockchip_linux_defconfig` 已与目标上游一致，
不再误记为 SDK 定制。误入库的 Mali 构建信息源文件已删除并忽略。

上游的 CAN0 overlay 与旧 PWM2 overlay 被 Git 判定为重命名：
内核移除旧 PWM2 源文件及旧产物，保留 SDK `overlay/` 下 PWM2 副本。
最终为四个总线禁用 overlay、CAN0 enable、SDK PWM2 disable，共 6 个。
复制内建 overlay 时只认当前 Makefile 声明，不再遍历所有历史 dtbo。

## 配置入口必须一致

`make defconfig`、`builddefconfig`、`tools/kernel-Makefile` 与
`tools/build-kernel.sh` 使用同一片段顺序：

```text
rockchip_linux_defconfig
  rk3576.config
  cma.config
  quectel-pwm-fan.config
  quectel-container.config
  quectel-exfat.config
  quectel-joystick.config
  quectel-m2-overlay.config
  rockchip_rt.config
  rockchip_panfrost.config
  quectel-overlays.config          # SDK 定制，置于官方片段之后
```

必需片段缺失时停止构建，不允许静默跳过。
**不要追加 `rockchip-debug.config`**：它不只是改变日志等级，
还可能改变内核配置及模块结构布局，破坏与底包预编译模块的兼容性。
当前日志等级为 1，`KPROBES`、`KALLSYMS_ALL` 未启用。

同步成功后旧 `.config` 自动改名为 `.config.before-sync.<时间戳>`；
下次构建重新生成配置。需要保留 menuconfig 定制时，先比较旧配置，不能整份盖回。
本次已执行 `make defconfig` 并完成内核、DTB 和五个内建 overlay 编译。

## 本次验证结果

- 目标上游 84,802 个文件逐一按 Git blob 内容、符号链接目标和可执行权限核对：
  缺失 0，类型/权限差异 0；仅两处音频定制与上游不同。
- 原先漏掉的 `kernel/tools/build/` 下 100 个源码已恢复，且不被忽略规则屏蔽。
- 内核完整编译通过，`6.1.118-rt36`；五个内建 overlay 加 SDK PWM2 共六个。
- 完整 `all` 构建及 Rockchip 打包成功，产物 `build/result/update.img`（约 5.5GB）、
  `build/result/boot.img`（约 46MB，Debian FIT）。
- 三个 AIC8800 模块和六个 overlay 已写入固件 rootfs 工作副本，逐个回读一致。
  AIC 三个模块的强未定义符号均可在本次 `Module.symvers` 的导出中找到。
  这是静态检查，不能代替实机 insmod 与功能测试。
- 底包 `rootfs.img` 构建前后 SHA-256 相同，未修改 `prebuilds/` 或 `demo/` 内容。
- 快照器六项回归测试通过，Shell 语法检查通过，编辑器未报告脚本错误。
- 未进行任何暂存、提交、推送，暂存区为空。实机回归尚未执行。

## 日常同步步骤

```bash
# 修改 kernel 后重新登记定制；只扫描源码，生成物受忽略规则排除。
./tools/sync-upstream.sh snapshot

# 先固定目标提交，不要依赖上游工作区临时切换的 HEAD。
./tools/sync-upstream.sh report --to <commit>
./tools/sync-upstream.sh apply --dry-run --to <commit>

# 对当前文件另做备份后执行。
./tools/sync-upstream.sh apply --to <commit>
make defconfig
JOBS=12 ./tools/build-kernel.sh all
```

工具行为：

- 目标必须是当前基准的后继提交，拒绝无关分支和回退。
- 同时扫描基准已有文件与 SDK 新增、非忽略文件，避免新增定制被覆盖。
- 扫描失败、未登记漂移、权限/类型变化、链接定制、三方合并冲突均停止。
- 上游删除了 SDK 定制文件时停止，要求人工解决改名/删除冲突。
- 三方合并结果在写盘前缓存，落盘不重新计算；不提供强制覆盖选项。
- 同步后自动刷新定制快照。无更新时也检查快照一致性。
- `--dry-run` 不改源码、配置或同步状态，但会使用临时目录，退出后自动清理。
- 完整写盘不是跨文件事务；磁盘写入失败或断电可能留下部分同步。
  因此必须有仓库外备份，不能把“预检无冲突”等同于“随时可以回滚”。

## 内核、模块、底包必须配套

### 实机发现的启动阻塞及修复（2026-10-28）

首次同步后的旧固件在 U-Boot 显示初始化时发生 Synchronous Abort，尚未进入 Linux。
旧底包 U-Boot 是 `Oct 22 2026 - 17:07:47`，没有自动识屏的面板和背光 compatible；
内核已切到 `waveshare,m2-auto-panel`，DSI 设备未挂接后被旧代码解引用。
从实际底包 FIT 提取的 `0x4026614c` 指令是 `ldr x22, [x0, #8]`，
与日志 `x0=0` 一致。附近 shun ELF 地址可用于辅助定位，但该 ELF 与底包并非同一构建，
不能直接把它的整份行号/栈解析当作准确结果。

**这是首次同步遗漏的 U-Boot 配套依赖，原“打包成功”固件不能用于发布。**
现将同上游 M2 的配套启动包收录到 `tools/boot/uboot-m2.img`：
构建标识 `Oct 26 2026 - 11:24:06`，包含自动识屏支持与空指针保护。
打包优先使用该文件，在工作目录替换 uboot，不修改 `prebuilds/`。
配套包的 ATF、OP-TEE、内部 DTB 与旧底包 FIT 哈希一致；文件及 FIT 载荷哈希已核验。
来源和 SHA-256 见 [启动资源说明](../tools/boot/README.md)。

已验证旧 U-Boot + 自动识屏 DTB 被检查入口拒绝，新包通过检查。
字符串检查仅是必要条件，修复后的固件仍需重新上板验收。
必须更新 U-Boot 和 boot 的组合，**仅烧 boot 分区仍会使用旧 U-Boot 并重现故障**。
优先使用重新打包后的完整 update，单独维护时使用同时输出的 uboot 镜像并核实分区。

内核允许模块构建，不能宣称“全部静态编译”或“lib/modules 为空”。
本次实测构建生成 AIC8800 bsp/fdrv/btlpm 三个模块；固件组装会将它们
写入 rootfs 工作副本的 `/usr/lib/modules/`，不改底包与 sysroot。
`debugfs write` 不会覆盖现有文件且部分错误返回 0，故现在先删旧文件再写入，
逐个回读校验；overlay 同样校验，失败则停止打包。

`pack` 不重新编译源码；若存在自编内核产物，会先重新生成 Debian FIT boot，
避免把 `kernel` 子命令产生的传统 boot 格式直接装入固件。
没有自编 boot 才用底包 boot，底包缺失则失败。
修改源码后应使用 `all`，不能用 `pack` 代替重新编译。

当前底包资源完整，并非仅有 rootfs：包含 loader、uboot、boot、misc、
recovery、oem、userdata、parameter、package-file 等。
本次未更换任何 `prebuilds/` 文件。抽出的 sysroot 显示版本 `.114`，
五个抽查 AIC 固件与目标上游一致，两个初始化脚本也一致。
这些抽查不能证明整个底包、全部预编译库与上游逐字节一致。

内核之外的 MPP、RKAIQ tuning、Debian 脚本/软件包、厂测工具不会
因源码同步自动更新；升级这些部分要另选同一版本的整套已验证底包，再重建 sysroot。
U-Boot 已通过本节所述 SDK 配套启动包修复，不再沿用不支持自动识屏的旧镜像。
uboot 中检测到微雪背光交接字符串只能证明已有部分支持，不能证明
4.3 寸自动识别已与最新驱动配套；必须上板测试。

## 发布前上板回归（未执行，不能据编译成功判定通过）

- 冷启动进入 Debian 桌面，检查 dmesg 无新 Oops/Unknown symbol；核对 `uname -r`。
- WiFi 扫描、连接及双向吞吐，BT 开关、配对、传输；核对加载的是配套模块。
- HDMI 1024x600、DSI 8 寸及 4.3 寸：开机 logo、背光、触控、休眠恢复。
- IMX219/IMX477：预览、曝光/3A、拍照，检查画面不过暗。
- NVMe 挂载读写、5G 冷启动枚举/拨号、PCIe 空槽休眠唤醒。
- SD/exFAT 卡、USB 存储拔插及读写；USB0 SuperSpeed、USB 手柄。
- RTC 联网/断网计时、S3 唤醒、普通 reboot 及 loader/fastboot 重启。
- 音频输出与麦克风录音；验证保留的 HDMI/DP 默认策略符合产品要求。
- Docker 启动；按板卡接线和 overlay 说明测试 CAN0 与 PWM2。

没有这些实机结果之前，本次只能标为“源码/构建验证完成”，不能标为“发布验收通过”。