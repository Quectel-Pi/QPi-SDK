# Quectel PI H1 (QCS6490) simple-h1 SDK - top-level entry
# 目标集与 QPi-SDK (M2) 的 Makefile 兼容 —— make 命令在两个 SDK 通用

SHELL := /bin/bash
BUILD_SH := ./build.sh

.PHONY: newapp app all check kernel boot overlays rootfs menuconfig defconfig savedefconfig clean help

# 从模板创建应用: make newapp NAME=myapp [TEMPLATE=hello]
newapp:
	source $(BUILD_SH) >/dev/null && newapp $(NAME) $(TEMPLATE)

# 编译应用: make app DIR=apps/hello-h1
app:
	source $(BUILD_SH) >/dev/null && buildapp $(DIR)

# 完整打包: 内核 + efi.bin + dtb.bin + system.img (应用层改动: SKIP_KERNEL=1 make all)
all:
	source $(BUILD_SH) >/dev/null && buildall

check:
	source $(BUILD_SH) >/dev/null && buildcheck

# 编译内核
kernel:
	source $(BUILD_SH) >/dev/null && buildkernel

# 打包启动镜像 (efi.bin + dtb.bin)
boot:
	source $(BUILD_SH) >/dev/null && buildboot

# 设备树 overlays (simple-h1: 预置 dtbo 说明)
overlays:
	source $(BUILD_SH) >/dev/null && buildoverlays

# 应用 overlay/ 打包 system.img
rootfs:
	source $(BUILD_SH) >/dev/null && buildrootfs

menuconfig:
	source $(BUILD_SH) >/dev/null && buildmenuconfig

defconfig:
	source $(BUILD_SH) >/dev/null && builddefconfig

savedefconfig:
	source $(BUILD_SH) >/dev/null && buildsavedefconfig

clean:
	source $(BUILD_SH) >/dev/null && buildclean

help:
	@source $(BUILD_SH) >/dev/null && buildhelp
