// SPDX-License-Identifier: GPL-2.0
/*
 * Waveshare I2C panel/backlight controller.
 *
 * Ported from the Qualcomm baseline waveshare-bl driver and adapted for
 * the RK3576 Linux 6.1 tree.
 */

#include <linux/backlight.h>
#include <linux/debugfs.h>
#include <linux/delay.h>
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/regulator/consumer.h>
#include <linux/slab.h>
#include <linux/sysfs.h>
#include <linux/uaccess.h>
#include <linux/waveshare-bl.h>

#define WS_PANEL_DEFAULT_BRIGHTNESS	255
#define WS_PANEL_DEFAULT_MAX_BRIGHTNESS	255
#define WS_PANEL_ENABLE_REG		0xaa
#define WS_PANEL_BRIGHTNESS_REG		0xab
#define WS_PANEL_DETECT_REG		WS_PANEL_BRIGHTNESS_REG

struct ws_panel {
	struct i2c_client *i2c;
	struct backlight_device *bl_dev;
	struct regulator *vddio_i2c;
	struct regulator *vdd_ana;
	struct gpio_desc *switch_gpio;
	struct gpio_desc *power_gpio;
	struct dentry *debugfs_dir;
	struct device *dev;
	u32 min_brightness;
	bool present;
};

static struct ws_panel *g_ws_panel;

static struct ws_panel *ws_panel_get_instance(void)
{
	return g_ws_panel;
}

int ws_panel_detect_presence(void)
{
	struct ws_panel *panel = ws_panel_get_instance();
	int ret;

	if (!panel || !panel->i2c)
		return -ENODEV;

	ret = i2c_smbus_read_byte_data(panel->i2c, WS_PANEL_DETECT_REG);
	if (ret < 0) {
		panel->present = false;
		dev_warn(panel->dev,
			 "waveshare panel detect failed: i2c-%d addr=0x%02x reg 0x%02x read failed: %d, treat MIPI panel as absent\n",
			 panel->i2c->adapter->nr, panel->i2c->addr,
			 WS_PANEL_DETECT_REG, ret);
		return ret;
	}

	panel->present = true;
	dev_info(panel->dev,
		 "waveshare panel detect ok: i2c-%d addr=0x%02x reg 0x%02x=0x%02x, MIPI panel present\n",
		 panel->i2c->adapter->nr, panel->i2c->addr,
		 WS_PANEL_DETECT_REG, ret);

	return ret;
}
EXPORT_SYMBOL_GPL(ws_panel_detect_presence);

bool ws_panel_is_present(void)
{
	struct ws_panel *panel = ws_panel_get_instance();

	return panel && panel->present;
}
EXPORT_SYMBOL_GPL(ws_panel_is_present);

int ws_panel_i2c_read(u8 reg)
{
	struct ws_panel *panel = ws_panel_get_instance();
	int ret;

	if (!panel || !panel->i2c)
		return -EINVAL;

	ret = i2c_smbus_read_byte_data(panel->i2c, reg);
	if (ret < 0)
		dev_err(panel->dev, "failed to read reg 0x%02x: %d\n", reg, ret);

	return ret;
}
EXPORT_SYMBOL_GPL(ws_panel_i2c_read);

int ws_panel_i2c_write(u8 reg, u8 val)
{
	struct ws_panel *panel = ws_panel_get_instance();
	int ret;

	if (!panel || !panel->i2c)
		return -EINVAL;
	if (!panel->present)
		return -ENODEV;

	ret = i2c_smbus_write_byte_data(panel->i2c, reg, val);
	if (ret)
		dev_err(panel->dev, "failed to write reg 0x%02x: %d\n", reg, ret);

	return ret;
}
EXPORT_SYMBOL_GPL(ws_panel_i2c_write);

int ws_panel_set_backlight(unsigned int value)
{
	int ret;

	if (value > WS_PANEL_DEFAULT_MAX_BRIGHTNESS)
		value = WS_PANEL_DEFAULT_MAX_BRIGHTNESS;

	ret = ws_panel_i2c_write(WS_PANEL_BRIGHTNESS_REG,
				 WS_PANEL_DEFAULT_MAX_BRIGHTNESS - value);
	if (ret)
		return ret;

	return ws_panel_i2c_write(WS_PANEL_ENABLE_REG, value ? 0x01 : 0x00);
}
EXPORT_SYMBOL_GPL(ws_panel_set_backlight);

