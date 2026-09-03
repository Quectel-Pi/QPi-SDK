// SPDX-License-Identifier: GPL-2.0
/*
 * Sony IMX477 camera sensor driver.
 *
 * The register tables and timing below are derived from the validated
 * imx477_cam0/imx477_cam1 sensor XML supplied with this board support package.
 */

#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/of_graph.h>
#include <linux/pm_runtime.h>
#include <linux/regulator/consumer.h>

#include <linux/rk-camera-module.h>
#include <media/media-entity.h>
#include <media/v4l2-async.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-fwnode.h>
#include <media/v4l2-subdev.h>

#define IMX477_NAME                    "imx477"
#define IMX477_CHIP_ID                  0x0477
#define IMX477_REG_CHIP_ID              0x0016
#define IMX477_REG_MODE_SELECT          0x0100
#define IMX477_REG_GROUP_HOLD           0x0104
#define IMX477_REG_EXPOSURE             0x0202
#define IMX477_REG_ANALOG_GAIN          0x0204
#define IMX477_REG_VTS                  0x0340
#define IMX477_XVCLK_FREQ               24000000
#define IMX477_LINK_FREQ                1050000000LL
#define IMX477_PIXEL_RATE               420000000LL
#define IMX477_VTS_MAX                  0xffff
#define IMX477_EXPOSURE_MIN             4
#define IMX477_EXPOSURE_MARGIN          61
#define IMX477_GAIN_MIN                 0
#define IMX477_GAIN_MAX                 240
#define IMX477_GAIN_DEFAULT             0

static const char * const imx477_supply_names[] = {
	"avdd",
	"dvdd",
	"dovdd",
};

struct imx477_reg {
	u16 address;
	u8 value;
};

struct imx477_mode {
	u32 width;
	u32 height;
	u32 hts;
	u32 vts;
	const struct imx477_reg *reg_list;
};

struct imx477 {
	struct i2c_client *client;
	struct clk *xvclk;
	struct regulator_bulk_data supplies[ARRAY_SIZE(imx477_supply_names)];
	struct gpio_desc *reset_gpio;
	struct gpio_desc *standby_gpio;
	struct mutex mutex;
	struct v4l2_subdev subdev;
	struct media_pad pad;
	struct v4l2_ctrl_handler ctrl_handler;
	struct v4l2_ctrl *exposure;
	struct v4l2_ctrl *analogue_gain;
	struct v4l2_ctrl *vblank;
	struct v4l2_ctrl *link_freq;
	struct v4l2_ctrl *pixel_rate;
	const struct imx477_mode *cur_mode;
	u32 module_index;
	const char *module_facing;
	const char *module_name;
	const char *lens_name;
	bool streaming;
};

#define to_imx477(sd) container_of(sd, struct imx477, subdev)

