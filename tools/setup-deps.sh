#!/usr/bin/env bash
# ============================================================================
# setup-deps.sh - H1 (QCS6490) SDK 构建依赖检测 / 一键安装
# ============================================================================
# 本 SDK 的构建依赖清单集中维护在本脚本 (4 个数组 + 1 组附加提示):
#   REQUIRED_TOOLS        -- "命令名:apt 包名"        (command -v 探测)
#   REQUIRED_LIBS         -- "apt 包名"               (dpkg -s 探测)
#   REQUIRED_FILES        -- "候选头文件路径|...:apt" (文件存在性探测)
#   REQUIRED_PY_MODULES   -- "模块名:apt 包名"        (python3 -c import 探测)
#   advisory_checks()     -- 平台/发行版/btrfs 版本/磁盘/厂商资源等非包风险提示 (仅告警)
#   - 不同 SDK (M1/M2/H1/L1...) 环境需求不同, 各自维护自己的 setup-deps.sh
#   - 插件 / CI / 用户只需要调用本脚本, 不需要知道装了哪些包
#
# H1 与 M2 差异: H1 固件底包 (prebuilds/efi.bin/dtb.bin/system.img) 体积达数 GB 不进仓库,
#   由 tools/fetch-prebuilds.sh 从官方固定地址下载 (curl + unzip, 已列入本清单); rootfs 为 BTRFS, 打包依赖 btrfs-progs/rsync/fakeroot;
#   EFI 打包依赖 python3(ukify)/mtools; 烧录 (qdl/EDL) 依赖 usbutils + libusb 等。
#
# 用法:
#   ./tools/setup-deps.sh           # = check
#   ./tools/setup-deps.sh check     # 检测缺失: 缺失包名逐行输出到 stdout (机器可读),
#                                   # 人类提示走 stderr; exit 0=齐全, 1=有缺失/环境不对
#   ./tools/setup-deps.sh install   # 用 sudo 安装缺失依赖 (密码从 stdin 读)
#
# 密码安全:
#   - install 模式从 stdin 读取 sudo 密码 (echo '<密码>' | 本脚本 或 < 密码文件),
#     交互终端下会静默提示输入; 密码不进命令行参数 / shell 历史
#   - 脚本内部用 here-string 喂给 sudo -S, 不经过任何外部进程 argv
# ============================================================================
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/.." && pwd)"

# ---- 依赖清单: "检测命令:apt 包名" ----
# 命令名用于 command -v 探测, 包名用于 apt-get install。
# 按用途分组维护, 新增依赖时在这里加一行即可。
REQUIRED_TOOLS=(
  "make:make"                              # 内核 / 应用构建
  "gcc:build-essential"                    # 内核 host 工具编译
  "git:git"                                # 仓库 / 资源获取
  "curl:curl"                              # 固件底包下载 (tools/fetch-prebuilds.sh)
  "unzip:unzip"                            # 固件底包解压 (tools/fetch-prebuilds.sh)
  "file:file"                              # 镜像类型识别
  "flex:flex"                              # 内核编译 (词法分析)
  "bison:bison"                            # 内核编译 (语法分析)
  "bc:bc"                                  # 内核编译 (算术)
  "lz4c:lz4"                               # 内核 Image.lz4 压缩 (Makefile: LZ4 = lz4)
  "python:python-is-python3"               # mkimg/bmpconvert 等 env python 脚本兼容
  "dtc:device-tree-compiler"               # dtc 设备树编译
  "fdtoverlay:device-tree-compiler"        # dtbo overlay 合并 (与 dtc 同包)
  "python3:python3"                        # ukify 打包 UKI
  "mcopy:mtools"                           # 免 root 更新 FAT (efi.bin/dtb.bin)
  "btrfs:btrfs-progs"                      # btrfs restore 提取 sysroot
  "mkfs.btrfs:btrfs-progs"                 # rootfs 打包 (与 btrfs 同包)
  "rsync:rsync"                            # base → staging 合成
  "fakeroot:fakeroot"                      # repack 属主伪装 (缺失仅警告)
  "qemu-aarch64-static:qemu-user-static"   # 应用层交叉编译 (rootfs GCC wrapper)
  "cmake:cmake"                            # CMake 工程应用
  "lsusb:usbutils"                         # 烧录 EDL 设备探测
  "depmod:kmod"                            # 内核 modules_install (缺则静默不生成 modules.dep, 设备端模块加载失败)
  "patchelf:patchelf"                      # 工具链 ELF 解释器修复 (tools/repair-toolchain.sh)
)

