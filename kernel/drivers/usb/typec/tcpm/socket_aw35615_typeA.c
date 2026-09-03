// SPDX-License-Identifier: GPL-2.0

#include <linux/delay.h>
#include <linux/errno.h>
#include <linux/extcon.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of_device.h>
#include <linux/regulator/consumer.h>

#include "socket_aw35615_typeA.h"

#define AW35615_DRIVER_VERSION	"V2.0"

static int aw35615_i2c_write(struct aw35615_chip *chip, u8 reg, u8 val)
{
	int ret = i2c_smbus_write_byte_data(chip->i2c_client, reg, val);

	if (ret < 0)
		dev_err(chip->dev, "i2c write reg=0x%02x val=0x%02x failed: %d\n",
			reg, val, ret);
	return ret;
}

static int aw35615_i2c_read(struct aw35615_chip *chip, u8 reg, u8 *val)
{
	int ret = i2c_smbus_read_byte_data(chip->i2c_client, reg);

	if (ret < 0) {
		dev_err(chip->dev, "i2c read reg=0x%02x failed: %d\n", reg, ret);
		return ret;
	}
	*val = (u8)ret;
	return 0;
}

static int aw35615_i2c_mask_write(struct aw35615_chip *chip, u8 reg,
				  u8 mask, u8 val)
{
	u8 data;
	int ret;

	ret = aw35615_i2c_read(chip, reg, &data);
	if (ret < 0)
		return ret;
	data = (data & ~mask) | (val & mask);
	return aw35615_i2c_write(chip, reg, data);
}

static int aw35615_sw_reset(struct aw35615_chip *chip)
{
	int ret = aw35615_i2c_write(chip, AW_REG_RESET, AW_REG_RESET_SW_RESET);

	if (ret < 0)
		dev_err(chip->dev, "sw reset failed: %d\n", ret);
	else
		usleep_range(1000, 2000);
	return ret;
}

static int aw35615_check_chipid(struct i2c_client *i2c)
{
	int ret;
	int i;

	for (i = 0; i < 5; i++) {
		ret = i2c_smbus_read_byte_data(i2c, AW_REG_DEVICE_ID);
		if (ret < 0) {
			dev_err(&i2c->dev, "read chip id failed: %d\n", ret);
			usleep_range(2000, 3000);
			continue;
		}
		if ((ret & 0xF0) != AW35615_VID) {
			dev_err(&i2c->dev, "vid mismatch: 0x%02x\n", ret);
			return -ENODEV;
		}
		AW_LOG("chip id ok: 0x%02x\n", ret);
		return 0;
	}
	return -ENODEV;
}

static int aw35615_chip_init(struct aw35615_chip *chip)
{
	int ret;

	ret = aw35615_i2c_write(chip, AW_REG_POWER, AW_REG_POWER_PWR_ALL);
	if (ret < 0)
		return ret;

	ret = aw35615_i2c_write(chip, AW_REG_MASK,  0xFF);
	if (ret < 0)
		return ret;
	ret = aw35615_i2c_write(chip, AW_REG_MASKA, 0xFF);
	if (ret < 0)
		return ret;
	ret = aw35615_i2c_write(chip, AW_REG_MASKB, 0xFF);
	if (ret < 0)
		return ret;

	ret = aw35615_i2c_write(chip, AW_REG_CONTROL4, AW_REG_TOG_EXIT_AUD);
	if (ret < 0)
		return ret;

	return 0;
}

static int aw35615_set_role(struct aw35615_chip *chip, bool is_host)
{
	u8 mode;
	int ret;

	mutex_lock(&chip->lock);

	mode = is_host ? AW_REG_CONTROL2_MODE_DFP : AW_REG_CONTROL2_MODE_UFP;

	ret = aw35615_i2c_mask_write(chip, AW_REG_CONTROL2,
				     AW_REG_CONTROL2_TOGGLE, 0);
	if (ret < 0)
		goto out;

	ret = aw35615_i2c_mask_write(chip, AW_REG_CONTROL2,
				     AW_REG_CONTROL2_MODE_MASK, mode);
	if (ret < 0)
		goto out;

	if (is_host) {
		ret = aw35615_i2c_mask_write(chip, AW_REG_CONTROL0,
					     AW_REG_CONTROL0_HOST_CUR_MASK,
					     AW_REG_CONTROL0_HOST_CUR_DEF);
		if (ret < 0)
			goto out;
	}

	ret = aw35615_i2c_mask_write(chip, AW_REG_CONTROL2,
				     AW_REG_CONTROL2_TOGGLE,
				     AW_REG_CONTROL2_TOGGLE);
	if (ret < 0)
		goto out;

	if (chip->cc1sel_gpio)
		gpiod_set_value_cansleep(chip->cc1sel_gpio, is_host ? 1 : 0);
	if (chip->cc2sel_gpio)
		gpiod_set_value_cansleep(chip->cc2sel_gpio, is_host ? 1 : 0);

	chip->typea_is_host = is_host;
	dev_info(chip->dev, "role -> %s\n", is_host ? "DFP (Host)" : "UFP (Device)");

out:
	mutex_unlock(&chip->lock);
	return ret;
}

static int aw35615_extcon_notifier(struct notifier_block *nb,
				   unsigned long state, void *ptr)
{
	struct aw35615_chip *chip = container_of(nb, struct aw35615_chip,
						 extcon_nb);

	AW_LOG("extcon event: %s\n", state ? "HOST" : "DEVICE");
	aw35615_set_role(chip, !!state);

	return NOTIFY_OK;
}