static const struct imx477_reg imx477_global_regs[] = {
	{ 0x0136, 0x18 }, { 0x0137, 0x00 }, { 0x0808, 0x02 },
	{ 0xE07A, 0x01 }, { 0xE000, 0x00 }, { 0x4AE9, 0x18 },
	{ 0x4AEA, 0x08 }, { 0xF61C, 0x04 }, { 0xF61E, 0x04 },
	{ 0x4AE9, 0x21 }, { 0x4AEA, 0x80 }, { 0x38A8, 0x1F },
	{ 0x38A9, 0xFF }, { 0x38AA, 0x1F }, { 0x38AB, 0xFF },
	{ 0x420B, 0x01 }, { 0x55D4, 0x00 }, { 0x55D5, 0x00 },
	{ 0x55D6, 0x07 }, { 0x55D7, 0xFF }, { 0x55E8, 0x07 },
	{ 0x55E9, 0xFF }, { 0x55EA, 0x00 }, { 0x55EB, 0x00 },
	{ 0x574C, 0x07 }, { 0x574D, 0xFF }, { 0x574E, 0x00 },
	{ 0x574F, 0x00 }, { 0x5754, 0x00 }, { 0x5755, 0x00 },
	{ 0x5756, 0x07 }, { 0x5757, 0xFF }, { 0x5973, 0x04 },
	{ 0x5974, 0x01 }, { 0x5D13, 0xC3 }, { 0x5D14, 0x58 },
	{ 0x5D15, 0xA3 }, { 0x5D16, 0x1D }, { 0x5D17, 0x65 },
	{ 0x5D18, 0x8C }, { 0x5D1A, 0x06 }, { 0x5D1B, 0xA9 },
	{ 0x5D1C, 0x45 }, { 0x5D1D, 0x3A }, { 0x5D1E, 0xAB },
	{ 0x5D1F, 0x15 }, { 0x5D21, 0x0E }, { 0x5D22, 0x52 },
	{ 0x5D23, 0xAA }, { 0x5D24, 0x7D }, { 0x5D25, 0x57 },
	{ 0x5D26, 0xA8 }, { 0x5D37, 0x5A }, { 0x5D38, 0x5A },
	{ 0x5D77, 0x7F }, { 0x7B7C, 0x00 }, { 0x7B7D, 0x00 },
	{ 0x8D1F, 0x00 }, { 0x8D27, 0x00 }, { 0x9004, 0x03 },
	{ 0x9200, 0x50 }, { 0x9201, 0x6C }, { 0x9202, 0x71 },
	{ 0x9203, 0x00 }, { 0x9204, 0x71 }, { 0x9205, 0x01 },
	{ 0x9371, 0x6A }, { 0x9373, 0x6A }, { 0x9375, 0x64 },
	{ 0x990C, 0x00 }, { 0x990D, 0x08 }, { 0x9956, 0x8C },
	{ 0x9957, 0x64 }, { 0x9958, 0x50 }, { 0x9A48, 0x06 },
	{ 0x9A49, 0x06 }, { 0x9A4A, 0x06 }, { 0x9A4B, 0x06 },
	{ 0x9A4C, 0x06 }, { 0x9A4D, 0x06 }, { 0xA001, 0x0A },
	{ 0xA003, 0x0A }, { 0xA005, 0x0A }, { 0xA006, 0x01 },
	{ 0xA007, 0xC0 }, { 0xA009, 0xC0 },
};

static const struct imx477_reg imx477_1080p30_regs[] = {
	{ 0x0112, 0x0A }, { 0x0113, 0x0A }, { 0x0114, 0x01 },
	{ 0x0342, 0x11 }, { 0x0343, 0xA0 }, { 0x0340, 0x0C },
	{ 0x0341, 0x1E }, { 0x0344, 0x00 }, { 0x0345, 0x1C },
	{ 0x0346, 0x00 }, { 0x0347, 0x14 }, { 0x0348, 0x0F },
	{ 0x0349, 0xBB }, { 0x034A, 0x0B }, { 0x034B, 0xCB },
	{ 0x0220, 0x00 }, { 0x0221, 0x11 }, { 0x0381, 0x01 },
	{ 0x0383, 0x01 }, { 0x0385, 0x01 }, { 0x0387, 0x01 },
	{ 0x0900, 0x00 }, { 0x0901, 0x11 }, { 0x0902, 0x02 },
	{ 0x3140, 0x02 }, { 0x3C00, 0x00 }, { 0x3C01, 0x03 },
	{ 0x3C02, 0xDC }, { 0x3F0D, 0x00 }, { 0x5748, 0x07 },
	{ 0x5749, 0xFF }, { 0x574A, 0x00 }, { 0x574B, 0x00 },
	{ 0x7B53, 0x01 }, { 0x9369, 0x5A }, { 0x936B, 0x55 },
	{ 0x936D, 0x28 }, { 0x9304, 0x00 }, { 0x9305, 0x00 },
	{ 0x9E9A, 0x2F }, { 0x9E9B, 0x2F }, { 0x9E9C, 0x2F },
	{ 0x9E9D, 0x00 }, { 0x9E9E, 0x00 }, { 0x9E9F, 0x00 },
	{ 0xA2A9, 0x60 }, { 0xA2B7, 0x00 }, { 0x0401, 0x02 },
	{ 0x0404, 0x00 }, { 0x0405, 0x21 }, { 0x0408, 0x00 },
	{ 0x0409, 0x14 }, { 0x040A, 0x01 }, { 0x040B, 0x82 },
	{ 0x040C, 0x0F }, { 0x040D, 0x78 }, { 0x040E, 0x08 },
	{ 0x040F, 0xB4 }, { 0x034C, 0x07 }, { 0x034D, 0x80 },
	{ 0x034E, 0x04 }, { 0x034F, 0x38 }, { 0x0301, 0x05 },
	{ 0x0303, 0x02 }, { 0x0305, 0x04 }, { 0x0306, 0x01 },
	{ 0x0307, 0x5E }, { 0x0309, 0x0A }, { 0x030B, 0x01 },
	{ 0x030D, 0x04 }, { 0x030E, 0x01 }, { 0x030F, 0x5E },
	{ 0x0310, 0x01 }, { 0x0820, 0x10 }, { 0x0821, 0x68 },
	{ 0x0822, 0x00 }, { 0x0823, 0x00 }, { 0x080A, 0x00 },
	{ 0x080B, 0xC7 }, { 0x080C, 0x00 }, { 0x080D, 0x87 },
	{ 0x080E, 0x00 }, { 0x080F, 0xDF }, { 0x0810, 0x00 },
	{ 0x0811, 0x97 }, { 0x0812, 0x00 }, { 0x0813, 0x8F },
	{ 0x0814, 0x00 }, { 0x0815, 0x7F }, { 0x0816, 0x02 },
	{ 0x0817, 0x27 }, { 0x0818, 0x00 }, { 0x0819, 0x6F },
	{ 0xE04C, 0x00 }, { 0xE04D, 0xDF }, { 0xE04E, 0x00 },
	{ 0xE04F, 0x1F }, { 0x3E20, 0x01 }, { 0x3E37, 0x00 },
	{ 0x3F50, 0x00 }, { 0x3F56, 0x00 }, { 0x3F57, 0x81 },
};

