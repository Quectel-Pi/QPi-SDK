#!/usr/bin/env bash
set -uo pipefail

C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_DIM=''; C_NC=''
setup_color() {
    if [ -t 1 ] && [ "${QPI_NO_COLOR:-0}" != "1" ]; then
        C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YLW='\033[1;33m'
        C_BLU='\033[0;36m'; C_DIM='\033[2m';  C_NC='\033[0m'
    fi
}
info()  { echo -e "${C_BLU}[INFO]${C_NC}  $*"; }
ok()    { echo -e "${C_GRN}[ OK ]${C_NC}  $*"; }
warn()  { echo -e "${C_YLW}[WARN]${C_NC}  $*"; }
err()   { echo -e "${C_RED}[FAIL]${C_NC}  $*"; }
dim()   { echo -e "${C_DIM}$*${C_NC}"; }
hr()    { echo "--------------------------------------------------------------------"; }

PLATFORM=""
DISTRO=""
DISTRO_VER=""
DISTRO_PRETTY=""
IS_ROOT=0
[ "$(id -u 2>/dev/null)" = "0" ] && IS_ROOT=1

detect_platform() {
    local forced="${QPI_SETUP_PLATFORM:-auto}"
    if [ "$forced" != "auto" ]; then
        PLATFORM="$forced"
    else
        case "$(uname -s 2>/dev/null)" in
            Darwin)                PLATFORM="macos" ;;
            MINGW*|MSYS*|CYGWIN*)  PLATFORM="msys"  ;;
            Linux)
                if grep -qi "microsoft" /proc/version 2>/dev/null \
                   || grep -qi "microsoft" /proc/sys/kernel/osrelease 2>/dev/null \
                   || [ -n "${WSL_DISTRO_NAME:-}" ]; then
                    PLATFORM="wsl"
                else
                    PLATFORM="linux"
                fi
                ;;
            *)                     PLATFORM="unknown" ;;
        esac
    fi

    local forced_d="${QPI_SETUP_DISTRO:-auto}"
    if [ "$forced_d" != "auto" ]; then
        DISTRO="$forced_d"
    elif [ -r /etc/os-release ]; then
        . /etc/os-release
        DISTRO_PRETTY="${PRETTY_NAME:-unknown}"
        DISTRO_VER="${VERSION_ID:-}"
        local id="${ID:-}" like="${ID_LIKE:-}"
        case " $id $like " in
            *" ubuntu "*)                      DISTRO="ubuntu" ;;
            *" debian "*)                      DISTRO="debian" ;;
            *" fedora "*|*" rhel "*|*" centos "*) DISTRO="fedora" ;;
            *" arch "*)                        DISTRO="arch" ;;
            *)                                 DISTRO="$id" ;;
        esac
    else
        DISTRO="unknown"
    fi

    case "$PLATFORM" in
        macos)   [ -z "$DISTRO_PRETTY" ] && DISTRO_PRETTY="macOS $(sw_vers -productVersion 2>/dev/null)" ;;
        msys)    DISTRO_PRETTY="Windows (MSYS/MinGW/Cygwin)" ;;
        unknown) DISTRO_PRETTY="未知系统" ;;
    esac
    [ -z "$DISTRO_PRETTY" ] && DISTRO_PRETTY="${DISTRO:-unknown} ${DISTRO_VER}"
}

pkgs_apt_base="build-essential make bc bison flex libssl-dev libelf-dev libncurses-dev cpio kmod xz-utils zstd lz4 file python3 python3-pefile git rsync ca-certificates curl wget unzip"
pkgs_apt_pack="btrfs-progs fakeroot mtools dosfstools device-tree-compiler"
pkgs_apt_app="qemu-user-static binfmt-support"
pkgs_apt_flash="usbutils libusb-1.0-0 libxml2-dev libzip-dev"