void ws_panel_switch_mipi(bool switch_ws)
{
	struct ws_panel *panel = ws_panel_get_instance();

	if (!panel || !panel->switch_gpio)
		return;

	gpiod_set_value_cansleep(panel->switch_gpio, switch_ws ? 0 : 1);
}
EXPORT_SYMBOL_GPL(ws_panel_switch_mipi);

void ws_panel_poweron_mipi(void)
{
	struct ws_panel *panel = ws_panel_get_instance();

	if (!panel || !panel->power_gpio)
		return;

	gpiod_set_value_cansleep(panel->power_gpio, 1);
}
EXPORT_SYMBOL_GPL(ws_panel_poweron_mipi);

static int ws_panel_bl_update_status(struct backlight_device *bl)
{
	struct ws_panel *panel = dev_get_drvdata(&bl->dev);
	int brightness = backlight_get_brightness(bl);

	if (!panel->present)
		return 0;

	if (backlight_is_blank(bl))
		brightness = 0;
	else if (brightness < panel->min_brightness)
		brightness = panel->min_brightness;

	return ws_panel_set_backlight(brightness);
}

static const struct backlight_ops ws_panel_bl_ops = {
	.options = BL_CORE_SUSPENDRESUME,
	.update_status = ws_panel_bl_update_status,
};

static struct backlight_device *ws_panel_create_backlight(struct ws_panel *panel)
{
	struct device *dev = panel->dev;
	struct backlight_properties props = {
		.type = BACKLIGHT_RAW,
		.brightness = WS_PANEL_DEFAULT_BRIGHTNESS,
		.max_brightness = WS_PANEL_DEFAULT_MAX_BRIGHTNESS,
	};
	u32 value;

	if (!of_property_read_u32(dev->of_node, "max-brightness-level", &value) &&
	    value > 0)
		props.max_brightness = value;

	if (!of_property_read_u32(dev->of_node, "default-brightness-level",
				  &value))
		props.brightness = min_t(u32, value, props.max_brightness);

	if (!of_property_read_u32(dev->of_node, "min-brightness-level", &value))
		panel->min_brightness = value;
	else
		panel->min_brightness = 15;

	return devm_backlight_device_register(dev, dev_name(dev), dev, panel,
					      &ws_panel_bl_ops, &props);
}

static ssize_t reg_read_store(struct device *dev,
			      struct device_attribute *attr,
			      const char *buf, size_t count)
{
	unsigned int reg;
	int ret;

	if (kstrtouint(buf, 16, &reg))
		return -EINVAL;

	ret = ws_panel_i2c_read(reg);
	if (ret < 0)
		return ret;

	dev_info(dev, "reg[0x%02x] = 0x%02x\n", reg, ret);
	return count;
}

static ssize_t reg_write_store(struct device *dev,
			       struct device_attribute *attr,
			       const char *buf, size_t count)
{
	unsigned int reg;
	unsigned int val;
	int ret;

	if (sscanf(buf, "%x %x", &reg, &val) != 2)
		return -EINVAL;

	ret = ws_panel_i2c_write(reg, val);
	if (ret)
		return ret;

	dev_info(dev, "reg[0x%02x] <= 0x%02x\n", reg, val);
	return count;
}

static ssize_t backlight_brightness_store(struct device *dev,
					  struct device_attribute *attr,
					  const char *buf, size_t count)
{
	struct ws_panel *panel = dev_get_drvdata(dev);
	unsigned int brightness;
	int ret;

	if (kstrtouint(buf, 10, &brightness))
		return -EINVAL;

	if (panel->bl_dev)
		brightness = min_t(unsigned int, brightness,
				   panel->bl_dev->props.max_brightness);

	brightness = max_t(unsigned int, brightness, panel->min_brightness);

	ret = ws_panel_set_backlight(brightness);
	if (ret)
		return ret;

	if (panel->bl_dev)
		panel->bl_dev->props.brightness = brightness;

	dev_info(dev, "backlight set to %u\n", brightness);
	return count;
}

