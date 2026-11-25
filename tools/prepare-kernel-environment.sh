#!/usr/bin/env bash

set -euo pipefail

SDK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSET_DIR="$SDK_ROOT/tools/kernel-environment"
LOCK_FILE="$ASSET_DIR/sources.lock"
CACHE_ROOT="${XDG_CACHE_HOME:-${HOME:?HOME is not set}/.cache}/qpi-sdk"
MODE=prepare

if [ "${1:-}" = "--check" ]; then
	MODE=check
	shift
fi
[ "$#" -eq 0 ] || { echo "用法: $0 [--check]" >&2; exit 2; }

CURRENT_COMPONENT=
CURRENT_STAGE=

component_label() {
	case "$1" in
		msm-kernel) echo "CodeLinaro Kernel source" ;;
		kernel-build) echo "AOSP Kernel build framework" ;;
		bazel-common-rules) echo "Bazel common rules" ;;
		gcc-host-sysroot) echo "GCC host sysroot" ;;
		clang) echo "Clang/LLVM toolchain" ;;
		build-tools) echo "AOSP build tools" ;;
		kernel-build-tools) echo "Kernel build tools" ;;
		ndk-r23) echo "Android NDK r23b sysroot" ;;
		ndk-android-mk) echo "NDK integration metadata" ;;
		*) echo "$1" ;;
	esac
}

component_number() {
	local wanted=$1 component number=0
	for component in "${PROGRESS_COMPONENTS[@]}"; do
		number=$((number + 1))
		[ "$component" = "$wanted" ] && { echo "$number"; return 0; }
	done
	return 1
}

component_begin() {
	local component=$1 number
	CURRENT_COMPONENT=$component
	CURRENT_STAGE=Checking
	number=$(component_number "$component") || number='?'
	printf '\n[%s/%s] %s\n' "$number" "${#PROGRESS_COMPONENTS[@]}" "$(component_label "$component")" >&2
	printf '  Source: %s\n' "${URL[$component]}" >&2
	printf '  Status: Checking\n' >&2
}

component_status() {
	local state=$1 detail=${2:-}
	CURRENT_STAGE=$state
	if [ -n "$detail" ]; then
		printf '  Status: %s - %s\n' "$state" "$detail" >&2
	else
		printf '  Status: %s\n' "$state" >&2
	fi
}

component_ready() {
	component_status Ready "${1:-Verified}"
}

retry_hint() {
	echo "  Retry: 修复上述问题后重新执行 buildenv；已完成的缓存会被复用，未知本地内容不会被覆盖。" >&2
}

command_failed() {
	local component=$1 stage=$2 rc=$3 reason=$4 location=${5:-}
	echo "ERROR: $(component_label "$component") failed" >&2
	echo "  Component: $component" >&2
	echo "  Stage: $stage" >&2
	echo "  Source: ${URL[$component]:-n/a}" >&2
	[ -z "$location" ] || echo "  Path: $location" >&2
	echo "  Exit status: $rc" >&2
	echo "  Reason: $reason" >&2
	retry_hint
	return 1
}

die() {
	echo "ERROR: $*" >&2
	if [ -n "$CURRENT_COMPONENT" ]; then
		echo "  Component: $CURRENT_COMPONENT ($(component_label "$CURRENT_COMPONENT"))" >&2
		echo "  Stage: ${CURRENT_STAGE:-unknown}" >&2
		echo "  Source: ${URL[$CURRENT_COMPONENT]:-n/a}" >&2
		retry_hint
	fi
	exit 1
}
note() { printf '  %s\n' "$*"; }

[ -r "$LOCK_FILE" ] || die "锁定文件不存在: $LOCK_FILE"

for tool in git find sort sha256sum readlink stat realpath cut; do
	command -v "$tool" >/dev/null 2>&1 || die "缺少宿主工具: $tool"
done
if [ "$MODE" = prepare ]; then
	for tool in unzip tar mktemp; do
		command -v "$tool" >/dev/null 2>&1 || die "缺少宿主工具: $tool"
	done
	if command -v curl >/dev/null 2>&1; then
		DOWNLOADER=curl
	elif command -v wget >/dev/null 2>&1; then
		DOWNLOADER=wget
	else
		die "缺少下载工具: 需要 curl 或 wget"
	fi
fi

declare -a COMPONENTS=()
declare -a PROGRESS_COMPONENTS=(
	msm-kernel kernel-build bazel-common-rules gcc-host-sysroot clang
	build-tools kernel-build-tools ndk-android-mk ndk-r23
)
declare -A TYPE URL REV SOURCE_PATH DEST SHA TREE REQUIRED POST

