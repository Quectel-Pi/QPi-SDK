# hello - Quectel PI H1 (QCS6490) 应用模板
#
# 由扩展「新建工程」或 SDK `newapp` 创建。
# 编译:
#   在 SDK 根目录:  source build.sh && buildapp <本目录>
#   或直接:         make
#
# SYSROOT 说明 (重要, 勿改动本行的位置与形式):
#   扩展创建工程时用正则 ^SYSROOT\s*\?=.*$ 改写本行为实际相对路径。
#   因此本行必须:
#     1) 顶格 (行首不得有空格/制表符, 否则正则不匹配 -> 静默失效)
#     2) 全文件仅此一行 (re.sub 会替换所有匹配行)
SYSROOT ?= ../prebuilds/sysroot

# source build.sh 后 CC/CFLAGS/LDFLAGS 已由 SDK 导出; 未 source 时给出回退
CC      ?= aarch64-linux-gnu-gcc
CFLAGS  ?=
LDFLAGS ?=

TARGET  := hello
PREFIX  ?= /usr/local
DESTDIR ?=

# 交叉编译 sysroot (与 SDK 导出的 --sysroot 同值, 重复无碍; 未 source 时由此生效)
CFLAGS  += --sysroot=$(SYSROOT) -I$(SYSROOT)/usr/include
LDFLAGS += --sysroot=$(SYSROOT) -L$(SYSROOT)/usr/lib/aarch64-linux-gnu

all: $(TARGET)

$(TARGET): main.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

install: $(TARGET)
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 0755 $(TARGET) $(DESTDIR)$(PREFIX)/bin/

clean:
	rm -f $(TARGET)

.PHONY: all install clean
