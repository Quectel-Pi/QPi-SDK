# {{PROJECT_NAME}} - Quectel PI H1 (QCS6490) 应用模板
# 由 newapp 创建。编译: source build.sh && buildapp <目录>  (或直接 make)
#
# 说明:
#   - source build.sh / tools/environment-setup.sh 后, CC/CXX/CFLAGS 等已由
#     SDK 设为 qemu wrapper 工具链 (sysroot 内 Debian gcc-14, 真 aarch64 交叉编译)
#   - 未 source 时回退: CC=aarch64-qcom-linux-gcc (无 sysroot, 仅内核用)
#     → 用宿主 gcc 编译仅验证流程, 产物不上板
#   - 安装到 overlay: ./scripts/install-app.sh apps/{{PROJECT_NAME}}

TARGET := {{PROJECT_NAME}}

# source build.sh 后 CC/CFLAGS 已导出; 未 source 时给出回退
CC ?= gcc
CFLAGS ?=
LDFLAGS ?=
PREFIX ?= /usr/local
DESTDIR ?=

all: $(TARGET)

$(TARGET): main.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

install: $(TARGET)
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 0755 $(TARGET) $(DESTDIR)$(PREFIX)/bin/

clean:
	rm -f $(TARGET)

.PHONY: all install clean
