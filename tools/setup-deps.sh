#!/usr/bin/env bash
# ============================================================================
# setup-deps.sh - M2 SDK 构建依赖检测 / 一键安装
# ============================================================================
# 本 SDK 的构建依赖清单集中维护在本脚本 REQUIRED_TOOLS 数组:
#   - 不同 SDK (M1/M2/H1/L1...) 环境需求不同, 各自维护自己的 setup-deps.sh
#   - 插件 / CI / 用户只需要调用本脚本, 不需要知道装了哪些包
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
  "curl:curl"                              # fetch-base-image.sh 下载资源包
  "unzip:unzip"                            # fetch-base-image.sh 解压
  "7z:p7zip-full"                          # 编译资源包 / sysroot 解压
  "debugfs:e2fsprogs"                      # build-rootfs.sh / build-kernel.sh 写 rootfs
  "dtc:device-tree-compiler"               # 设备树 overlays 编译
  "qemu-aarch64-static:qemu-user-static"   # 应用层交叉编译 (rootfs GCC wrapper)
  "make:make"                              # 内核 / 应用构建
  "gcc:build-essential"                    # 内核 host 工具编译
  "cmake:cmake"                            # CMake 工程应用
  "file:file"                              # 镜像类型识别
  "git:git"                                # 仓库 / 资源获取
)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info() { echo -e "${CYAN}[INFO]${NC} $1" >&2; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1" >&2; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# 输出缺失的 apt 包名 (每行一个, 保持清单顺序)
missing_pkgs() {
    for entry in "${REQUIRED_TOOLS[@]}"; do
        local tool="${entry%%:*}" pkg="${entry#*:}"
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "$pkg"
        fi
    done
}

cmd_check() {
    if ! command -v apt-get >/dev/null 2>&1; then
        log_err "未找到 apt-get, 当前环境不是 Debian/Ubuntu"
        return 1
    fi
    local missing
    missing="$(missing_pkgs)"
    if [ -z "$missing" ]; then
        log_ok "所有构建依赖已齐全"
        return 0
    fi
    log_err "缺少以下构建依赖:"
    echo "$missing" | sed 's/^/    /' >&2
    log_info "安装: ./tools/setup-deps.sh install   (需 sudo 密码, 从 stdin 输入)"
    echo "$missing"
    return 1
}

cmd_install() {
    command -v apt-get >/dev/null 2>&1 || { log_err "未找到 apt-get, 当前环境不是 Debian/Ubuntu"; return 1; }

    local missing
    missing="$(missing_pkgs)"
    if [ -z "$missing" ]; then
        log_ok "所有构建依赖已齐全, 无需安装"
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
