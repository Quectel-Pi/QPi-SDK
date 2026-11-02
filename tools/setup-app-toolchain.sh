#!/usr/bin/env bash
# Debian arm64 工具链只解包进 sysroot；不在宿主安装 arm64 包，不修改底包镜像。
set -euo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSROOT="$(realpath "${QPI_SYSROOT:-$ROOT/prebuilds/sysroot}")"
MODE="${1:-install}"
case "$MODE" in install|--check|--plan) ;; *) echo "用法: bash $0 [install|--check|--plan]" >&2; exit 2 ;; esac
fail() { echo "[ERROR] $*" >&2; exit 1; }
[[ -f "$SYSROOT/var/lib/dpkg/status" ]] || fail "缺少 sysroot 包状态，请先提取 rootfs: $SYSROOT"
WRAPPERS="$ROOT/toolchains/m2-debian-rootfs-toolchain/bin"
WORK="$(mktemp -d /tmp/qpi-app-toolchain.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

check_toolchain() {
    local tool
    for tool in gcc g++ ld as ar; do
        [[ -x "$SYSROOT/usr/bin/aarch64-linux-gnu-$tool" ]] || return 1
    done
    printf '#include <stdio.h>\nint main(void) { puts("ok"); return 0; }\n' > "$WORK/check.c"
    printf '#include <iostream>\nint main() { std::cout << "ok"; }\n' > "$WORK/check.cpp"
    local flags=("--sysroot=$SYSROOT" "-B$SYSROOT/usr/lib/aarch64-linux-gnu"
        "-I$SYSROOT/usr/include" "-I$SYSROOT/usr/include/aarch64-linux-gnu"
        "-L$SYSROOT/usr/lib/aarch64-linux-gnu" "-L$SYSROOT/lib/aarch64-linux-gnu")
    QPI_SYSROOT="$SYSROOT" "$WRAPPERS/aarch64-linux-gnu-gcc" "${flags[@]}" "$WORK/check.c" -o "$WORK/check-c" || return 1
    QPI_SYSROOT="$SYSROOT" "$WRAPPERS/aarch64-linux-gnu-g++" "${flags[@]}" "$WORK/check.cpp" -o "$WORK/check-cxx" || return 1
    file "$WORK/check-c" "$WORK/check-cxx" | grep -c 'ARM aarch64' | grep -qx 2 || return 1
    QPI_SYSROOT="$SYSROOT" "$WRAPPERS/aarch64-linux-gnu-gcc" --version | head -1
    echo "[OK] C/C++ 编译和链接通过 (AArch64)"
}
if [[ "$MODE" == --check ]]; then
    check_toolchain || fail "应用工具链不完整或 QEMU/binfmt 未就绪；运行 bash tools/setup-app-toolchain.sh"
    exit 0
fi
if [[ "$MODE" == install ]] && check_toolchain >"$WORK/check.log" 2>&1; then
    cat "$WORK/check.log"
    exit 0
fi
for tool in apt-get dpkg-deb dpkg-query gpgv file; do
    command -v "$tool" >/dev/null || fail "宿主缺少 $tool，请先运行 tools/setup-deps.sh install"