static ssize_t power_status_show(struct device *dev,
				 struct device_attribute *attr, char *buf)
{
	struct ws_panel *panel = dev_get_drvdata(dev);
	int vdd_ana_enabled = 0;
	int vddio_enabled = 0;

	if (panel->vdd_ana)
		vdd_ana_enabled = regulator_is_enabled(panel->vdd_ana);

	if (panel->vddio_i2c)
		vddio_enabled = regulator_is_enabled(panel->vddio_i2c);

	return sprintf(buf, "vdd_ana: %s\nvddio_i2c: %s\n",
		       vdd_ana_enabled ? "enabled" : "disabled",
		       vddio_enabled ? "enabled" : "disabled");
}

static ssize_t gpio_status_show(struct device *dev,
				struct device_attribute *attr, char *buf)
{
	struct ws_panel *panel = dev_get_drvdata(dev);
	int switch_val = -1;
	int power_val = -1;

	if (panel->switch_gpio)
		switch_val = gpiod_get_value(panel->switch_gpio);

	if (panel->power_gpio)
		power_val = gpiod_get_value(panel->power_gpio);

	return sprintf(buf, "switch_gpio: %d\npower_gpio: %d\n",
		       switch_val, power_val);
}

static ssize_t power_gpio_store(struct device *dev,
				struct device_attribute *attr,
				const char *buf, size_t count)
{
	struct ws_panel *panel = dev_get_drvdata(dev);
	unsigned int value;

	if (kstrtouint(buf, 10, &value))
		return -EINVAL;

	if (!panel->power_gpio)
		return -ENODEV;

	gpiod_set_value_cansleep(panel->power_gpio, !!value);
	return count;
}

static ssize_t power_gpio_show(struct device *dev,
			       struct device_attribute *attr, char *buf)
{
	struct ws_panel *panel = dev_get_drvdata(dev);
	int value = -1;

	if (panel->power_gpio)
		value = gpiod_get_value(panel->power_gpio);

	return sprintf(buf, "%d\n", value);
}

static ssize_t switch_gpio_store(struct device *dev,
				 struct device_attribute *attr,
				 const char *buf, size_t count)
{
	struct ws_panel *panel = dev_get_drvdata(dev);
	unsigned int value;

	if (kstrtouint(buf, 10, &value))
		return -EINVAL;

	if (!panel->switch_gpio)
		return -ENODEV;

	gpiod_set_value_cansleep(panel->switch_gpio, !!value);
	return count;
}

static ssize_t switch_gpio_show(struct device *dev,
				struct device_attribute *attr, char *buf)
{
	struct ws_panel *panel = dev_get_drvdata(dev);
	int value = -1;

	if (panel->switch_gpio)
		value = gpiod_get_value(panel->switch_gpio);

	return sprintf(buf, "%d\n", value);
}

static DEVICE_ATTR_WO(reg_read);
static DEVICE_ATTR_WO(reg_write);
static DEVICE_ATTR_WO(backlight_brightness);
static DEVICE_ATTR_RW(power_gpio);
static DEVICE_ATTR_RW(switch_gpio);
static DEVICE_ATTR_RO(power_status);
static DEVICE_ATTR_RO(gpio_status);

static struct attribute *ws_panel_attrs[] = {
	&dev_attr_reg_read.attr,
	&dev_attr_reg_write.attr,
	&dev_attr_backlight_brightness.attr,
	&dev_attr_power_gpio.attr,
	&dev_attr_switch_gpio.attr,
	&dev_attr_power_status.attr,
	&dev_attr_gpio_status.attr,
	NULL,
};

static const struct attribute_group ws_panel_group = {
	.attrs = ws_panel_attrs,
};

