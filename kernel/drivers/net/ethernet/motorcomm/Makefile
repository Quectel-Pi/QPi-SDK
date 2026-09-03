# SPDX-License-Identifier: GPL-2.0
#
# Makefile for the Motorcomm(R) network device drivers.
#

obj-$(CONFIG_YT6801) += yt6801.o

yt6801-objs := fuxi-gmac-common.o fuxi-gmac-desc.o fuxi-gmac-ethtool.o \
	       fuxi-gmac-hw.o fuxi-gmac-net.o fuxi-gmac-pci.o \
	       fuxi-gmac-phy.o fuxi-efuse.o fuxi-gmac-ioctl.o

ccflags-y += -DFXGMAC_INT_MODERATION_ENABLED=1 -DINT_MOD_IN_US=200
ccflags-y += -DFXGMAC_TX_PAUSE_ENABLED=0

# The vendor 1.0.33 source leaves a debug-only stats pointer unused.
CFLAGS_fuxi-gmac-net.o += -Wno-unused-variable
