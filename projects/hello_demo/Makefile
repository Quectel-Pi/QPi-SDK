# ============================================================
#  {{PROJECT_NAME}} - 构建脚本
#  用法: 在 SDK 图形化工具中点「构建」即可, 无需手动操作
# ============================================================

# 交叉编译器 (由 environment-setup.sh 提供, 找不到时使用下方默认值)
CC      ?= aarch64-none-linux-gnu-gcc
SYSROOT ?= ../../../prebuilds/sysroot

CFLAGS  ?= --sysroot=$(SYSROOT) \
           -I$(SYSROOT)/usr/include -I$(SYSROOT)/usr/include/aarch64-linux-gnu \
           -Wall -Wextra -O2
LDFLAGS ?= --sysroot=$(SYSROOT) \
           -B$(SYSROOT)/usr/lib/aarch64-linux-gnu \
           -L$(SYSROOT)/usr/lib/aarch64-linux-gnu -L$(SYSROOT)/lib/aarch64-linux-gnu

# 额外链接库 (如线程: -lpthread)
LIBS    ?=

TARGET = {{PROJECT_NAME}}

all: $(TARGET)

$(TARGET): main.c
	$(CC) $(CFLAGS) $< -o $@ $(LDFLAGS) $(LIBS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
