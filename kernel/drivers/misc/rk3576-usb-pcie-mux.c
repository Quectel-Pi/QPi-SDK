// SPDX-License-Identifier: GPL-2.0
/*
 * Rockchip RK3576 SerDes MUX driver
 *
 * Controls the SMARC SH603ZA USB1/PCIE1 and SATA/PCIE0 external MUXes
 * via GPIO.
 *
 * The MUX SEL pin (USB_PCIE_CTL) is connected to GPIO0_C7.
 *   SEL = HIGH (1)  ->   PCIE1 mode
 *   SEL = LOW  (0)  ->   USB1 mode
 *
 * The MUX SEL pin (SMSATA_PCIE_CTL) is connected to GPIO0_A5.
 *   SEL = HIGH (1)  ->   SATA mode
 *   SEL = LOW  (0)  ->   PCIE0 mode
 *
 * The associated combphy PHY mode must be set separately by the target
 * controller driver at probe time.
 *
 * GPIO0_C7 has a board pull-up, so gpiod_get_value() (which reads
 * the pin's physical level) cannot be used to report mode — it reads
 * HIGH regardless of the driven value until the line settles.
 * cur_mode tracks the software-driven state instead.
 *
 * Sysfs interface:
 *   /sys/bus/platform/devices/usb-pcie-mux/mode
 *     Read  : "pcie" or "usb"  (reports driven state)
 *     Write : "pcie" or "usb"  (sets GPIO)
 *   /sys/bus/platform/devices/smsata-pcie-mux/mode
 *     Read  : "pcie" or "sata"  (reports driven state)
 *     Write : "pcie" or "sata"  (sets GPIO)
 */

#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <linux/gpio/consumer.h>
#include <linux/device.h>
#include <linux/delay.h>
#include <linux/of.h>
#include <linux/of_device.h>

struct rk3576_serdes_mux_cfg {
	const char *low_mode;
	const char *high_mode;
	const char *consumer;
	const char *description;
};

struct usb_pcie_mux {
	struct device      *dev;
	struct gpio_desc   *mux_gpio;
	const struct rk3576_serdes_mux_cfg *cfg;
	int                 cur_mode; /* driven value, not pin readback */
	int                 default_mode;
};

static ssize_t mode_show(struct device *dev,
			 struct device_attribute *attr, char *buf)
{
	struct usb_pcie_mux *mux = dev_get_drvdata(dev);
	return scnprintf(buf, PAGE_SIZE, "%s\n",
			 mux->cur_mode ? mux->cfg->high_mode : mux->cfg->low_mode);
}

/*
 * Query the current mux mode for a consumer controller.
 * Returns 1 if high_mode (e.g. "sata"), 0 if low_mode (e.g. "pcie"),
 * negative on error.
 *
 * Used by the shared-combphy controller drivers (rk-pcie / ahci-dwc) to
 * decide whether to probe. They must NOT request the mux GPIO themselves
 * (GPIOD_FLAGS_BIT_NONEXCLUSIVE consumers would kill the owner's request
 * on unbind via devm), so they query the mux driver's software state
 * instead of reading the pin.
 */
int rk3576_usb_pcie_mux_get_mode(struct device_node *np)
{
	struct platform_device *pdev;
	struct usb_pcie_mux *mux;

	if (!np)
		return -EINVAL;

	pdev = of_find_device_by_node(np);
	if (!pdev)
		return -EPROBE_DEFER;

	mux = dev_get_drvdata(&pdev->dev);
	platform_device_put(pdev);
	if (!mux)
		return -EPROBE_DEFER;

	return mux->cur_mode;
}
EXPORT_SYMBOL_GPL(rk3576_usb_pcie_mux_get_mode);