pkgs_dnf_base="gcc gcc-c++ make bc bison flex openssl-devel elfutils-libelf-devel ncurses-devel cpio kmod xz zstd lz4 file python3 python3-pefile git rsync ca-certificates curl wget unzip"
pkgs_dnf_pack="btrfs-progs fakeroot mtools dosfstools dtc"
pkgs_dnf_app="qemu-user-static"
pkgs_dnf_flash="usbutils libusb1 libxml2 libzip"

pkgs_pac_base="base-devel bc bison flex openssl libelf ncurses cpio kmod xz zstd lz4 file python python-pefile git rsync ca-certificates curl wget unzip"
pkgs_pac_pack="btrfs-progs fakeroot mtools dosfstools dtc"
pkgs_pac_app="qemu-user-static-binfmt"
pkgs_pac_flash="usbutils libusb libxml2 libzip"

gate_platform() {
    case "$PLATFORM" in
        macos)
            err "macOS 无法原生编译本 SDK。"
            hr
            echo "原因 (硬性限制, 非缺依赖):"
            echo "  1. 仓库自带工具是 Linux x86-64 ELF, macOS 无法执行:"
            echo "       tools/qdl  ELF 64-bit LSB, interpreter /lib64/ld-linux-x86-64.so.2"
            echo "       tools/adb  ELF 64-bit LSB, for GNU/Linux 3.2.0"
            echo "  2. 打包链路依赖 Linux 专属能力, macOS 均不具备:"
            echo "       mount -o loop            (scripts/pack-system.sh, build-rootfs.sh)"
            echo "       btrfs / mkfs.btrfs / btrfstune"
            echo "       fakeroot"
            echo "       51-android.rules udev 规则 (macOS 无 udev)"
            echo "  3. BSD userland (无 GNU sed/find --printf 等), 脚本按 Linux 语义编写。"
            hr
            echo "可行方案 (任选):"
            echo "  - 用 Linux 物理机 / 虚拟机 (推荐 Ubuntu 22.04, 见下)"
            echo "  - 在 macOS 上跑 Linux 虚拟机 (UTM / VMware Fusion / Lima), 系统用 Ubuntu 22.04"
            echo "  - 仅做应用开发 (buildapp) 可在 macOS 用 Docker + linux/amd64 容器"
            dim "  注意: 交叉编译产物仅依赖 prebuilds/sysroot, 但 SDK 的打包/烧录脚本仍须 Linux。"
            return 1
            ;;
        msys)
            err "当前是 Windows 下的 MSYS/MinGW/Cygwin 环境, 不支持本 SDK。"
            hr
            echo "原因:"
            echo "  1. 脚本硬依赖 Linux 能力: mount -o loop / btrfs / fakeroot / udev / sudo"
            echo "  2. tools/qdl 与 tools/adb 是 Linux x86-64 ELF, 在此环境无法执行"
            echo "  3. 仓库内核树含 Windows 保留设备名路径, NTFS 上无法 checkout:"
            echo "       kernel/drivers/gpu/drm/nouveau/nvkm/subdev/i2c/aux.c   ('aux' 为保留名)"
            hr
            echo "请在 WSL2 内运行 (Windows 11 / 10 21H2+):"
            echo "  wsl --install -d Ubuntu-22.04          # 首次安装"
            echo "  wsl -d Ubuntu-22.04                     # 进入后:"
            echo "  cd /mnt/c/.../QPi-SDK && ./tools/setup-env.sh"
            dim "  提示: 需先在 BIOS 开启虚拟化, 且 bcdedit hypervisorlaunchtype 不能为 Off。"
            return 1
            ;;
        wsl|linux) return 0 ;;
        *)
            err "无法识别的平台: ${PLATFORM}"
            return 1
            ;;
    esac
}

SUDO=""
setup_sudo() {
    if [ "$IS_ROOT" = "1" ]; then
        SUDO=""
    elif command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        SUDO="__NO_SUDO__"
    fi
}

run() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "    ${C_DIM}\$ $*${C_NC}"
        return 0
    fi
    "$@"
}

install_deps() {
    hr
    info "安装宿主依赖 (平台: ${PLATFORM} / ${DISTRO} ${DISTRO_VER})"
    hr

    case "$DISTRO" in
        ubuntu|debian)
            if [ "$SUDO" = "__NO_SUDO__" ]; then
                err "缺少 sudo, 且当前非 root; 请以 root 执行或安装 sudo。"
                return 1
            fi
            if [ "${DRY_RUN:-0}" != "1" ]; then
                info "apt-get update ..."
                $SUDO apt-get update -qq || { err "apt-get update 失败"; return 1; }
            fi
            local pkgs="$pkgs_apt_base $pkgs_apt_pack $pkgs_apt_app $pkgs_apt_flash"
            info "apt-get install (base+pack+app+flash, 共 $(echo $pkgs | wc -w) 个包) ..."
            run $SUDO apt-get install -y -qq $pkgs
            ;;
        fedora)
            if [ "$SUDO" = "__NO_SUDO__" ]; then err "缺少 sudo"; return 1; fi
            local pkgs="$pkgs_dnf_base $pkgs_dnf_pack $pkgs_dnf_app $pkgs_dnf_flash"
            info "dnf install (base+pack+app+flash) ..."
            run $SUDO dnf install -y $pkgs
            ;;
        arch)
            if [ "$SUDO" = "__NO_SUDO__" ]; then err "缺少 sudo"; return 1; fi
            local pkgs="$pkgs_pac_base $pkgs_pac_pack $pkgs_pac_app $pkgs_pac_flash"
            info "pacman -S --needed (base+pack+app+flash) ..."
            run $SUDO pacman -S --needed --noconfirm $pkgs
            ;;
        *)
            err "不支持的发行版: ${DISTRO:-unknown}"
            echo "请手动安装: rsync btrfs-progs fakeroot mtools dosfstools device-tree-compiler"
            echo "            build-essential bc bison flex libssl-dev libelf-dev libncurses-dev"
            echo "            cpio kmod xz-utils zstd lz4 python3 git qemu-user-static"
            return 1
            ;;
    esac
    return 0
}

post_setup_platform() {
    [ "$PLATFORM" = "wsl" ] || return 0
    hr
    info "WSL2 专项配置"
    hr

    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "    ${C_DIM}\$ modprobe btrfs${C_NC}"
    elif ! grep -qw btrfs /proc/filesystems 2>/dev/null; then
        if $SUDO modprobe btrfs 2>/dev/null; then
            ok "已加载 btrfs 内核模块"
        else
            warn "modprobe btrfs 失败 —— 打包 system.img 会失败"
            dim "   WSL2 内核 config: CONFIG_BTRFS_FS=m (需模块加载)"
        fi
    else
        ok "btrfs 已在内核中可用"
    fi
    if [ "${DRY_RUN:-0}" != "1" ] && [ -d /etc/modules-load.d ]; then
        echo "btrfs" | $SUDO tee /etc/modules-load.d/simple-h1.conf >/dev/null 2>&1 \
            && ok "已写入 /etc/modules-load.d/simple-h1.conf (开机自动加载 btrfs)"
    fi

    if [ -e /dev/loop-control ]; then
        ok "loop 设备可用 (/dev/loop-control)"
    else
        warn "未找到 /dev/loop-control —— repack 的 mount -o loop 可能失败"
    fi

    if mount 2>/dev/null | grep -q binfmt_misc; then
        ok "binfmt_misc 已挂载"
    elif [ "${DRY_RUN:-0}" != "1" ]; then
        $SUDO mkdir -p /proc/sys/fs/binfmt_misc 2>/dev/null
        $SUDO mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null \
            && ok "binfmt_misc 已挂载" \
            || warn "binfmt_misc 未挂载 —— qemu wrapper 工具链不可用 (可改用 QPI_CROSS_COMPILE 指定工具链)"
    fi

    echo
    dim "WSL2 使用提示:"
    dim "  · 内存: WSL2 默认取宿主 50%。编内核建议在 %UserProfile%\\.wslconfig 设 memory=24GB"
    dim "  · 烧录: WSL2 默认不做 USB 直通。装备用 usbipd-win 把 Qualcomm 9008 转发进来:"
    dim "      usbipd list ; usbipd bind --busid <id> ; usbipd attach --wsl --busid <id>"
    dim "    或在 Windows 侧用原生 qdl 烧录 (编译/打包仍在 WSL 内完成)。"
    dim "  · 源码请放在 WSL 原生文件系统 (~/QPi-SDK) 而非 /mnt/c, 否则内核编译极慢。"
}

