# 示例应用: hello-h1
# 演示 simple-h1 的 make install 机制
# 用法: ../../scripts/install-app.sh apps/hello-h1
#
# 注意: 本示例用宿主 gcc 编译 (仅演示安装机制)。
# 目标板应用如需交叉编译, 将 CC 指向 aarch64-qcom-linux-gcc
# 并准备目标 sysroot (libc 头文件), 例如:
#   make CC=aarch64-qcom-linux-gcc CROSS_SYSROOT=/path/to/sysroot

CC ?= gcc
PREFIX ?= /usr/local
DESTDIR ?=

all: hello-h1

hello-h1: main.c
	$(CC) -o $@ $<

install: hello-h1
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 0755 hello-h1 $(DESTDIR)$(PREFIX)/bin/
	install -d $(DESTDIR)$(PREFIX)/share/hello-h1
	echo "Hello from simple-h1!" > $(DESTDIR)$(PREFIX)/share/hello-h1/README.txt

clean:
	rm -f hello-h1

.PHONY: all install clean