static ssize_t mode_store(struct device *dev,
			  struct device_attribute *attr,
			  const char *buf, size_t count)
{
	struct usb_pcie_mux *mux = dev_get_drvdata(dev);
	int gpio_val;

	if (sysfs_streq(buf, mux->cfg->low_mode))
		gpio_val = 0;
	else if (sysfs_streq(buf, mux->cfg->high_mode))
		gpio_val = 1;
	else
		return -EINVAL;

	if (mux->cur_mode == gpio_val) {
		dev_dbg(dev, "already in %s mode\n",
			gpio_val ? mux->cfg->high_mode : mux->cfg->low_mode);
		return count;
	}

	dev_info(dev, "switching MUX to %s mode\n",
		 gpio_val ? mux->cfg->high_mode : mux->cfg->low_mode);
	gpiod_set_value(mux->mux_gpio, gpio_val);
	usleep_range(1000, 2000);
	mux->cur_mode = gpio_val;
	dev_info(dev, "MUX switched to %s mode\n",
		 gpio_val ? mux->cfg->high_mode : mux->cfg->low_mode);

	return count;
}
static DEVICE_ATTR_RW(mode);

static const struct rk3576_serdes_mux_cfg usb_pcie_mux_cfg = {
	.low_mode = "usb",
	.high_mode = "pcie",
	.consumer = "usb_pcie_mux",
	.description = "USB/PCIE",
};

static const struct rk3576_serdes_mux_cfg sata_pcie_mux_cfg = {
	.low_mode = "pcie",
	.high_mode = "sata",
	.consumer = "sata_pcie_mux",
	.description = "SATA/PCIE",
};

static int usb_pcie_mux_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct usb_pcie_mux *mux;
	const char *default_mode;
	int ret;

	mux = devm_kzalloc(dev, sizeof(*mux), GFP_KERNEL);
	if (!mux)
		return -ENOMEM;

	mux->dev = dev;
	mux->cfg = of_device_get_match_data(dev);
	if (!mux->cfg)
		return -EINVAL;

	/* Default to low_mode unless "rockchip,default-mode" says otherwise */
	mux->default_mode = 0;
	ret = device_property_read_string(dev, "rockchip,default-mode",
					  &default_mode);
	if (ret == 0) {
		if (sysfs_streq(default_mode, mux->cfg->high_mode))
			mux->default_mode = 1;
		else if (!sysfs_streq(default_mode, mux->cfg->low_mode))
			dev_warn(dev, "invalid rockchip,default-mode \"%s\", using %s\n",
				 default_mode, mux->cfg->low_mode);
	}

	/* Request GPIO and drive default level at probe */
	mux->mux_gpio = devm_gpiod_get(dev, "mux",
				       (mux->default_mode ?
					GPIOD_OUT_HIGH : GPIOD_OUT_LOW) |
				       GPIOD_FLAGS_BIT_NONEXCLUSIVE);
	if (IS_ERR(mux->mux_gpio))
		return dev_err_probe(dev, PTR_ERR(mux->mux_gpio),
				     "failed to get mux-gpios\n");

	gpiod_set_consumer_name(mux->mux_gpio, mux->cfg->consumer);
	mux->cur_mode = mux->default_mode;

	dev_set_drvdata(dev, mux);

	ret = device_create_file(dev, &dev_attr_mode);
	if (ret)
		return ret;

	dev_info(dev, "%s MUX probed (default: %s mode)\n",
		 mux->cfg->description,
		 mux->cur_mode ? mux->cfg->high_mode : mux->cfg->low_mode);

	return 0;
}

static int usb_pcie_mux_remove(struct platform_device *pdev)
{
	device_remove_file(&pdev->dev, &dev_attr_mode);
	return 0;
}

static const struct of_device_id usb_pcie_mux_of_match[] = {
	{
		.compatible = "rockchip,rk3576-usb-pcie-mux",
		.data = &usb_pcie_mux_cfg,
	},
	{
		.compatible = "rockchip,rk3576-sata-pcie-mux",
		.data = &sata_pcie_mux_cfg,
	},
	{ }
};
MODULE_DEVICE_TABLE(of, usb_pcie_mux_of_match);

static struct platform_driver usb_pcie_mux_driver = {
	.probe  = usb_pcie_mux_probe,
	.remove = usb_pcie_mux_remove,
	.driver = {
		.name		= "rk3576_usb_pcie_mux",
		.of_match_table	= usb_pcie_mux_of_match,
	},
};
module_platform_driver(usb_pcie_mux_driver);

MODULE_AUTHOR("Quectel");
MODULE_DESCRIPTION("RK3576 SerDes MUX driver for SMARC SH603ZA");
MODULE_LICENSE("GPL");
