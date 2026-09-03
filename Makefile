# Quectel M2 SDK - top-level entry

SHELL := /bin/bash
BUILD_SH := ./build.sh

.PHONY: newapp app all check kernel boot overlays rootfs menuconfig defconfig savedefconfig clean help

# 从模板创建应用: make newapp NAME=myapp [TEMPLATE=hello]
newapp:
	source $(BUILD_SH) >/dev/null && newapp $(NAME) $(TEMPLATE)

# 交叉编译应用: make app DIR=docs/examples/hello
app:
	source $(BUILD_SH) >/dev/null && buildapp $(DIR)

all:
	source $(BUILD_SH) >/dev/null && buildall

check:
	source $(BUILD_SH) >/dev/null && buildcheck

kernel:
	source $(BUILD_SH) >/dev/null && buildkernel

boot:
	source $(BUILD_SH) >/dev/null && buildboot

overlays:
	source $(BUILD_SH) >/dev/null && buildoverlays

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