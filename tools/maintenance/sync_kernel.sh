#!/bin/bash

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
[ -f "$ROOT/build.sh" ] && [ -d "$ROOT/tools" ] || {
	echo "ERROR: SDK 根目录校验失败: $ROOT" >&2
	exit 1
}
. "$ROOT/config/platforms.sh"
dt_platform_ensure || { echo "ERROR: 档位未定（见 config/platforms.sh）" >&2; exit 1; }

REPO=$(readlink -m "$ROOT/../repo")
KP="$REPO/src/kernel-5.15/kernel_platform"
KERNEL_DIR="$ROOT/kernel"
[ -d "$KP" ] || { echo "ERROR: 找不到 Kernel 同步源目录: $KP" >&2; exit 1; }
case "$KERNEL_DIR/" in
	"$ROOT"/*) ;;
	*) echo "ERROR: 拒绝同步到 SDK 之外: $KERNEL_DIR" >&2; exit 1 ;;
esac
[ "$(readlink -m "$KP")" != "$(readlink -m "$KERNEL_DIR")" ] || {
	echo "ERROR: Kernel 同步源目录和目标目录不能相同" >&2
	exit 1
}

safe_remove_kernel_paths() {
	local path
	for path in "$@"; do
		case "$path" in
			"$KERNEL_DIR"/*) ;;
			*) echo "ERROR: 拒绝删除 Kernel 目录之外的路径: $path" >&2; return 1 ;;
		esac
	done
	rm -rf -- "$@"
}

mkdir -p "$KERNEL_DIR" "$ROOT/config"
rsync -a --delete \
    --exclude=/common \
    --exclude=/prebuilts/tradefed \
    --exclude=/prebuilts/asuite \
    --exclude=/qcom/proprietary/devicetree \
    --exclude=/msm-kernel/arch/arm64/boot/dts/vendor \
    --exclude=/qcom/proprietary/prebuilt_HY11 \
    --exclude=/qcom/proprietary/prebuilt_HY33 \
    "$KP/" "$KERNEL_DIR/"

safe_remove_kernel_paths "$KERNEL_DIR/prebuilts/jdk" "$KERNEL_DIR/prebuilts/bazel"
safe_remove_kernel_paths "$KERNEL_DIR/prebuilts/clang/host/linux-x86/clang-stable"

safe_remove_kernel_paths "$KERNEL_DIR/prebuilts/ndk-r23/build" "$KERNEL_DIR/prebuilts/ndk-r23/meta" \
       "$KERNEL_DIR/prebuilts/ndk-r23/prebuilds" "$KERNEL_DIR/prebuilts/ndk-r23/python-packages" \
       "$KERNEL_DIR/prebuilts/ndk-r23/shader-tools" "$KERNEL_DIR/prebuilts/ndk-r23/simpleperf" \
       "$KERNEL_DIR/prebuilts/ndk-r23/sources" "$KERNEL_DIR/prebuilts/ndk-r23/wrap.sh"
safe_remove_kernel_paths "$KERNEL_DIR/prebuilts/ndk-r23/toolchains/renderscript"
while IFS= read -r -d '' path; do
	safe_remove_kernel_paths "$path"
done < <(find "$KERNEL_DIR/prebuilts/ndk-r23/toolchains/llvm/prebuilds/linux-x86_64" \
     -mindepth 1 -maxdepth 1 ! -name sysroot -print0)
safe_remove_kernel_paths "$KERNEL_DIR/prebuilts/ndk-r23/toolchains/llvm/prebuilds/linux-x86_64/sysroot/usr/lib/i686-linux-android" \
       "$KERNEL_DIR/prebuilts/ndk-r23/toolchains/llvm/prebuilds/linux-x86_64/sysroot/usr/lib/x86_64-linux-android"

CC="$KERNEL_DIR/prebuilts/clang/host/linux-x86/clang-r450784e"
safe_remove_kernel_paths "$CC/lib64/libclang-cpp.so.14git" "$CC/lib64/liblldb.so.14.0.7git" "$CC/lib64/libclang.so.13"
safe_remove_kernel_paths "$CC/bin/clangd" "$CC/bin/clang-tidy" "$CC/bin/clang-tidy.real" "$CC/bin/clang-check" \
       "$CC/bin/clang-format" "$CC/bin/clang-apply-replacements" "$CC/bin/clang-change-namespace" \
       "$CC/bin/clang-doc" "$CC/bin/clang-include-fixer" "$CC/bin/clang-objc-fuzzer" \
       "$CC/bin/clang-query" "$CC/bin/clang-refactor" "$CC/bin/clang-rename" \
       "$CC/bin/clang-reorder-fields" "$CC/bin/dsymutil" "$CC/bin/git-clang-format" \
       "$CC/bin/modularize" "$CC/bin/pp-trace" "$CC/bin/sancov" "$CC/bin/scan-build" \
       "$CC/bin/scan-build-py" "$CC/bin/scan-view" "$CC/bin/lldb" "$CC/bin/lldb-argdumper" \
       "$CC/bin/lldb-instr" "$CC/bin/lldb-server" "$CC/bin/lldb-vscode"

# 客户工作 config 由 buildenv 从当前 fw 的 boot image 初始化；同步 Kernel
# 源码时不再用内部 dist/.config 覆盖它。