CHECK_FAIL=0

need_cmd() {
    if command -v "$1" >/dev/null 2>&1; then
        ok "$1  ${C_DIM}($(command -v "$1"))${C_NC}"
    else
        err "$1 缺失  ${C_DIM}— $2${C_NC}"
        CHECK_FAIL=1
    fi
}

need_any_cmd() {
    local desc="$2"; shift 2
    local c
    for c in "$@"; do
        if command -v "$c" >/dev/null 2>&1; then
            ok "$c  ${C_DIM}($(command -v "$c"))${C_NC}"
            return 0
        fi
    done
    err "$(echo "$@" | tr ' ' '/') 均缺失  ${C_DIM}— $desc${C_NC}"
    CHECK_FAIL=1
}

need_header() {
    if [ -e "$1" ]; then ok "头文件 $1"; else err "头文件 $1 缺失  ${C_DIM}— $2${C_NC}"; CHECK_FAIL=1; fi
}

check_deps() {
    hr
    info "依赖复核"
    hr
    echo "${C_DIM}-- 内核编译基础 --${C_NC}"
    need_cmd make  "内核编译核心"
    need_any_cmd "C 编译器 (内核编译必需)" gcc cc
    need_cmd bc    "内核 Kconfig 计算"
    need_cmd bison "内核 kconfig 解析"
    need_cmd flex  "内核 kconfig 词法"
    need_cmd python3 "tools/uki/ukify 打包 UKI"
    if python3 -c "import pefile" >/dev/null 2>&1; then
        ok "python3 pefile 模块  ${C_DIM}(tools/uki/ukify 打包 UKI 必需)${C_NC}"
    else
        err "python3 pefile 模块缺失  ${C_DIM}— python3-pefile${C_NC}"
        dim "  tools/uki/ukify 第 52 行 import pefile, 缺失时 pack-efi.sh 立即失败:"
        dim "  ModuleNotFoundError: No module named 'pefile'"
        CHECK_FAIL=1
    fi
    echo "${C_DIM}-- 固件打包 --${C_NC}"
    need_cmd btrfs   "system.img (mkfs.btrfs/btrfstune/btrfs restore)"
    need_cmd rsync   "overlay 合成 (build-rootfs.sh)"
    need_any_cmd "免 root 更新 FAT 分区 (efi.bin/dtb.bin)" mcopy mtools
    need_any_cmd "设备树 dtbo 合并 (qcm6490-*.dtbo)" fdtoverlay dtc
    need_cmd fakeroot "repack 保属主 (缺则属主不保真)"
    echo "${C_DIM}-- 应用交叉编译 --${C_NC}"
    need_cmd depmod "内核模块 depmod"
    if [ -x "${SDK_ROOT:-.}/toolchains/qcom-rootfs-toolchain/bin/aarch64-linux-gnu-gcc" ]; then
        ok "qcom-rootfs-toolchain 存在 (qemu wrapper)"
    else
        warn "toolchains/qcom-rootfs-toolchain 缺失 (仓库应自带, 请检查)"
    fi
    if [ -d "${SDK_ROOT:-.}/prebuilds/sysroot" ]; then
        ok "prebuilds/sysroot 存在"
    else
        warn "prebuilds/sysroot 缺失 — 厂商未分发, buildapp 将退回宿主 aarch64-linux-gnu-gcc"
    fi
    echo "${C_DIM}-- 内核头文件/库 --${C_NC}"
    need_header /usr/include/openssl/ssl.h "libssl-dev (内核 sign-file/模块签名)"
    for h in /usr/include/libelf.h /usr/include/elfutils/libelf.h /usr/include/gelf.h; do
        [ -e "$h" ] && { ok "头文件 $h"; break; }
    done
    [ -e /usr/include/libelf.h ] || [ -e /usr/include/elfutils/libelf.h ] || [ -e /usr/include/gelf.h ] \
        || { err "libelf 头文件缺失  ${C_DIM}— libelf-dev (内核编译必需)${C_NC}"; CHECK_FAIL=1; }
    for h in /usr/include/ncurses.h /usr/include/ncursesw/ncurses.h; do
        [ -e "$h" ] && { ok "头文件 $h"; break; }
    done
    [ -e /usr/include/ncurses.h ] || [ -e /usr/include/ncursesw/ncurses.h ] \
        || { err "ncurses 头文件缺失  ${C_DIM}— libncurses-dev (menuconfig)${C_NC}"; CHECK_FAIL=1; }
    echo "${C_DIM}-- 烧录 (可选) --${C_NC}"
    need_cmd lsusb "flash.sh 识别 9008 EDL 设备"
    if [ -x "${SDK_ROOT:-.}/tools/qdl" ]; then
        file "${SDK_ROOT:-.}/tools/qdl" 2>/dev/null | grep -q ELF && ok "tools/qdl (Linux x86-64 ELF)"
    fi
    return 0
}