static const struct imx477_mode imx477_modes[] = {
	{
		.width = 1920,
		.height = 1080,
		.hts = 4512,
		.vts = 3102,
		.reg_list = imx477_1080p30_regs,
	},
};

static const s64 imx477_link_freq_menu[] = {
	IMX477_LINK_FREQ,
};

static int imx477_write_reg(struct imx477 *imx477, u16 address, u8 value)
{
	u8 buffer[] = { address >> 8, address & 0xff, value };
	int ret;

	ret = i2c_master_send(imx477->client, buffer, sizeof(buffer));
	return ret == sizeof(buffer) ? 0 : ret < 0 ? ret : -EIO;
}

static int imx477_read_reg(struct imx477 *imx477, u16 address, u16 *value)
{
	u8 buffer[] = { address >> 8, address & 0xff };
	struct i2c_msg messages[] = {
		{ .addr = imx477->client->addr, .flags = 0, .len = sizeof(buffer), .buf = buffer },
		{ .addr = imx477->client->addr, .flags = I2C_M_RD, .len = 2, .buf = buffer },
	};
	int ret;

	ret = i2c_transfer(imx477->client->adapter, messages, ARRAY_SIZE(messages));
	if (ret != ARRAY_SIZE(messages))
		return ret < 0 ? ret : -EIO;

	*value = (buffer[0] << 8) | buffer[1];
	return 0;
}

static int imx477_write_array(struct imx477 *imx477,
				      const struct imx477_reg *regs, u32 num_regs)
{
	u32 index;
	int ret;

	for (index = 0; index < num_regs; index++) {
		ret = imx477_write_reg(imx477, regs[index].address, regs[index].value);
		if (ret)
			return ret;
	}

	return 0;
}

static int imx477_set_exposure(struct imx477 *imx477, u32 exposure)
{
	int ret;

	ret = imx477_write_reg(imx477, IMX477_REG_GROUP_HOLD, 1);
	ret |= imx477_write_reg(imx477, IMX477_REG_EXPOSURE, exposure >> 8);
	ret |= imx477_write_reg(imx477, IMX477_REG_EXPOSURE + 1, exposure & 0xff);
	ret |= imx477_write_reg(imx477, IMX477_REG_GROUP_HOLD, 0);
	return ret;
}

static int imx477_set_gain(struct imx477 *imx477, u32 gain)
{
	int ret;

	ret = imx477_write_reg(imx477, IMX477_REG_GROUP_HOLD, 1);
	ret |= imx477_write_reg(imx477, IMX477_REG_ANALOG_GAIN, gain >> 8);
	ret |= imx477_write_reg(imx477, IMX477_REG_ANALOG_GAIN + 1, gain & 0xff);
	ret |= imx477_write_reg(imx477, IMX477_REG_GROUP_HOLD, 0);
	return ret;
}

