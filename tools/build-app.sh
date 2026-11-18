#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
app_dir="${1:-}"

if [ -z "$app_dir" ]; then
	echo "用法: tools/build-app.sh <应用目录>" >&2
	exit 1
fi
app_dir=$(cd "$app_dir" 2>/dev/null && pwd -P) || {
	echo "ERROR: 应用目录不存在: $app_dir" >&2
	exit 1
}

for tool in aarch64-linux-gnu-gcc aarch64-linux-gnu-g++; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "ERROR: Docker 镜像缺少 $tool。" >&2
		echo "       请重新构建 SDK Docker 镜像。" >&2
		exit 1
	fi
done

if [ -f "$app_dir/CMakeLists.txt" ]; then
	command -v cmake >/dev/null 2>&1 || {
		echo "ERROR: Docker 镜像缺少 cmake" >&2
		exit 1
	}
	cmake -S "$app_dir" -B "$app_dir/build" \
		-DCMAKE_TOOLCHAIN_FILE="$ROOT/tools/cmake/aarch64-linux-gnu-toolchain.cmake"
	cmake --build "$app_dir/build"
elif [ -f "$app_dir/Makefile" ]; then
	command -v make >/dev/null 2>&1 || {
		echo "ERROR: Docker 镜像缺少 make" >&2
		exit 1
	}
	make -C "$app_dir" \
		CROSS_COMPILE=aarch64-linux-gnu- \
		CC=aarch64-linux-gnu-gcc \
		CXX=aarch64-linux-gnu-g++
else
	echo "ERROR: 未找到 CMakeLists.txt 或 Makefile: $app_dir" >&2
	exit 1
fi