# ---- 动态库 / 开发头文件依赖 (无命令可探测, 用 dpkg -s) ----
REQUIRED_LIBS=(
  "libusb-1.0-0"                           # qdl USB 通信
  "libxml2-dev"                            # qdl XML 解析
  "libzip-dev"                             # qdl 压缩包读取
  "libssl-dev"                             # openssl 头文件 (模块签名 / certs 工具, 切换配置时启用)
)

# ---- 开发头文件依赖 (无命令可探测, 且头文件路径跨发行版不同, 用文件存在性) ----
# 格式 "候选路径1|候选路径2:apt 包名", 任一路径存在即视为已安装
REQUIRED_FILES=(
  "/usr/include/libelf.h|/usr/include/elfutils/libelf.h|/usr/include/gelf.h:libelf-dev"  # 内核 objtool / BTF (改配置启用时)
  "/usr/include/ncurses.h|/usr/include/ncursesw/ncurses.h:libncurses-dev"                # 内核 make menuconfig (buildmenuconfig)
)

REQUIRED_PY_MODULES=(
  "pefile:python3-pefile"                  # tools/uki/ukify 打包 UKI (第 52 行顶层 import)
)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info() { echo -e "${CYAN}[INFO]${NC} $1" >&2; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1" >&2; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }

# 输出缺失的 apt 包名 (每行一个, 去重保持清单顺序)
missing_pkgs() {
    for entry in "${REQUIRED_TOOLS[@]}"; do
        local tool="${entry%%:*}" pkg="${entry#*:}"
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "$pkg"
        fi
    done
    for pkg in "${REQUIRED_LIBS[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || echo "$pkg"
    done
    for entry in "${REQUIRED_PY_MODULES[@]}"; do
        local mod="${entry%%:*}" pkg="${entry#*:}"
        python3 -c "import $mod" >/dev/null 2>&1 || echo "$pkg"
    done
    for entry in "${REQUIRED_FILES[@]}"; do
        local paths="${entry%%:*}" pkg="${entry#*:}" found=0 p
        local IFS='|'
        for p in $paths; do
            if [ -e "$p" ]; then found=1; break; fi
        done
        unset IFS
        [ "$found" = "1" ] || echo "$pkg"
    done
}

# ---- 附加检查: 不参与包清单, 只提示"包都装了也可能踩坑"的环境风险 (输出到 stderr) ----
# 能力对齐自 tools/setup-env.sh: 平台门禁 / 发行版基线 / btrfs-progs 版本 / 磁盘容量 / 厂商独立分发资源
advisory_checks() {
    case "$(uname -s)" in
        Darwin|MINGW*|MSYS*|CYGWIN*)
            log_err "当前平台 $(uname -s) 无法原生编译本 SDK: 仓库自带 tools/qdl、tools/adb 是 Linux x86-64 ELF, 打包还依赖 mount -o loop / btrfs / fakeroot"
            log_info "请改用 Ubuntu 22.04 (物理机 / 虚拟机 / WSL2)"
            ;;
    esac

    if [ -r /etc/os-release ]; then
        local pretty ver
        pretty="$(grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
        ver="$(grep -m1 '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
        case "$ver" in
            22.04) log_ok "宿主: ${pretty} (设计基准版本)" ;;
            "")    log_info "宿主: ${pretty}" ;;
            *)     log_warn "宿主: ${pretty} — 设计基准为 Ubuntu 22.04, 其他版本请留意 btrfs-progs 行为差异" ;;
        esac
    fi

    # btrfs-progs 主版本: 6.x 会忽略 -b 自动扩展, system.img 可达 17.9GB 超出 GPT system 分区,
    # 烧录后内核挂载 rootfs 失败、反复重启 (见 tools/build-rootfs.sh 注释)
    if command -v btrfs >/dev/null 2>&1; then
        local bv bmaj
        bv="$(btrfs --version 2>/dev/null | awk '{print $NF}' || true)"
        bv="${bv#v}"
        bmaj="${bv%%.*}"
        case "$bmaj" in
            ''|*[!0-9]*) log_warn "无法解析 btrfs-progs 版本: '${bv}'" ;;
            5) log_ok "btrfs-progs ${bv} (tools/build-rootfs.sh 以 5.16 为基准)" ;;
            *) log_warn "btrfs-progs ${bv} 非 5.x — 打包产物 system.img 可能超出 system 分区, 烧录后内核挂载 rootfs 失败重启; 打包后请核对 system.img 大小" ;;
        esac
    fi

    # 磁盘可用空间: 内核编译 + 镜像打包建议 >= 30GB
    local avail_gb=""
    avail_gb="$(df -BG --output=avail "$ROOT_DIR" 2>/dev/null | tail -1 | tr -dc '0-9' || true)"
    if [ -n "$avail_gb" ]; then
        if [ "$avail_gb" -ge 30 ]; then
            log_ok "可用磁盘 ${avail_gb}GB"
        else
            log_warn "可用磁盘仅 ${avail_gb}GB — 内核编译 + 镜像打包建议 >=30GB"
        fi
    fi

    # 厂商独立分发资源 (不在仓库内, 缺任一项都无法产出可烧录固件)
    if [ -x "$ROOT_DIR/toolchains/gcc/bin/aarch64-qcom-linux/aarch64-qcom-linux-gcc" ] \
        || command -v "${CROSS_COMPILE:-aarch64-qcom-linux-}gcc" >/dev/null 2>&1; then
        log_ok "内核工具链 aarch64-qcom-linux-gcc 可用"
    else
        log_warn "内核工具链 aarch64-qcom-linux-gcc 不可用 — toolchains/gcc/ 由厂商独立分发, 缺失时 buildkernel 会在自检阶段退出"
    fi
    if [ -d "$ROOT_DIR/prebuilds/sysroot" ]; then
        log_ok "prebuilds/sysroot 存在"
    else
        log_warn "prebuilds/sysroot 缺失 — 厂商未分发, buildapp 将退回宿主 aarch64-linux-gnu-gcc"
    fi
}

