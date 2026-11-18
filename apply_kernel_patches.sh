#!/usr/bin/env bash

set -euo pipefail

SDK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$SDK_ROOT/kernel/msm-kernel"
PATCH_DIR="$SDK_ROOT/patches"
BASELINE_REV="f278c736182df6de50199aee950bcfc9ad4e9eab"

PATCHES=(
	"0001-sdk-kernel-build-and-config-integration.patch"
	"0002-qualcomm-bengal-scuba-platform-support.patch"
	"0003-m1-l1-display-touch-and-runtime-dt-support.patch"
	"0004-m1-l1-board-and-peripheral-support.patch"
	"0005-realtek-r8152-vendor-driver.patch"
	"0006-kernel-security-and-general-backports.patch"
)

die() {
	echo "ERROR: $*" >&2
	exit 1
}

check_kernel_repository() {
	local actual_root actual_head

	[ -d "$KERNEL_DIR" ] || die "Kernel 目录不存在: $KERNEL_DIR"
	git -C "$KERNEL_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
		die "$KERNEL_DIR 不是 Git 仓库"

	actual_root="$(git -C "$KERNEL_DIR" rev-parse --show-toplevel)"
	actual_root="$(cd "$actual_root" && pwd -P)"
	[ "$actual_root" = "$(cd "$KERNEL_DIR" && pwd -P)" ] ||
		die "$KERNEL_DIR 不是当前 Git 仓库的顶层目录（实际顶层: $actual_root）"

	actual_head="$(git -C "$KERNEL_DIR" rev-parse HEAD)"
	[ "$actual_head" = "$BASELINE_REV" ] ||
		die "CodeLinaro baseline revision 不匹配: expected=$BASELINE_REV actual=$actual_head"
}

check_clean_worktree() {
	local status

	status="$(git -C "$KERNEL_DIR" status --porcelain=v1 --untracked-files=all)"
	[ -z "$status" ] || {
		echo "ERROR: kernel/msm-kernel 工作区不干净，拒绝应用 Patch。" >&2
		echo "请先自行处理以下 tracked/untracked 文件:" >&2
		printf '%s\n' "$status" >&2
		exit 1
	}
}

check_patch_files() {
	local patch

	for patch in "${PATCHES[@]}"; do
		[ -f "$PATCH_DIR/$patch" ] || die "缺少 Patch: $PATCH_DIR/$patch"
	done
}

precheck_patch_sequence() (
	local check_dir patch

	check_dir="$(mktemp -d "${TMPDIR:-/tmp}/dt2-kernel-patch-check.XXXXXX")"
	trap 'rm -rf -- "$check_dir"' EXIT

	git -C "$KERNEL_DIR" archive --format=tar "$BASELINE_REV" |
		tar -xf - -C "$check_dir"

	for patch in "${PATCHES[@]}"; do
		echo "预检查: $patch"
		git -C "$check_dir" apply --check --whitespace=nowarn "$PATCH_DIR/$patch" ||
			die "Patch 顺序预检查失败: $patch"
		git -C "$check_dir" apply --whitespace=nowarn "$PATCH_DIR/$patch" ||
			die "Patch 临时应用失败: $patch"
	done

)

apply_patch_sequence() {
	local patch

	for patch in "${PATCHES[@]}"; do
		echo "应用: $patch"
		git -C "$KERNEL_DIR" apply --whitespace=nowarn "$PATCH_DIR/$patch" ||
			die "应用 Patch 失败: $patch"
	done
}

check_kernel_repository
check_clean_worktree
check_patch_files

echo "CodeLinaro baseline revision: $BASELINE_REV"
echo "开始顺序预检查 6 个 Patch..."
precheck_patch_sequence

# 防止预检查期间真实仓库被其他进程或用户改变。
check_kernel_repository
check_clean_worktree

echo "顺序预检查通过，开始应用 Patch..."
apply_patch_sequence

echo
echo "=== Kernel Patch 应用完成 ==="
echo "CodeLinaro baseline revision: $BASELINE_REV"
echo "6 个 Patch 均已成功应用"
echo "kernel/msm-kernel 已准备完成"
echo "下一步可以执行: source build.sh"