check_versions() {
    hr
    info "版本校验"
    hr

    if [ "$DISTRO" = "ubuntu" ]; then
        if [ "$DISTRO_VER" = "22.04" ]; then
            ok "Ubuntu 22.04 (设计基准版本)"
        else
            warn "Ubuntu ${DISTRO_VER}, 基准为 22.04 —— 注意下列 btrfs-progs 行为差异"
        fi
    fi

    if command -v btrfs >/dev/null 2>&1; then
        local bv bmaj
        bv="$(btrfs --version 2>/dev/null | awk '{print $NF}')"
        bv="${bv#v}"
        bmaj="${bv%%.*}"
        case "$bmaj" in
            ''|*[!0-9]*) warn "无法解析 btrfs-progs 版本: '${bv}'" ;;
            5)  ok "btrfs-progs ${bv}  ${C_DIM}(Ubuntu 22.04 为 5.16.x, build-rootfs.sh 以此为基准)${C_NC}" ;;
            *)  warn "btrfs-progs ${bv} (非 5.x)"
                dim "  tools/build-rootfs.sh 注释: 5.16 对大目录会忽略 -b 自动扩展,"
                dim "  产出 17.9GB 超 GPT system 分区 → 烧录后内核挂 rootfs 失败重启。"
                dim "  该脚本已避开 --rootdir 路径; 换用 6.x 请务必校验产物 system.img 大小。"
                ;;
        esac
    fi

    local avail_gb
    avail_gb="$(df -BG --output=avail "${SDK_ROOT:-.}" 2>/dev/null | tail -1 | tr -dc '0-9')"
    if [ -n "$avail_gb" ]; then
        if [ "$avail_gb" -ge 30 ]; then
            ok "可用磁盘 ${avail_gb}GB"
        else
            warn "可用磁盘仅 ${avail_gb}GB —— 内核编译+镜像打包建议 >=30GB"
        fi
    fi

    if command -v "${CROSS_COMPILE:-aarch64-qcom-linux-}gcc" >/dev/null 2>&1; then
        ok "内核工具链可用: ${CROSS_COMPILE:-aarch64-qcom-linux-}gcc"
    else
        warn "内核工具链 aarch64-qcom-linux-gcc 不可用"
        dim "  toolchains/gcc/ 为厂商独立分发 (不在仓库内), 请向 Quectel 获取后放置。"
        dim "  缺失时 buildkernel 会在自检阶段退出。"
    fi
}