cmd_check() {
    if ! command -v apt-get >/dev/null 2>&1; then
        log_err "未找到 apt-get, 当前环境不是 Debian/Ubuntu"
        return 1
    fi
    local missing
    missing="$(missing_pkgs | awk '!seen[$0]++')"
    if [ -z "$missing" ]; then
        log_ok "所有构建依赖已齐全"
        advisory_checks
        return 0
    fi
    log_err "缺少以下构建依赖:"
    echo "$missing" | sed 's/^/    /' >&2
    log_info "安装: ./tools/setup-deps.sh install   (需 sudo 密码, 从 stdin 输入)"
    advisory_checks
    echo "$missing"
    return 1
}

cmd_install() {
    command -v apt-get >/dev/null 2>&1 || { log_err "未找到 apt-get, 当前环境不是 Debian/Ubuntu"; return 1; }

    local missing
    missing="$(missing_pkgs | awk '!seen[$0]++')"
    if [ -z "$missing" ]; then
        log_ok "所有构建依赖已齐全, 无需安装"
        advisory_checks
        return 0
    fi

    local SUDO_PASS=""
    if [ "$(id -u)" != "0" ]; then
        command -v sudo >/dev/null 2>&1 || { log_err "当前非 root 且未找到 sudo"; return 1; }
        # 密码只从 stdin 读一次: 交互终端静默提示, 管道/重定向按行读
        if [ -t 0 ]; then
            read -r -s -p "[sudo] password for $USER: " SUDO_PASS
            echo >&2
        else
            IFS= read -r SUDO_PASS || true
        fi
        [ -n "$SUDO_PASS" ] || { log_err "未提供 sudo 密码 (echo '<密码>' | $0 install 或 < 密码文件)"; return 1; }
    fi

    # run_sudo: root 直接执行; 非 root 用 here-string 喂密码给 sudo -S (不进 argv)
    run_sudo() {
        if [ "$(id -u)" = "0" ]; then
            "$@"
        else
            sudo -S -p '' "$@" <<< "$SUDO_PASS"
        fi
    }

    log_info "将安装: $(echo "$missing" | tr '\n' ' ')"
    run_sudo apt-get update
    # shellcheck disable=SC2086 (包名来自本脚本清单, 无空格)
    run_sudo apt-get install -y $missing
    log_ok "依赖安装完成"
    advisory_checks
}

case "${1:-check}" in
    check|""|-h|--help)
        cmd_check
        ;;
    install)
        cmd_install
        ;;
    *)
        echo "用法: $0 {check|install}" >&2
        echo "  check    检测缺失依赖 (缺失包名输出到 stdout)" >&2
        echo "  install  用 sudo 安装缺失依赖 (密码从 stdin 读)" >&2
        exit 1
        ;;
esac