static int imx477_set_vts(struct imx477 *imx477, u32 vts)
{
	int ret;

	ret = imx477_write_reg(imx477, IMX477_REG_GROUP_HOLD, 1);
	ret |= imx477_write_reg(imx477, IMX477_REG_VTS, vts >> 8);
	ret |= imx477_write_reg(imx477, IMX477_REG_VTS + 1, vts & 0xff);
	ret |= imx477_write_reg(imx477, IMX477_REG_GROUP_HOLD, 0);
	return ret;
}

static int imx477_set_ctrl(struct v4l2_ctrl *ctrl)
{
	struct imx477 *imx477 = container_of(ctrl->handler, struct imx477,
					      ctrl_handler);
	u32 vts = imx477->cur_mode->vts + imx477->vblank->val;
	int ret = 0;

	if (!imx477->streaming)
		return 0;

	switch (ctrl->id) {
	case V4L2_CID_EXPOSURE:
		ret = imx477_set_exposure(imx477, ctrl->val);
		break;
	case V4L2_CID_ANALOGUE_GAIN:
		ret = imx477_set_gain(imx477, ctrl->val);
		break;
	case V4L2_CID_VBLANK:
		__v4l2_ctrl_modify_range(imx477->exposure, IMX477_EXPOSURE_MIN,
			vts - IMX477_EXPOSURE_MARGIN, 1, imx477->exposure->default_value);
		ret = imx477_set_vts(imx477, vts);
		break;
	default:
		break;
	}

	return ret;
}

static const struct v4l2_ctrl_ops imx477_ctrl_ops = {
	.s_ctrl = imx477_set_ctrl,
};

static int imx477_start_stream(struct imx477 *imx477)
{
	const struct imx477_mode *mode = imx477->cur_mode;
	int ret;

	ret = imx477_write_array(imx477, imx477_global_regs,
				 ARRAY_SIZE(imx477_global_regs));
	if (ret)
		return ret;

	ret = imx477_write_array(imx477, mode->reg_list,
				 ARRAY_SIZE(imx477_1080p30_regs));
	if (ret)
		return ret;

	ret = imx477_set_vts(imx477, mode->vts + imx477->vblank->val);
	if (ret)
		return ret;
	ret = imx477_set_exposure(imx477, imx477->exposure->val);
	if (ret)
		return ret;
	ret = imx477_set_gain(imx477, imx477->analogue_gain->val);
	if (ret)
		return ret;

	return imx477_write_reg(imx477, IMX477_REG_MODE_SELECT, 1);
}

static int imx477_stop_stream(struct imx477 *imx477)
{
	return imx477_write_reg(imx477, IMX477_REG_MODE_SELECT, 0);
}

static int imx477_s_stream(struct v4l2_subdev *sd, int on)
{
	struct imx477 *imx477 = to_imx477(sd);
	int ret = 0;

	mutex_lock(&imx477->mutex);
	if (imx477->streaming == !!on)
		goto unlock;

	if (on) {
		ret = pm_runtime_resume_and_get(&imx477->client->dev);
		if (ret < 0)
			goto unlock;
		ret = imx477_start_stream(imx477);
		if (ret) {
			pm_runtime_put(&imx477->client->dev);
			goto unlock;
		}
	} else {
		ret = imx477_stop_stream(imx477);
		pm_runtime_put(&imx477->client->dev);
	}

	imx477->streaming = !!on;
unlock:
	mutex_unlock(&imx477->mutex);
	return ret;
}

static void imx477_fill_format(struct v4l2_mbus_framefmt *format)
{
	format->width = imx477_modes[0].width;
	format->height = imx477_modes[0].height;
	format->code = MEDIA_BUS_FMT_SRGGB10_1X10;
	format->field = V4L2_FIELD_NONE;
	format->colorspace = V4L2_COLORSPACE_RAW;
	format->ycbcr_enc = V4L2_YCBCR_ENC_DEFAULT;
	format->quantization = V4L2_QUANTIZATION_FULL_RANGE;
	format->xfer_func = V4L2_XFER_FUNC_NONE;
}

static int imx477_get_fmt(struct v4l2_subdev *sd,
			   struct v4l2_subdev_state *state,
			   struct v4l2_subdev_format *format)
{
	imx477_fill_format(&format->format);
	return 0;
}

static int imx477_set_fmt(struct v4l2_subdev *sd,
			   struct v4l2_subdev_state *state,
			   struct v4l2_subdev_format *format)
{
	struct imx477 *imx477 = to_imx477(sd);