while IFS='|' read -r component type url rev source_path dest sha tree required post; do
	case "$component" in ''|'#'*) continue ;; esac
	[ -n "$post" ] || die "sources.lock 字段不完整: $component"
	COMPONENTS+=("$component")
	TYPE["$component"]=$type
	URL["$component"]=$url
	REV["$component"]=$rev
	SOURCE_PATH["$component"]=$source_path
	DEST["$component"]=$dest
	SHA["$component"]=$sha
	TREE["$component"]=$tree
	REQUIRED["$component"]=$required
	POST["$component"]=$post
done < "$LOCK_FILE"

for required_component in msm-kernel kernel-build bazel-common-rules gcc-host-sysroot clang build-tools kernel-build-tools ndk-r23 ndk-android-mk; do
	[ -n "${TYPE[$required_component]:-}" ] || die "sources.lock 缺少组件: $required_component"
done

tree_digest() {
	local root=$1 kind=${2:-generic} path file executable
	[ -d "$root" ] || return 1
	find -P "$root" -mindepth 1 -path "$root/.git" -prune -o \( -type f -o -type l \) -printf '%P\0' |
		LC_ALL=C sort -z |
		while IFS= read -r -d '' path; do
			if [ "$kind" = msm-kernel ]; then
				case "$path" in
				.scmversion|arch/arm64/configs/vendor/bengal_le-consolidate_defconfig) continue ;;
				esac
			fi
			file=$root/$path
			if [ -L "$file" ]; then
				printf 'L\t%s\t%s\n' "$path" "$(readlink "$file")"
			else
				if [ -x "$file" ]; then executable=x; else executable=-; fi
				printf 'F\t%s\t%s\t%s\n' "$executable" "$path" \
					"$(sha256sum "$file" | cut -d' ' -f1)"
			fi
		done |
		sha256sum | cut -d' ' -f1
}

component_digest_ok() {
	local component=$1 actual
	actual=$(tree_digest "$SDK_ROOT/${DEST[$component]}") || return 1
	[ "$actual" = "${TREE[$component]}" ]
}

check_clang_binary() {
	local binary="$SDK_ROOT/${DEST[clang]}/clang-r450784e/bin/clang"
	[ -f "$binary" ] || return 1
	[ "$(sha256sum "$binary" | cut -d' ' -f1)" = "${SHA[clang]}" ]
}

check_msm_kernel() {
	local dir="$SDK_ROOT/${DEST[msm-kernel]}" head status digest actual_root
	[ -d "$dir" ] || return 2
	git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 3
	actual_root=$(git -C "$dir" rev-parse --show-toplevel) || return 3
	[ "$(cd "$dir" && pwd -P)" = "$(realpath "$actual_root")" ] || return 3
	head=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || return 3
	[ "$head" = "${REV[msm-kernel]}" ] || return 4
	status=$(git -C "$dir" status --porcelain=v1 --untracked-files=all)
	if [ -z "$status" ]; then
		return 10
	fi
	digest=$(tree_digest "$dir" msm-kernel) || return 5
	[ "$digest" = "${TREE[msm-kernel]}" ] || return 5
	return 0
}

validate_existing_component() {
	local component
	local destination
	component=$1
	destination="$SDK_ROOT/${DEST[$component]}"
	if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
		note "缺失: ${DEST[$component]}"
		return 2
	fi
	component_digest_ok "$component" || {
		echo "ERROR: ${DEST[$component]} 与 sources.lock 不一致；拒绝覆盖未知修改。" >&2
		return 1
	}
	if [ "$component" = clang ]; then
		check_clang_binary || {
			echo "ERROR: Clang 二进制 SHA256 不匹配。" >&2
			return 1
		}
	fi
	note "复用: ${DEST[$component]}"
}

ensure_cache_dirs() {
	mkdir -p "$CACHE_ROOT/git" "$CACHE_ROOT/downloads" ||
		die "无法创建缓存目录: $CACHE_ROOT（请检查磁盘空间和写权限）"
}

git_cache_path() { printf '%s/git/%s.git\n' "$CACHE_ROOT" "$1"; }

