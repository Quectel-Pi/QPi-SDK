# Quectel PI H1 (QCS6490) CMake 交叉编译工具链
# 与 QPi-SDK (M2) 的 tools/cmake/ 用法一致:
#   cmake -S . -B build -DCMAKE_TOOLCHAIN_FILE=tools/cmake/aarch64-qcom-rootfs-toolchain.cmake
# 原理: qemu wrapper 跑 prebuilds/sysroot 内 Debian gcc-14 (与 M2 的
#       m2-debian-toolchain 同构, 免 root; 依赖 qemu-aarch64 binfmt)

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# SDK 根 (本文件在 tools/cmake/ 下)
get_filename_component(QPI_SDK_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(QPI_SYSROOT "${QPI_SDK_ROOT}/prebuilds/sysroot" CACHE PATH "H1 rootfs sysroot")
set(QPI_TOOLCHAIN_DIR "${QPI_SDK_ROOT}/toolchains/qcom-rootfs-toolchain")

set(CMAKE_SYSROOT "${QPI_SYSROOT}")

set(CMAKE_C_COMPILER "${QPI_TOOLCHAIN_DIR}/bin/aarch64-linux-gnu-gcc")
set(CMAKE_CXX_COMPILER "${QPI_TOOLCHAIN_DIR}/bin/aarch64-linux-gnu-g++")
set(CMAKE_AR "${QPI_TOOLCHAIN_DIR}/bin/aarch64-linux-gnu-ar")
set(CMAKE_RANLIB "${QPI_TOOLCHAIN_DIR}/bin/aarch64-linux-gnu-ranlib")
set(CMAKE_STRIP "${QPI_TOOLCHAIN_DIR}/bin/aarch64-linux-gnu-strip")
set(CMAKE_OBJCOPY "${QPI_TOOLCHAIN_DIR}/bin/aarch64-linux-gnu-objcopy")
set(CMAKE_OBJDUMP "${QPI_TOOLCHAIN_DIR}/bin/aarch64-linux-gnu-objdump")

set(CMAKE_FIND_ROOT_PATH "${QPI_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(CMAKE_C_FLAGS "--sysroot=${QPI_SYSROOT}" CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS "--sysroot=${QPI_SYSROOT}" CACHE STRING "" FORCE)