	imx477_fill_format(&format->format);
	if (format->which == V4L2_SUBDEV_FORMAT_ACTIVE)
		imx477->cur_mode = &imx477_modes[0];
	return 0;
}

static int imx477_enum_mbus_code(struct v4l2_subdev *sd,
				  struct v4l2_subdev_state *state,
				  struct v4l2_subdev_mbus_code_enum *code)
{
	if (code->index)
		return -EINVAL;
	code->code = MEDIA_BUS_FMT_SRGGB10_1X10;
	return 0;
}

static int imx477_enum_frame_size(struct v4l2_subdev *sd,
				  struct v4l2_subdev_state *state,
				  struct v4l2_subdev_frame_size_enum *fse)
{
	if (fse->index || fse->code != MEDIA_BUS_FMT_SRGGB10_1X10)
		return -EINVAL;
	fse->min_width = imx477_modes[0].width;
	fse->max_width = imx477_modes[0].width;
	fse->min_height = imx477_modes[0].height;
	fse->max_height = imx477_modes[0].height;
	return 0;
}

static int imx477_enum_frame_interval(struct v4l2_subdev *sd,
				      struct v4l2_subdev_state *state,
				      struct v4l2_subdev_frame_interval_enum *fie)
{
	if (fie->index >= ARRAY_SIZE(imx477_modes))
		return -EINVAL;
	fie->code = MEDIA_BUS_FMT_SRGGB10_1X10;
	fie->width = imx477_modes[fie->index].width;
	fie->height = imx477_modes[fie->index].height;
	fie->interval.numerator = imx477_modes[fie->index].hts *
				  imx477_modes[fie->index].vts;
	fie->interval.denominator = IMX477_PIXEL_RATE;
	return 0;
}

static int imx477_g_frame_interval(struct v4l2_subdev *sd,
				    struct v4l2_subdev_frame_interval *fi)
{
	struct imx477 *imx477 = to_imx477(sd);

	fi->interval.numerator = imx477->cur_mode->hts *
				 imx477->cur_mode->vts;
	fi->interval.denominator = IMX477_PIXEL_RATE;
	return 0;
}

static int imx477_g_mbus_config(struct v4l2_subdev *sd, unsigned int pad_id,
				 struct v4l2_mbus_config *config)
{
	if (pad_id != 0)
		return -EINVAL;
	config->type = V4L2_MBUS_CSI2_DPHY;
	config->bus.mipi_csi2.num_data_lanes = 2;
	return 0;
}

static long imx477_ioctl(struct v4l2_subdev *sd, unsigned int cmd, void *arg)
{
	struct imx477 *imx477 = to_imx477(sd);
	struct rkmodule_inf *inf = arg;

	if (cmd != RKMODULE_GET_MODULE_INFO)
		return -ENOIOCTLCMD;

	strscpy(inf->base.sensor, IMX477_NAME, sizeof(inf->base.sensor));
	strscpy(inf->base.module, imx477->module_name, sizeof(inf->base.module));
	strscpy(inf->base.lens, imx477->lens_name, sizeof(inf->base.lens));
	return 0;
}

static const struct v4l2_subdev_core_ops imx477_core_ops = {
	.ioctl = imx477_ioctl,
};

static const struct v4l2_subdev_video_ops imx477_video_ops = {
	.s_stream = imx477_s_stream,
	.g_frame_interval = imx477_g_frame_interval,
};

static const struct v4l2_subdev_pad_ops imx477_pad_ops = {
	.enum_mbus_code = imx477_enum_mbus_code,
	.enum_frame_size = imx477_enum_frame_size,
	.enum_frame_interval = imx477_enum_frame_interval,
	.get_fmt = imx477_get_fmt,
	.set_fmt = imx477_set_fmt,
	.get_mbus_config = imx477_g_mbus_config,
};

static const struct v4l2_subdev_ops imx477_subdev_ops = {
	.core = &imx477_core_ops,
	.video = &imx477_video_ops,
	.pad = &imx477_pad_ops,
};