done
[[ -r /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] &&
    grep -q '^enabled$' /proc/sys/fs/binfmt_misc/qemu-aarch64 ||
    fail "请先安装并启用 qemu-user-static / qemu-aarch64 binfmt"
KEYRING="$SYSROOT/usr/share/keyrings/debian-archive-keyring.gpg"
[[ -r "$KEYRING" ]] || fail "底包缺少 Debian archive keyring，拒绝不验证签名的下载"
MIRROR="${QPI_DEBIAN_MIRROR:-https://deb.debian.org/debian}"
[[ "$MIRROR" == https://* && "$MIRROR" != *[[:space:]]* ]] || fail "QPI_DEBIAN_MIRROR 必须是无空白的 HTTPS URL"
package_version() {
    dpkg-query --admindir="$SYSROOT/var/lib/dpkg" -W -f='${Version}' "$1" 2>/dev/null
}
GCC_VERSION="$(package_version cpp-14-aarch64-linux-gnu)" || fail "底包缺少 cpp-14-aarch64-linux-gnu 元数据，不是支持的 Debian trixie sysroot"
[[ "$GCC_VERSION" == 14.* ]] || fail "不支持的 GCC 基准: $GCC_VERSION"
mkdir -p "$WORK/lists/partial" "$WORK/archives/partial" "$WORK/empty"
cp "$SYSROOT/var/lib/dpkg/status" "$WORK/status"
# 禁止读取宿主 sources、APT hooks、偏好和状态，避免操作宿主系统。
printf 'Dir::Etc::parts "%s";\nDir::Etc::main "%s";\n' "$WORK/empty" "$WORK/no-main" > "$WORK/apt.conf"
printf 'deb [arch=arm64 signed-by=%s] %s trixie main\n' "$KEYRING" "$MIRROR" > "$WORK/sources.list"
export APT_CONFIG="$WORK/apt.conf"
APT=(apt-get -o "Dir::Etc::sourcelist=$WORK/sources.list"
    -o "Dir::Etc::sourceparts=$WORK/empty" -o "Dir::Etc::preferences=$WORK/preferences"
    -o "Dir::Etc::preferencesparts=$WORK/empty" -o "Dir::State::status=$WORK/status"
    -o "Dir::State::lists=$WORK/lists" -o "Dir::State::extended_states=$WORK/extended_states"
    -o "Dir::Cache::archives=$WORK/archives" -o "Dir::Cache::pkgcache=$WORK/pkgcache"
    -o "Dir::Cache::srcpkgcache=$WORK/srcpkgcache" -o APT::Architecture=arm64
    -o 'APT::Architectures::=arm64' -o "APT::Sandbox::User=$(id -un)"
    -o Debug::NoLocking=1 -o Acquire::Languages=none -o Acquire::Retries=3
    -o Acquire::https::Timeout=30 -o Acquire::http::Timeout=30)
PACKAGES=("cpp-14-aarch64-linux-gnu=$GCC_VERSION" "gcc-14=$GCC_VERSION" "g++-14=$GCC_VERSION" 'binutils=2.44-3')
echo "[INFO] 根据 sysroot 已安装包解析依赖，GCC=$GCC_VERSION；下载经 Debian 签名和哈希校验"
"${APT[@]}" update
"${APT[@]}" --download-only --no-install-recommends --no-remove --reinstall -y install "${PACKAGES[@]}" ||
    fail "依赖下载失败。检查网络及 trixie 是否仍提供匹配版本；不会自动升级底包运行库"
# 必须全部检查后才解包。若需要替换底包已有运行库，停止，不能偷偷改变目标 ABI。
shopt -s nullglob
DEBS=("$WORK/archives/"*.deb)
[[ ${#DEBS[@]} -gt 0 ]] || fail "未下载到工具链包"
for deb in "${DEBS[@]}"; do
    name="$(dpkg-deb -f "$deb" Package)"
    version="$(dpkg-deb -f "$deb" Version)"
    arch="$(dpkg-deb -f "$deb" Architecture)"
    [[ "$arch" == arm64 || "$arch" == all ]] || fail "错误架构: $name $arch"
    state="$(dpkg-query --admindir="$SYSROOT/var/lib/dpkg" -W -f='${db:Status-Status}' "$name" 2>/dev/null || true)"
    if [[ "$state" == installed ]]; then
        installed="$(package_version "$name")"
        [[ "$installed" == "$version" ]] || fail "拒绝替换底包已装包 $name: $installed -> $version；请使用匹配底包的软件源"
    fi
    printf '[PLAN] %s %s %s\n' "$name" "$version" "$arch"
done
[[ "$MODE" != --plan ]] || { echo "[OK] 下载/依赖检查通过，未修改 sysroot"; exit 0; }
for deb in "${DEBS[@]}"; do
    dpkg-deb -x "$deb" "$SYSROOT"
done
# Debian gcc/g++ 元包通常创建这些入口；这里直接指向版本化可执行文件。
for tool in gcc g++; do
    target="aarch64-linux-gnu-$tool-14"
    [[ -x "$SYSROOT/usr/bin/$target" ]] || fail "缺少 $target"
    ln -sfn "$target" "$SYSROOT/usr/bin/aarch64-linux-gnu-$tool"
done
# 仅解包，不运行目标系统 maintainer scripts，也不伪造其 dpkg 已安装状态。
check_toolchain || fail "工具链已解包，但编译验证失败，请检查以上错误"