next_steps() {
    hr
    if [ "$CHECK_FAIL" = "0" ]; then
        ok "宿主环境就绪 —— 可以开始编译"
    else
        err "仍有缺失项 (见上), 请先补齐"
    fi
    hr
    echo "后续步骤:"
    echo "  cd <SDK_ROOT>"
    echo "  source build.sh          # 注册 build* 命令, 导出交叉编译变量"
    echo "  buildcheck               # SDK 自带环境检查"
    echo "  buildkernel              # 编译内核  (Image + dtb + modules)"
    echo "  buildall                 # 完整打包  (内核 + efi.bin + dtb.bin + system.img)"
    echo "  SKIP_KERNEL=1 buildall   # 仅应用层/overlay 改动时 (快)"
    dim "  提醒: 厂商独立分发资源不在仓库内, 缺任一项都无法产出可烧录固件:"
    dim "        toolchains/gcc/           内核交叉工具链 aarch64-qcom-linux 13.4"
    dim "        prebuilds/system.img      原始根文件系统 (base_rootfs 提取源)"
    dim "        prebuilds/efi.bin,dtb.bin 启动分区底包"
}

usage() {
    cat <<'EOF'
Quectel PI H1 (QCS6490) simple-h1 SDK 宿主环境部署

自动识别运行平台 (WSL2 / Ubuntu / Debian / Fedora / Arch / macOS / MSYS),
并安装编译内核、打包固件、交叉编译应用、烧录所需的全部宿主依赖。

用法:
  ./tools/setup-env.sh              # 检测 + 安装 (默认)
  ./tools/setup-env.sh check        # 只检测, 不安装 (CI/只读环境友好)
  ./tools/setup-env.sh install      # 强制安装
  ./tools/setup-env.sh -h           # 帮助

选项:
  --dry-run        只打印将要执行的安装命令, 不真正执行
  --no-color       关闭彩色输出

用于测试/强制覆盖环境变量:
  QPI_SETUP_PLATFORM=auto|wsl|linux|macos|msys
  QPI_SETUP_DISTRO=auto|ubuntu|debian|fedora|arch

退出码: 0 = 环境就绪; 1 = 平台不支持或缺依赖; 2 = 用法错误
EOF
}

DRY_RUN=0
ACTION="auto"
while [ $# -gt 0 ]; do
    case "$1" in
        check|install) ACTION="$1" ;;
        --dry-run)     DRY_RUN=1 ;;
        --no-color)    QPI_NO_COLOR=1 ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

SDK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SDK_ROOT

setup_color
detect_platform
setup_sudo

echo "============================================================"
echo "  Quectel PI H1 (QCS6490) simple-h1 SDK — 宿主环境部署"
echo "============================================================"
echo "  平台:     ${PLATFORM}"
echo "  发行版:   ${DISTRO_PRETTY}"
echo "  发行版ID: ${DISTRO} ${DISTRO_VER}"
echo "  权限:     $([ "$IS_ROOT" = "1" ] && echo root || echo "非 root (sudo: ${SUDO:-none})")"
echo "  模式:     ${ACTION}$([ "$DRY_RUN" = "1" ] && echo " (dry-run)")"
echo "============================================================"

gate_platform || exit 1

[ "$ACTION" = "check" ] || install_deps || { err "依赖安装失败"; exit 1; }
post_setup_platform

check_deps
check_versions
next_steps

[ "$CHECK_FAIL" = "0" ] && exit 0 || exit 1