static int imx477_power_on(struct imx477 *imx477)
{
	int ret;

	ret = regulator_bulk_enable(ARRAY_SIZE(imx477->supplies), imx477->supplies);
	if (ret)
		return ret;
	ret = clk_set_rate(imx477->xvclk, IMX477_XVCLK_FREQ);
	if (ret)
		goto disable_regulators;
	ret = clk_prepare_enable(imx477->xvclk);
	if (ret)
		goto disable_regulators;

	gpiod_set_value_cansleep(imx477->standby_gpio, 1);
	gpiod_set_value_cansleep(imx477->reset_gpio, 0);
	usleep_range(1000, 2000);
	gpiod_set_value_cansleep(imx477->reset_gpio, 1);
	msleep(500);
	return 0;

disable_regulators:
	regulator_bulk_disable(ARRAY_SIZE(imx477->supplies), imx477->supplies);
	return ret;
}

static int imx477_power_off(struct imx477 *imx477)
{
	gpiod_set_value_cansleep(imx477->reset_gpio, 0);
	gpiod_set_value_cansleep(imx477->standby_gpio, 0);
	clk_disable_unprepare(imx477->xvclk);
	return regulator_bulk_disable(ARRAY_SIZE(imx477->supplies), imx477->supplies);
}

static int imx477_runtime_resume(struct device *dev)
{
	return imx477_power_on(to_imx477(i2c_get_clientdata(to_i2c_client(dev))));
}

static int imx477_runtime_suspend(struct device *dev)
{
	return imx477_power_off(to_imx477(i2c_get_clientdata(to_i2c_client(dev))));
}

static const struct dev_pm_ops imx477_pm_ops = {
	SET_RUNTIME_PM_OPS(imx477_runtime_suspend, imx477_runtime_resume, NULL)
};

static int imx477_check_chip_id(struct imx477 *imx477)
{
	u16 chip_id;
	int ret;

	ret = imx477_read_reg(imx477, IMX477_REG_CHIP_ID, &chip_id);
	if (ret)
		return ret;
	if (chip_id != IMX477_CHIP_ID) {
		dev_err(&imx477->client->dev, "unexpected chip id 0x%04x\n", chip_id);
		return -ENODEV;
	}
	return 0;
}

