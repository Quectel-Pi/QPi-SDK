/* SPDX-License-Identifier: GPL-2.0 */

#ifndef AW35615_REG_H
#define AW35615_REG_H

#include <linux/kernel.h>
#include <linux/gpio/consumer.h>
#include <linux/extcon.h>
#include <linux/mutex.h>
#include <linux/i2c.h>

#define AW35615_VID					(0x90)

#define AW_REG_DEVICE_ID			(0x01)

#define AW_REG_SWITCHES0			(0x02)
#define AW_REG_SWITCHES0_CC2_PU_EN	BIT(7)
#define AW_REG_SWITCHES0_CC1_PU_EN	BIT(6)
#define AW_REG_SWITCHES0_CC2_PD_EN	BIT(1)
#define AW_REG_SWITCHES0_CC1_PD_EN	BIT(0)

#define AW_REG_CONTROL0				(0x06)
#define AW_REG_CONTROL0_HOST_CUR_MASK	(0xC)
#define AW_REG_CONTROL0_HOST_CUR_DEF	(0x4)

#define AW_REG_CONTROL2				(0x08)
#define AW_REG_CONTROL2_MODE_MASK	(0x6)
#define AW_REG_CONTROL2_MODE_DFP	(0x6)
#define AW_REG_CONTROL2_MODE_UFP	(0x4)
#define AW_REG_CONTROL2_TOGGLE		BIT(0)

#define AW_REG_MASK					(0x0A)
#define AW_REG_MASK_VBUSOK			BIT(7)

#define AW_REG_POWER				(0x0B)
#define AW_REG_POWER_PWR_ALL		(0xF)

#define AW_REG_RESET				(0x0C)
#define AW_REG_RESET_SW_RESET		BIT(0)

#define AW_REG_MASKA				(0x0E)
#define AW_REG_MASKB				(0x0F)

#define AW_REG_CONTROL4				(0x10)
#define AW_REG_TOG_EXIT_AUD			BIT(0)

#define AW_REG_STATUS0				(0x40)
#define AW_REG_STATUS0_VBUSOK		BIT(7)

#define AW_REG_INTERRUPT			(0x42)
#define AW_REG_INTERRUPT_VBUSOK		BIT(7)

struct aw35615_chip {
	struct device      *dev;
	struct i2c_client  *i2c_client;
	struct mutex        lock;

	/* VBUS regulator */
	struct regulator   *vbus;

	/* CC PMOS 控制 GPIO */
	struct gpio_desc   *cc1sel_gpio;  /* GPIO4_B2，控制 USB1_CC1 PMOS */
	struct gpio_desc   *cc2sel_gpio;  /* GPIO4_A7，控制 USB1_CC2 PMOS */

	/* extcon：监听 u2phy1 上报的 OTG 角色事件 */
	struct extcon_dev  *extcon;
	struct notifier_block extcon_nb;

	/* 当前角色：true = Host/DFP，false = Device/UFP */
	bool typea_is_host;
};

#define AWINIC_DEBUG
#ifdef AWINIC_DEBUG
#define AWINIC_LOG_NAME "aw35615"
#define AW_LOG(fmt, arg...) \
	pr_info("[%s] %s %d: " fmt, AWINIC_LOG_NAME, __func__, __LINE__, ##arg)
#else
#define AW_LOG(fmt, arg...)
#endif

#endif /* AW35615_REG_H */