ensure_git_cache() {
	local component=$1 cache temp actual rc
	cache=$(git_cache_path "$component")
	if [ ! -d "$cache" ]; then
		component_status Downloading "Git clone"
		temp=$(mktemp -d "$CACHE_ROOT/git/.${component}.XXXXXX")
		local -a clone_progress=(--progress)
		if git clone "${clone_progress[@]}" --filter=blob:none --no-checkout "${URL[$component]}" "$temp/repo"; then
			:
		else
			rc=$?
			rm -rf -- "$temp"
			command_failed "$component" Downloading "$rc" \
				"Git clone 失败；请检查 DNS、网络、代理和官方仓库可用性" "${URL[$component]}"
			return 1
		fi
		mv "$temp/repo" "$cache"
		rmdir "$temp"
	else
		git -C "$cache" rev-parse --git-dir >/dev/null 2>&1 || {
			command_failed "$component" Checking 1 "Git 缓存损坏或不是 Git 仓库" "$cache"
			return 1
		}
		component_status Checking "using cache $cache"
	fi
	component_status Downloading "fetching locked revision ${REV[$component]}"
	local -a fetch_progress=(--progress)
	if git -C "$cache" fetch "${fetch_progress[@]}" --no-tags --depth=1 origin "${REV[$component]}"; then
		:
	else
		rc=$?
		command_failed "$component" Downloading "$rc" \
			"Git fetch 失败；请检查 DNS、网络、代理、访问权限和锁定 revision 是否仍可获取" "$cache"
		return 1
	fi
	component_status Verifying "revision and cached Git objects"
	actual=$(git -C "$cache" rev-parse FETCH_HEAD)
	[ "$actual" = "${REV[$component]}" ] || die "revision 校验失败: $component"
	# A promisor cache is not complete merely because the commit object exists.
	# Materialize every tree/blob reachable from the locked revision, then repeat
	# the archive with promisor fetching disabled. Only the latter proves that a
	# future stage can be created from this cache without network access.
	echo "校验 Git 缓存完整性: $component" >&2
	git -C "$cache" archive "${REV[$component]}" >/dev/null ||
		die "无法完整获取锁定 revision 的 tree/blob: $component"
	git -C "$cache" -c remote.origin.promisor=false archive "${REV[$component]}" >/dev/null ||
		die "Git 缓存仍缺少锁定 revision 的对象: $component"
	printf '%s\n' "$cache"
}

stage_container() {
	local component
	local destination
	local parent
	component=$1
	destination="$SDK_ROOT/${DEST[$component]}"
	parent=$(dirname "$destination")
	[ -n "$parent" ] && [ "$parent" != / ] || die "拒绝使用不安全的 staging parent: $parent"
	case "$parent" in "$SDK_ROOT"/*) ;; *) die "staging parent 不在 SDK 内: $parent" ;; esac
	mkdir -p "$parent" || {
		echo "ERROR: 无法创建目标父目录: $parent（请检查磁盘空间和写权限）" >&2
		return 1
	}
	mktemp -d "$parent/.qpi-${component}.XXXXXX" || {
		echo "ERROR: 无法创建 staging 目录: $parent（请检查磁盘空间和写权限）" >&2
		return 1
	}
}

install_stage() {
	local component
	local container
	local root
	local destination
	component=$1
	container=$2
	[ -n "$container" ] || die "staging container 为空: $component"
	root="$container/root"
	destination="$SDK_ROOT/${DEST[$component]}"
	[ "$root" != /root ] || die "拒绝使用不安全的 staging root: $root"
	case "$container" in "$SDK_ROOT"/*/.qpi-*) ;; *) die "staging container 不在 SDK 内: $container" ;; esac
	[ ! -e "$destination" ] && [ ! -L "$destination" ] || die "目标在准备期间出现，拒绝覆盖: $destination"
	mv "$root" "$destination" || return 1
	rmdir "$container" || return 1
}

apply_kernel_build_overlay() {
	local root=$1 patch="$ASSET_DIR/kernel-build-sdk.patch"
	[ -f "$patch" ] || die "缺少 kernel/build SDK overlay: $patch"
	git -C "$root" init -q
	git -C "$root" apply --check "$patch" || die "kernel/build SDK overlay 预检查失败"
	git -C "$root" apply "$patch" || die "kernel/build SDK overlay 应用失败"
	rm -rf -- "$root/.git"
	# SDK 发布树不携带仅影响源码仓库本身的 ignore 规则。
	rm -f -- "$root/.gitignore" "$root/abi/.gitignore"
}