static int aw35615_probe(struct i2c_client *client,
			 const struct i2c_device_id *id)
{
	struct device *dev = &client->dev;
	struct aw35615_chip *chip;
	struct extcon_dev *edev;
	int ret;

	AW_LOG("probe enter, driver version %s\n", AW35615_DRIVER_VERSION);

	if (!i2c_check_functionality(client->adapter, I2C_FUNC_SMBUS_BYTE_DATA)) {
		dev_err(dev, "I2C SMBus byte data not supported\n");
		return -ENODEV;
	}

	ret = aw35615_check_chipid(client);
	if (ret < 0)
		return ret;

	chip = devm_kzalloc(dev, sizeof(*chip), GFP_KERNEL);
	if (!chip)
		return -ENOMEM;

	chip->dev = dev;
	chip->i2c_client = client;
	mutex_init(&chip->lock);
	i2c_set_clientdata(client, chip);

	chip->vbus = devm_regulator_get_optional(dev, "vbus");
	if (IS_ERR(chip->vbus)) {
		if (PTR_ERR(chip->vbus) != -ENODEV) {
			dev_err(dev, "get vbus regulator failed: %ld\n",
				PTR_ERR(chip->vbus));
			return PTR_ERR(chip->vbus);
		}
		chip->vbus = NULL;
	}

	chip->cc1sel_gpio = devm_gpiod_get_optional(dev, "cc1sel", GPIOD_OUT_HIGH);
	if (IS_ERR(chip->cc1sel_gpio)) {
		dev_err(dev, "get cc1sel gpio failed: %ld\n",
			PTR_ERR(chip->cc1sel_gpio));
		return PTR_ERR(chip->cc1sel_gpio);
	}

	chip->cc2sel_gpio = devm_gpiod_get_optional(dev, "cc2sel", GPIOD_OUT_HIGH);
	if (IS_ERR(chip->cc2sel_gpio)) {
		dev_err(dev, "get cc2sel gpio failed: %ld\n",
			PTR_ERR(chip->cc2sel_gpio));
		return PTR_ERR(chip->cc2sel_gpio);
	}

	ret = aw35615_sw_reset(chip);
	if (ret < 0)
		return ret;

	ret = aw35615_chip_init(chip);
	if (ret < 0) {
		dev_err(dev, "chip init failed: %d\n", ret);
		return ret;
	}

	edev = extcon_get_edev_by_phandle(dev, 0);
	if (IS_ERR(edev)) {
		ret = PTR_ERR(edev);
		if (ret != -EPROBE_DEFER)
			dev_err(dev, "get extcon dev failed: %d\n", ret);
		return ret;
	}
	chip->extcon = edev;

	chip->extcon_nb.notifier_call = aw35615_extcon_notifier;
	ret = extcon_register_notifier(chip->extcon, EXTCON_USB_HOST,
				       &chip->extcon_nb);
	if (ret < 0) {
		dev_err(dev, "register extcon notifier failed: %d\n", ret);
		return ret;
	}

	ret = extcon_get_state(chip->extcon, EXTCON_USB_HOST);
	chip->typea_is_host = (ret == 1);
	dev_info(dev, "initial role: %s\n",
		 chip->typea_is_host ? "Host(DFP)" : "Device(UFP)");

	ret = aw35615_set_role(chip, chip->typea_is_host);
	if (ret < 0) {
		dev_err(dev, "set initial role failed: %d\n", ret);
		goto unreg_notifier;
	}

	dev_info(dev, "socket_aw35615_typeA probe success\n");
	return 0;

unreg_notifier:
	extcon_unregister_notifier(chip->extcon, EXTCON_USB_HOST,
				   &chip->extcon_nb);
	return ret;
}

static void aw35615_remove(struct i2c_client *client)
{
	struct aw35615_chip *chip = i2c_get_clientdata(client);

	if (chip->extcon)
		extcon_unregister_notifier(chip->extcon, EXTCON_USB_HOST,
					   &chip->extcon_nb);

	aw35615_sw_reset(chip);
}

static int aw35615_pm_suspend(struct device *dev)
{
	return 0;
}

static int aw35615_pm_resume(struct device *dev)
{
	struct aw35615_chip *chip = dev->driver_data;
	int ret;

	ret = aw35615_sw_reset(chip);
	if (ret < 0)
		return ret;

	ret = aw35615_chip_init(chip);
	if (ret < 0) {
		dev_err(dev, "resume: chip init failed: %d\n", ret);
		return ret;
	}

	ret = aw35615_set_role(chip, chip->typea_is_host);
	if (ret < 0)
		dev_err(dev, "resume: restore role failed: %d\n", ret);

	return ret;
}

static const struct dev_pm_ops aw35615_pm_ops = {
	.suspend = aw35615_pm_suspend,
	.resume  = aw35615_pm_resume,
};

static const struct of_device_id aw35615_dt_match[] = {
	{ .compatible = "socket_aw35615-typea" },
	{},
};
MODULE_DEVICE_TABLE(of, aw35615_dt_match);

static const struct i2c_device_id aw35615_i2c_id[] = {
	{ "socket_aw35615-typea", 0 },
	{},
};
MODULE_DEVICE_TABLE(i2c, aw35615_i2c_id);

static struct i2c_driver aw35615_driver = {
	.driver = {
		.name           = "socket_aw35615-typea",
		.pm             = &aw35615_pm_ops,
		.of_match_table = of_match_ptr(aw35615_dt_match),
	},
	.probe    = aw35615_probe,
	.remove   = aw35615_remove,
	.id_table = aw35615_i2c_id,
};
module_i2c_driver(aw35615_driver);

MODULE_AUTHOR("ethan.mo");
MODULE_DESCRIPTION("AW35615 Type-A only Driver");
MODULE_LICENSE("GPL");