static ssize_t debug_registers_read(struct file *file, char __user *user_buf,
				    size_t count, loff_t *ppos)
{
	char *buf;
	int len = 0;
	int ret;
	int reg;
	static const u8 debug_regs[] = { 0x00, 0x01, 0x02, 0x03, 0x04, 0x05,
					 WS_PANEL_ENABLE_REG,
					 WS_PANEL_BRIGHTNESS_REG };

	buf = kzalloc(1024, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;

	len += scnprintf(buf + len, 1024 - len, "Waveshare panel registers:\n");

	for (reg = 0; reg < ARRAY_SIZE(debug_regs); reg++) {
		ret = ws_panel_i2c_read(debug_regs[reg]);
		if (ret >= 0)
			len += scnprintf(buf + len, 1024 - len,
					 "reg 0x%02x: 0x%02x\n",
					 debug_regs[reg], ret);
		else
			len += scnprintf(buf + len, 1024 - len,
					 "reg 0x%02x: error(%d)\n",
					 debug_regs[reg], ret);
	}

	ret = simple_read_from_buffer(user_buf, count, ppos, buf, len);
	kfree(buf);
	return ret;
}

static ssize_t debug_power_gpio_write(struct file *file,
				      const char __user *user_buf,
				      size_t count, loff_t *ppos)
{
	struct ws_panel *panel = file->private_data;
	char buf[16];
	unsigned int value;

	if (count >= sizeof(buf))
		return -EINVAL;

	if (copy_from_user(buf, user_buf, count))
		return -EFAULT;

	buf[count] = '\0';
	if (kstrtouint(buf, 10, &value))
		return -EINVAL;

	if (panel->power_gpio)
		gpiod_set_value_cansleep(panel->power_gpio, !!value);

	return count;
}

static ssize_t debug_power_gpio_read(struct file *file, char __user *user_buf,
				     size_t count, loff_t *ppos)
{
	struct ws_panel *panel = file->private_data;
	char buf[16];
	int len;
	int value = -1;

	if (panel->power_gpio)
		value = gpiod_get_value(panel->power_gpio);

	len = scnprintf(buf, sizeof(buf), "%d\n", value);
	return simple_read_from_buffer(user_buf, count, ppos, buf, len);
}

static ssize_t debug_switch_gpio_write(struct file *file,
				       const char __user *user_buf,
				       size_t count, loff_t *ppos)
{
	struct ws_panel *panel = file->private_data;
	char buf[16];
	unsigned int value;

	if (count >= sizeof(buf))
		return -EINVAL;

	if (copy_from_user(buf, user_buf, count))
		return -EFAULT;

	buf[count] = '\0';
	if (kstrtouint(buf, 10, &value))
		return -EINVAL;

	if (panel->switch_gpio)
		gpiod_set_value_cansleep(panel->switch_gpio, !!value);

	return count;
}

static ssize_t debug_switch_gpio_read(struct file *file, char __user *user_buf,
				      size_t count, loff_t *ppos)
{
	struct ws_panel *panel = file->private_data;
	char buf[16];
	int len;
	int value = -1;

	if (panel->switch_gpio)
		value = gpiod_get_value(panel->switch_gpio);

	len = scnprintf(buf, sizeof(buf), "%d\n", value);
	return simple_read_from_buffer(user_buf, count, ppos, buf, len);
}

static const struct file_operations debug_registers_fops = {
	.owner = THIS_MODULE,
	.open = simple_open,
	.read = debug_registers_read,
	.llseek = default_llseek,
};

static const struct file_operations debug_power_gpio_fops = {
	.owner = THIS_MODULE,
	.open = simple_open,
	.read = debug_power_gpio_read,
	.write = debug_power_gpio_write,
	.llseek = default_llseek,
};

static const struct file_operations debug_switch_gpio_fops = {
	.owner = THIS_MODULE,
	.open = simple_open,
	.read = debug_switch_gpio_read,
	.write = debug_switch_gpio_write,
	.llseek = default_llseek,
};

static void ws_panel_debugfs_init(struct ws_panel *panel)
{
	panel->debugfs_dir = debugfs_create_dir("ws_panel", NULL);
	if (IS_ERR_OR_NULL(panel->debugfs_dir)) {
		panel->debugfs_dir = NULL;
		dev_warn(panel->dev, "failed to create debugfs directory\n");
		return;
	}

	debugfs_create_file("registers", 0444, panel->debugfs_dir, panel,
			    &debug_registers_fops);
	debugfs_create_file("power_gpio", 0644, panel->debugfs_dir, panel,
			    &debug_power_gpio_fops);
	debugfs_create_file("switch_gpio", 0644, panel->debugfs_dir, panel,
			    &debug_switch_gpio_fops);
}

static void ws_panel_debugfs_exit(struct ws_panel *panel)
{
	if (panel->debugfs_dir)
		debugfs_remove_recursive(panel->debugfs_dir);
}

static int ws_panel_probe(struct i2c_client *i2c,
			  const struct i2c_device_id *id)
{
	struct device *dev = &i2c->dev;
	struct ws_panel *panel;
	int ret;

	panel = devm_kzalloc(dev, sizeof(*panel), GFP_KERNEL);
	if (!panel)
		return -ENOMEM;

	panel->i2c = i2c;
	panel->dev = dev;
	i2c_set_clientdata(i2c, panel);

	panel->switch_gpio = devm_gpiod_get_optional(dev, "switch", GPIOD_ASIS);
	if (IS_ERR(panel->switch_gpio))
		return PTR_ERR(panel->switch_gpio);

	panel->power_gpio = devm_gpiod_get_optional(dev, "power", GPIOD_OUT_HIGH);
	if (IS_ERR(panel->power_gpio))
		return PTR_ERR(panel->power_gpio);

	msleep(100);

	g_ws_panel = panel;
	ws_panel_detect_presence();

	panel->bl_dev = ws_panel_create_backlight(panel);
	if (IS_ERR(panel->bl_dev)) {
		ret = PTR_ERR(panel->bl_dev);
		g_ws_panel = NULL;
		return ret;
	}

	dev_set_drvdata(dev, panel);
	if (panel->present) {
		backlight_update_status(panel->bl_dev);
	} else {
		panel->bl_dev->props.power = FB_BLANK_POWERDOWN;
		panel->bl_dev->props.brightness = 0;
	}

	ret = sysfs_create_group(&dev->kobj, &ws_panel_group);
	if (ret)
		dev_warn(dev, "failed to create sysfs group: %d\n", ret);

	ws_panel_debugfs_init(panel);

	return 0;
}

static void ws_panel_remove(struct i2c_client *i2c)
{
	struct ws_panel *panel = i2c_get_clientdata(i2c);
	struct device *dev = &i2c->dev;

	if (g_ws_panel == panel)
		g_ws_panel = NULL;

	ws_panel_debugfs_exit(panel);
	sysfs_remove_group(&dev->kobj, &ws_panel_group);
}

#ifdef CONFIG_PM_SLEEP
static int ws_panel_suspend(struct device *dev)
{
	struct i2c_client *i2c = to_i2c_client(dev);
	struct ws_panel *panel = i2c_get_clientdata(i2c);

	if (panel->bl_dev) {
		panel->bl_dev->props.power = FB_BLANK_POWERDOWN;
		backlight_update_status(panel->bl_dev);
	}

	return 0;
}

static int ws_panel_resume(struct device *dev)
{
	struct i2c_client *i2c = to_i2c_client(dev);
	struct ws_panel *panel = i2c_get_clientdata(i2c);

	if (panel->bl_dev) {
		panel->bl_dev->props.power = FB_BLANK_UNBLANK;
		backlight_update_status(panel->bl_dev);
	}

	return 0;
}
#endif

static const struct dev_pm_ops ws_panel_pm_ops = {
#ifdef CONFIG_PM_SLEEP
	.suspend = ws_panel_suspend,
	.resume = ws_panel_resume,
#endif
};

static const struct of_device_id ws_panel_of_ids[] = {
	{ .compatible = "waveshare-bl" },
	{ }
};
MODULE_DEVICE_TABLE(of, ws_panel_of_ids);

static const struct i2c_device_id ws_panel_ids[] = {
	{ "waveshare-bl", 0 },
	{ }
};
MODULE_DEVICE_TABLE(i2c, ws_panel_ids);

static struct i2c_driver ws_panel_driver = {
	.driver = {
		.name = "waveshare-bl",
		.of_match_table = ws_panel_of_ids,
		.pm = &ws_panel_pm_ops,
	},
	.probe = ws_panel_probe,
	.remove = ws_panel_remove,
	.id_table = ws_panel_ids,
};
module_i2c_driver(ws_panel_driver);

MODULE_AUTHOR("Dave Stevenson <dave.stevenson@raspberrypi.com>");
MODULE_DESCRIPTION("Waveshare BL driver");
MODULE_LICENSE("GPL");