kernel_build_compat_links() {
	cat <<'EOF'
_setup_env.sh|kernel/_setup_env.sh
_wrapper_common.sh|kernel/_wrapper_common.sh
abi|kernel/abi
all-variants.sh|kernel/all-variants.sh
android|kernel/android
brunch|kernel/brunch
build.sh|kernel/build.sh
build_abi.sh|kernel/build_abi.sh
build_abl.sh|kernel/build_abl.sh
build_module.sh|kernel/build_module.sh
build_test.sh|kernel/build_test.sh
build_utils.sh|kernel/build_utils.sh
build-tools/path|../kernel/build-tools/path
config.sh|kernel/config.sh
envsetup.sh|kernel/envsetup.sh
multi-switcher.sh|kernel/multi-switcher.sh
static_analysis|kernel/static_analysis
EOF
}

ensure_kernel_build_compat_links() {
	local build_root="$SDK_ROOT/kernel/build"
	local name target path target_path parent actual entry expected=0
	local -a missing=()

	[ -d "$build_root/kernel" ] || {
		echo "ERROR: kernel/build framework 目录不存在: $build_root/kernel" >&2
		return 1
	}

	# Preflight the complete layout before creating anything. Existing files,
	# directories and links with a different target are user/unknown content and
	# must never be overwritten by buildenv.
	while IFS='|' read -r name target; do
		[ -n "$name" ] || continue
		expected=$((expected + 1))
		path="$build_root/$name"
		parent=$(dirname "$path")
		if [ -e "$parent" ] && [ ! -d "$parent" ]; then
			echo "ERROR: kernel/build 兼容链接父路径不是目录: $parent" >&2
			return 1
		fi
		target_path=$(realpath -m -- "$parent/$target")
		[ -e "$target_path" ] || {
			echo "ERROR: kernel/build 兼容链接目标不存在: $target" >&2
			return 1
		}
		if [ -L "$path" ]; then
			actual=$(readlink "$path")
			[ "$actual" = "$target" ] || {
				echo "ERROR: kernel/build 兼容链接目标错误: $name -> $actual（期望 $target）" >&2
				return 1
			}
		elif [ -e "$path" ]; then
			echo "ERROR: kernel/build 兼容链接路径被非软链接占用: $path" >&2
			return 1
		else
			missing+=("$name|$target")
		fi
	done < <(kernel_build_compat_links)

	if [ "${#missing[@]}" -eq 0 ]; then
		note "kernel/build 兼容软链接: $expected/$expected verified"
		return 0
	fi

	if [ "$MODE" = check ]; then
		for entry in "${missing[@]}"; do
			name=${entry%%|*}
			target=${entry#*|}
			echo "ERROR: 缺少 kernel/build 兼容软链接: $name -> $target" >&2
		done
		return 1
	fi

	component_status Installing "kernel/build compatibility symlinks"
	for entry in "${missing[@]}"; do
		name=${entry%%|*}
		target=${entry#*|}
		mkdir -p -- "$(dirname "$build_root/$name")" || {
			echo "ERROR: 无法创建 kernel/build 兼容链接父目录: $(dirname "$build_root/$name")" >&2
			return 1
		}
		ln -s -- "$target" "$build_root/$name" || {
			echo "ERROR: 无法创建 kernel/build 兼容软链接: $name -> $target" >&2
			return 1
		}
	done
	note "kernel/build 兼容软链接: restored ${#missing[@]}, verified $expected/$expected"
}

postprocess_clang() {
	local root
	local cc
	local path
	local manifest
	local -A keep=()
	root=$1
	[ -n "$root" ] && [ "$root" != / ] || die "Clang staging root 不安全: $root"
	cc="$root/clang-r450784e"
	manifest="$ASSET_DIR/clang-retained-paths.txt"
	[ -d "$cc" ] || die "官方 Clang revision 缺少 clang-r450784e"
	[ -f "$manifest" ] || die "缺少 Clang 发布裁剪清单: $manifest"
	cp "$ASSET_DIR/clang-LGPL-2.1.txt" "$cc/LGPL-2.1.txt"
	while IFS= read -r path; do
		[ -n "$path" ] && keep["$path"]=1
	done < "$manifest"
	while IFS= read -r -d '' path; do
		path=${path#"$root/"}
		[ -n "${keep[$path]:-}" ] || rm -f -- "$root/$path"
	done < <(find -P "$root" -mindepth 1 \( -type f -o -type l \) -print0)
	find "$root" -depth -mindepth 1 -type d -empty -delete
	for path in \
		python3/lib/python3.9/venv/scripts/common/Activate.ps1 \
		python3/lib/python3.9/site-packages/pkg_resources/_vendor/pyparsing.py \
		python3/lib/python3.9/site-packages/pip-20.2.3.dist-info/RECORD \
		python3/lib/python3.9/site-packages/setuptools/_vendor/pyparsing.py \
		python3/lib/python3.9/site-packages/setuptools-49.2.1.dist-info/RECORD \
		python3/lib/python3.9/ctypes/macholib/fetch_macholib.bat; do
		[ -f "$cc/$path" ] || die "Clang 后处理目标缺失: $path"
		sed -i 's/\r$//' "$cc/$path"
	done
	# lldb-argdumper 是指向已裁剪 bin/lldb-argdumper 的符号链接。
	# POSIX 符号链接本身没有可移植的 executable mode；只校验其目标，不做 chmod。
	[ "$(readlink "$cc/lib/python3.9/site-packages/lldb/lldb-argdumper")" = '../../../../bin/lldb-argdumper' ] ||
		die "Clang lldb-argdumper 符号链接目标异常"
}

postprocess_gcc() {
	local root
	local root_real
	local manifest
	local path
	local parent_real
	local -A keep=()
	root=$1
	[ -n "$root" ] && [ "$root" != / ] || die "GCC staging root 不安全: $root"
	root_real=$(realpath "$root") || die "无法解析 GCC staging root: $root"
	manifest="$ASSET_DIR/gcc-retained-paths.txt"
	[ -f "$manifest" ] || die "缺少 GCC 发布裁剪清单: $manifest"

	while IFS= read -r path || [ -n "$path" ]; do
		[ -n "$path" ] || die "GCC 发布裁剪清单包含空路径"
		case "$path" in
			/*|.|..|./*|../*|*/./*|*/../*|*/.|*/..)
				die "GCC 发布裁剪清单包含不安全路径: $path"
				;;
		esac
		[ -z "${keep[$path]:-}" ] || die "GCC 发布裁剪清单包含重复路径: $path"
		parent_real=$(realpath -m "$root/$(dirname "$path")") ||
			die "无法解析 GCC 清单路径的父目录: $path"
		case "$parent_real" in
			"$root_real"|"$root_real"/*) ;;
			*) die "GCC 清单路径经符号链接逃出 staging root: $path" ;;
		esac
		[ -f "$root/$path" ] || [ -L "$root/$path" ] ||
			die "官方 GCC revision 缺少发布清单路径: $path"
		keep["$path"]=1
	done < "$manifest"

	while IFS= read -r -d '' path; do
		path=${path#"$root/"}
		[ -n "${keep[$path]:-}" ] || rm -f -- "$root/$path"
	done < <(find -P "$root" -mindepth 1 \( -type f -o -type l \) -print0)
	find -P "$root" -depth -mindepth 1 -type d -empty -delete
}

postprocess_build_tools() {
	local root
	local root_real
	local manifest
	local path
	local parent_real
	local -A keep=()
	root=$1
	[ -n "$root" ] && [ "$root" != / ] || die "build-tools staging root 不安全: $root"
	root_real=$(realpath "$root") || die "无法解析 build-tools staging root: $root"
	manifest="$ASSET_DIR/build-tools-retained-paths.txt"
	[ -f "$manifest" ] || die "缺少 build-tools 发布裁剪清单: $manifest"

	while IFS= read -r path || [ -n "$path" ]; do
		[ -n "$path" ] || die "build-tools 发布裁剪清单包含空路径"
		case "$path" in
			/*|.|..|./*|../*|*/./*|*/../*|*/.|*/..)
				die "build-tools 发布裁剪清单包含不安全路径: $path"
				;;
		esac
		[ -z "${keep[$path]:-}" ] || die "build-tools 发布裁剪清单包含重复路径: $path"
		parent_real=$(realpath -m "$root/$(dirname "$path")") ||
			die "无法解析 build-tools 清单路径的父目录: $path"
		case "$parent_real" in
			"$root_real"|"$root_real"/*) ;;
			*) die "build-tools 清单路径经符号链接逃出 staging root: $path" ;;
		esac
		[ -f "$root/$path" ] || [ -L "$root/$path" ] ||
			die "官方 build-tools revision 缺少发布清单路径: $path"
		keep["$path"]=1
	done < "$manifest"

	while IFS= read -r -d '' path; do
		path=${path#"$root/"}
		[ -n "${keep[$path]:-}" ] || rm -f -- "$root/$path"
	done < <(find -P "$root" -mindepth 1 \( -type f -o -type l \) -print0)
	find -P "$root" -depth -mindepth 1 -type d -empty -delete
}

prepare_git_component() {
	local component=$1 cache container root digest
	if ! cache=$(ensure_git_cache "$component"); then
		die "无法准备 Git 缓存: $component"
	fi
	if ! container=$(stage_container "$component"); then
		die "无法创建 staging container: $component"
	fi
	[ -n "$container" ] || die "staging container 为空: $component"
	root=$container/root
	[ "$root" != /root ] || die "拒绝使用不安全的 staging root: $root"
	mkdir "$root" || die "无法创建 staging root: $root"
	component_status Installing "exporting locked source"
	git -C "$cache" archive "${REV[$component]}" | tar -xf - -C "$root" ||
		die "无法导出锁定 revision: $component"
	case "$component" in
		kernel-build) apply_kernel_build_overlay "$root" ;;
		gcc-host-sysroot) postprocess_gcc "$root" ;;
		clang) postprocess_clang "$root" ;;
		build-tools) postprocess_build_tools "$root" ;;
	esac
	component_status Verifying "final tree digest"
	digest=$(tree_digest "$root")
	[ "$digest" = "${TREE[$component]}" ] || {
		rm -rf -- "$container"
		die "$component 最终树校验失败: expected=${TREE[$component]} actual=$digest"
	}
	if [ "$component" = clang ]; then
		[ "$(sha256sum "$root/clang-r450784e/bin/clang" | cut -d' ' -f1)" = "${SHA[clang]}" ] ||
			die "Clang 二进制 SHA256 校验失败"
	fi
	component_status Installing "atomic install to ${DEST[$component]}"
	install_stage "$component" "$container" || die "原子安装失败: $component"
}

ensure_ndk_archive() {
	local archive="$CACHE_ROOT/downloads/android-ndk-r23b-linux.zip" part hash rc
	if [ -f "$archive" ]; then
		component_status Verifying "cached archive $archive"
		hash=$(sha256sum "$archive" | cut -d' ' -f1)
		[ "$hash" = "${SHA[ndk-r23]}" ] || die "缓存中的 NDK archive SHA256 不匹配: $archive"
		printf '%s\n' "$archive"
		return
	fi
	part=$archive.part
	component_status Downloading "Android NDK archive"
	if [ "$DOWNLOADER" = curl ]; then
		local -a curl_progress=(--silent --show-error)
		[ -t 2 ] && curl_progress=(--progress-bar)
		if curl -fL --retry 3 --connect-timeout 30 -C - "${curl_progress[@]}" -o "$part" "${URL[ndk-r23]}"; then
			:
		else
			rc=$?
			command_failed ndk-r23 Downloading "$rc" \
				"HTTP 下载失败；保留 .part 文件以便重试，请检查 DNS、网络、代理、超时或官方源状态" "$part"
			return 1
		fi
	else
		local -a wget_progress=(--no-verbose)
		[ -t 2 ] && wget_progress=(--progress=bar:force:noscroll)
		if wget --timeout=30 --tries=3 -c "${wget_progress[@]}" -O "$part" "${URL[ndk-r23]}"; then
			:
		else
			rc=$?
			command_failed ndk-r23 Downloading "$rc" \
				"HTTP 下载失败；保留 .part 文件以便重试，请检查 DNS、网络、代理、超时或官方源状态" "$part"
			return 1
		fi
	fi
	component_status Verifying "archive SHA256"
	hash=$(sha256sum "$part" | cut -d' ' -f1)
	[ "$hash" = "${SHA[ndk-r23]}" ] || die "NDK archive SHA256 校验失败: expected=${SHA[ndk-r23]} actual=$hash path=$part"
	mv "$part" "$archive"
	printf '%s\n' "$archive"
}

prepare_ndk() {
	local archive supplement_cache container unpacked root digest
	if ! archive=$(ensure_ndk_archive); then
		die "无法准备 NDK archive"
	fi
	supplement_cache=${NDK_ANDROID_MK_CACHE:-}
	[ -n "$supplement_cache" ] || supplement_cache=$(ensure_git_cache ndk-android-mk) ||
		die "无法准备 NDK Android.mk Git 缓存"
	component_status Installing "extracting and trimming NDK sysroot"
	if ! container=$(stage_container ndk-r23); then
		die "无法创建 staging container: ndk-r23"
	fi
	[ -n "$container" ] || die "staging container 为空: ndk-r23"
	unzip -q "$archive" -d "$container/unpack" || die "NDK archive 解压失败"
	unpacked=$container/unpack/${SOURCE_PATH[ndk-r23]}
	[ -d "$unpacked" ] || die "NDK archive 内路径不存在: ${SOURCE_PATH[ndk-r23]}"
	root=$container/root
	mv "$unpacked" "$root"
	rm -rf -- "$container/unpack"
	rm -rf -- "$root/build" "$root/meta" "$root/prebuilt" "$root/python-packages" \
		"$root/shader-tools" "$root/simpleperf" "$root/sources" "$root/wrap.sh" \
		"$root/toolchains/renderscript"
	find "$root/toolchains/llvm/prebuilt/linux-x86_64" -mindepth 1 -maxdepth 1 \
		! -name sysroot -exec rm -rf -- {} +
	rm -rf -- "$root/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/i686-linux-android" \
		"$root/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/x86_64-linux-android"
	git -C "$supplement_cache" show "${REV[ndk-android-mk]}:${SOURCE_PATH[ndk-android-mk]}" > "$root/Android.mk"
	[ "$(sha256sum "$root/Android.mk" | cut -d' ' -f1)" = "${SHA[ndk-android-mk]}" ] ||
		die "NDK Android.mk SHA256 校验失败"
	component_status Verifying "final NDK tree digest"
	digest=$(tree_digest "$root")
	[ "$digest" = "${TREE[ndk-r23]}" ] || {
		rm -rf -- "$container"
		die "NDK 最终树校验失败: expected=${TREE[ndk-r23]} actual=$digest"
	}
	component_status Installing "atomic install to ${DEST[ndk-r23]}"
	install_stage ndk-r23 "$container" || die "原子安装失败: ndk-r23"
}

prepare_msm_kernel_missing() {
	local cache container root wrapper digest
	if ! cache=$(ensure_git_cache msm-kernel); then
		die "无法准备 Git 缓存: msm-kernel"
	fi
	component_status Installing "exporting source and applying 6 Patch series"
	if ! container=$(stage_container msm-kernel); then
		die "无法创建 staging container: msm-kernel"
	fi
	[ -n "$container" ] || die "staging container 为空: msm-kernel"
	root=$container/root
	[ "$root" != /root ] || die "拒绝使用不安全的 staging root: $root"
	mkdir "$root" || die "无法创建 msm-kernel staging root"
	cp -a "$cache/." "$root/" || die "无法从完整缓存复制 msm-kernel staging repository"
	git -C "$root" config --unset-all remote.origin.promisor 2>/dev/null || true
	git -C "$root" config --unset-all remote.origin.partialclonefilter 2>/dev/null || true
	git -C "$root" config --unset-all extensions.partialClone 2>/dev/null || true
	git -C "$root" remote set-url origin "${URL[msm-kernel]}" || die "无法设置 msm-kernel 官方 remote"
	git -C "$root" checkout --detach "${REV[msm-kernel]}" >/dev/null || die "无法 checkout msm-kernel 锁定 revision"
	[ "$(git -C "$root" rev-parse HEAD)" = "${REV[msm-kernel]}" ] || die "msm-kernel staging HEAD 校验失败"
	[ -z "$(git -C "$root" status --porcelain=v1 --untracked-files=all)" ] || die "msm-kernel staging baseline 不干净"
	GIT_TERMINAL_PROMPT=0 git -C "$root" -c remote.origin.url=/nonexistent \
		archive "${REV[msm-kernel]}" >/dev/null || die "msm-kernel staging 离线完整性校验失败"
	wrapper=$container/sdk
	mkdir -p "$wrapper/kernel"
	ln -s "$SDK_ROOT/patches" "$wrapper/patches"
	ln -s "$root" "$wrapper/kernel/msm-kernel"
	cp "$SDK_ROOT/apply_kernel_patches.sh" "$wrapper/apply_kernel_patches.sh"
	"$wrapper/apply_kernel_patches.sh"
	component_status Verifying "6 Patch final tree digest"
	digest=$(tree_digest "$root" msm-kernel)
	[ "$digest" = "${TREE[msm-kernel]}" ] || {
		rm -rf -- "$container"
		die "msm-kernel 6 Patch 最终树校验失败"
	}
	rm -rf -- "$wrapper"
	component_status Installing "atomic install to ${DEST[msm-kernel]}"
	install_stage msm-kernel "$container" || die "原子安装失败: msm-kernel"
}

prepare_or_check_msm_kernel() {
	local rc=0
	check_msm_kernel || rc=$?
	case "$rc" in
		0) note "复用: ${DEST[msm-kernel]}（固定 baseline + 正确的6 Patch状态）" ;;
		2)
			if [ "$MODE" = check ]; then
				note "缺失: ${DEST[msm-kernel]}"
				component_status Checking "Missing (check mode does not download)"
				return 1
			fi
			prepare_msm_kernel_missing
			note "已准备: ${DEST[msm-kernel]}"
			;;
		10)
			if [ "$MODE" = check ]; then
				note "未就绪: ${DEST[msm-kernel]} 是干净 baseline，尚未应用6个Patch"
				return 1
			fi
			"$SDK_ROOT/apply_kernel_patches.sh"
			check_msm_kernel || die "应用6个Patch后状态校验失败"
			note "已在干净 baseline 上应用6个Patch"
			;;
		3) die "${DEST[msm-kernel]} 不是独立的 Git 仓库" ;;
		4) die "${DEST[msm-kernel]} HEAD 不是锁定 baseline ${REV[msm-kernel]}" ;;
		*) die "${DEST[msm-kernel]} 是半Patch状态或含Patch之外的未知修改；拒绝覆盖" ;;
	esac
}

main() {
	local component failures=0 rc
	local NDK_ANDROID_MK_CACHE=
	echo "Kernel 环境准备模式: $MODE"
	echo "锁定文件: $LOCK_FILE"
	if [ "$MODE" = prepare ]; then
		ensure_cache_dirs
		echo "外部缓存: $CACHE_ROOT"
	fi

	component_begin msm-kernel
	if prepare_or_check_msm_kernel; then
		component_ready "Verified"
	else
		failures=1
	fi

	for component in kernel-build bazel-common-rules gcc-host-sysroot clang build-tools kernel-build-tools; do
		component_begin "$component"
		rc=0
		validate_existing_component "$component" || rc=$?
		case "$rc" in
			0)
				if [ "$component" = kernel-build ]; then
					if ensure_kernel_build_compat_links; then
						component_ready "Already available and verified"
					elif [ "$MODE" = check ]; then
						component_status Checking "Compatibility symlinks missing or invalid"
						failures=1
					else
						die "kernel/build 兼容软链接准备失败"
					fi
				else
					component_ready "Already available and verified"
				fi
				;;
			1)
				command_failed "$component" Checking 1 \
					"已有目标与 sources.lock 不一致；拒绝覆盖未知修改" "$SDK_ROOT/${DEST[$component]}"
				exit 1
				;;
			2)
				if [ "$MODE" = check ]; then
					component_status Checking "Missing (check mode does not download)"
					failures=1
				else
					component_status Downloading
					prepare_git_component "$component"
					if [ "$component" = kernel-build ]; then
						ensure_kernel_build_compat_links ||
							die "kernel/build 兼容软链接准备失败"
					fi
					note "已准备: ${DEST[$component]}"
					component_ready "Downloaded, verified and installed"
				fi
				;;
		esac
	done

	component_begin ndk-android-mk
	if [ -f "$SDK_ROOT/${DEST[ndk-android-mk]}" ] &&
		[ "$(sha256sum "$SDK_ROOT/${DEST[ndk-android-mk]}" | cut -d' ' -f1)" = "${SHA[ndk-android-mk]}" ]; then
		component_ready "Already available with NDK; SHA256 verified"
	elif [ "$MODE" = check ]; then
		component_status Checking "Missing or SHA256 mismatch (check mode does not download)"
		failures=1
	elif [ -e "$SDK_ROOT/${DEST[ndk-android-mk]}" ] || [ -L "$SDK_ROOT/${DEST[ndk-android-mk]}" ]; then
		command_failed ndk-android-mk Checking 1 \
			"已有 NDK integration metadata 的 SHA256 不匹配；拒绝覆盖未知内容" \
			"$SDK_ROOT/${DEST[ndk-android-mk]}"
		exit 1
	else
		NDK_ANDROID_MK_CACHE=$(ensure_git_cache ndk-android-mk) ||
			die "无法准备 NDK Android.mk Git 缓存"
		component_ready "Locked source cached; installed atomically with NDK"
	fi

	component=ndk-r23
	component_begin "$component"
	rc=0
	validate_existing_component "$component" || rc=$?
	case "$rc" in
		0) component_ready "Already available and verified" ;;
		1)
			command_failed "$component" Checking 1 \
				"已有目标与 sources.lock 不一致；拒绝覆盖未知修改" "$SDK_ROOT/${DEST[$component]}"
			exit 1
			;;
		2)
			if [ "$MODE" = check ]; then
				component_status Checking "Missing (check mode does not download)"
				failures=1
			else
				prepare_ndk
				note "已准备: ${DEST[$component]}"
				component_ready "Downloaded, verified and installed"
			fi
			;;
	esac

	if [ "$failures" -ne 0 ]; then
		echo "ERROR: Kernel 构建环境不完整（--check 未执行任何下载或修改）。" >&2
		return 1
	fi
	echo "Kernel 构建环境校验通过"
}

main