static int imx477_probe(struct i2c_client *client,
			 const struct i2c_device_id *id)
{
	struct device *dev = &client->dev;
	struct imx477 *imx477;
	struct v4l2_subdev *sd;
	u32 index;
	int ret;

	imx477 = devm_kzalloc(dev, sizeof(*imx477), GFP_KERNEL);
	if (!imx477)
		return -ENOMEM;

	imx477->client = client;
	imx477->cur_mode = &imx477_modes[0];
	ret = of_property_read_u32(dev->of_node, RKMODULE_CAMERA_MODULE_INDEX, &index);
	ret |= of_property_read_string(dev->of_node, RKMODULE_CAMERA_MODULE_FACING,
					       &imx477->module_facing);
	ret |= of_property_read_string(dev->of_node, RKMODULE_CAMERA_MODULE_NAME,
					       &imx477->module_name);
	ret |= of_property_read_string(dev->of_node, RKMODULE_CAMERA_LENS_NAME,
					       &imx477->lens_name);
	if (ret)
		return dev_err_probe(dev, -EINVAL, "missing module information\n");
	imx477->module_index = index;

	imx477->xvclk = devm_clk_get(dev, "xvclk");
	if (IS_ERR(imx477->xvclk))
		return dev_err_probe(dev, PTR_ERR(imx477->xvclk), "failed to get xvclk\n");
	imx477->reset_gpio = devm_gpiod_get(dev, "reset", GPIOD_OUT_LOW);
	if (IS_ERR(imx477->reset_gpio))
		return dev_err_probe(dev, PTR_ERR(imx477->reset_gpio), "failed to get reset GPIO\n");
	imx477->standby_gpio = devm_gpiod_get(dev, "pwdn", GPIOD_OUT_LOW);
	if (IS_ERR(imx477->standby_gpio))
		return dev_err_probe(dev, PTR_ERR(imx477->standby_gpio), "failed to get standby GPIO\n");

	for (index = 0; index < ARRAY_SIZE(imx477->supplies); index++)
		imx477->supplies[index].supply = imx477_supply_names[index];
	ret = devm_regulator_bulk_get(dev, ARRAY_SIZE(imx477->supplies), imx477->supplies);
	if (ret)
		return dev_err_probe(dev, ret, "failed to get supplies\n");

	mutex_init(&imx477->mutex);
	v4l2_ctrl_handler_init(&imx477->ctrl_handler, 5);
	imx477->ctrl_handler.lock = &imx477->mutex;
	v4l2_i2c_subdev_init(&imx477->subdev, client, &imx477_subdev_ops);
	sd = &imx477->subdev;
	sd->flags |= V4L2_SUBDEV_FL_HAS_DEVNODE;
	sd->entity.function = MEDIA_ENT_F_CAM_SENSOR;

	imx477->link_freq = v4l2_ctrl_new_int_menu(&imx477->ctrl_handler, NULL,
		V4L2_CID_LINK_FREQ, 0, 0, imx477_link_freq_menu);
	imx477->pixel_rate = v4l2_ctrl_new_std(&imx477->ctrl_handler, NULL,
		V4L2_CID_PIXEL_RATE, IMX477_PIXEL_RATE, IMX477_PIXEL_RATE, 1,
		IMX477_PIXEL_RATE);
	imx477->vblank = v4l2_ctrl_new_std(&imx477->ctrl_handler, &imx477_ctrl_ops,
		V4L2_CID_VBLANK, 0, IMX477_VTS_MAX - imx477->cur_mode->vts, 1, 0);
	imx477->exposure = v4l2_ctrl_new_std(&imx477->ctrl_handler, &imx477_ctrl_ops,
		V4L2_CID_EXPOSURE, IMX477_EXPOSURE_MIN,
		imx477->cur_mode->vts - IMX477_EXPOSURE_MARGIN, 1,
		min_t(u32, 0x0c00, imx477->cur_mode->vts - IMX477_EXPOSURE_MARGIN));
	imx477->analogue_gain = v4l2_ctrl_new_std(&imx477->ctrl_handler,
		&imx477_ctrl_ops, V4L2_CID_ANALOGUE_GAIN, IMX477_GAIN_MIN,
		IMX477_GAIN_MAX, 1, IMX477_GAIN_DEFAULT);
	if (imx477->ctrl_handler.error) {
		ret = imx477->ctrl_handler.error;
		goto err_mutex;
	}
	sd->ctrl_handler = &imx477->ctrl_handler;

	ret = media_entity_pads_init(&sd->entity, 1, &imx477->pad);
	if (ret)
		goto err_controls;
	imx477->pad.flags = MEDIA_PAD_FL_SOURCE;

	ret = imx477_power_on(imx477);
	if (ret)
		goto err_entity;
	ret = imx477_check_chip_id(imx477);
	imx477_power_off(imx477);
	if (ret)
		goto err_entity;

	snprintf(sd->name, sizeof(sd->name), "m%02d_%s_%s %s", imx477->module_index,
		 imx477->module_facing, IMX477_NAME, dev_name(dev));
	ret = v4l2_async_register_subdev_sensor(sd);
	if (ret)
		goto err_entity;

	pm_runtime_set_suspended(dev);
	pm_runtime_enable(dev);
	return 0;

err_entity:
	media_entity_cleanup(&sd->entity);
err_controls:
	v4l2_ctrl_handler_free(&imx477->ctrl_handler);
err_mutex:
	mutex_destroy(&imx477->mutex);
	return ret;
}

static void imx477_remove(struct i2c_client *client)
{
	struct imx477 *imx477 = to_imx477(i2c_get_clientdata(client));

	pm_runtime_disable(&client->dev);
	v4l2_async_unregister_subdev(&imx477->subdev);
	media_entity_cleanup(&imx477->subdev.entity);
	v4l2_ctrl_handler_free(&imx477->ctrl_handler);
	mutex_destroy(&imx477->mutex);
}

static const struct of_device_id imx477_of_match[] = {
	{ .compatible = "sony,imx477" },
	{},
};
MODULE_DEVICE_TABLE(of, imx477_of_match);

static const struct i2c_device_id imx477_i2c_ids[] = {
	{ "imx477", 0 },
	{},
};
MODULE_DEVICE_TABLE(i2c, imx477_i2c_ids);

static struct i2c_driver imx477_i2c_driver = {
	.driver = {
		.name = IMX477_NAME,
		.of_match_table = imx477_of_match,
		.pm = &imx477_pm_ops,
	},
	.probe = imx477_probe,
	.remove = imx477_remove,
	.id_table = imx477_i2c_ids,
};
module_i2c_driver(imx477_i2c_driver);

MODULE_DESCRIPTION("Sony IMX477 camera sensor driver");
MODULE_LICENSE("GPL");