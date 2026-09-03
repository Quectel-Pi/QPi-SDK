// SPDX-License-Identifier: GPL-2.0
/*
 * gc13a0c camera driver
 *
 * Copyright (C) 2022 Rockchip Electronics Co., Ltd.
 *
 * V0.0X01.0X00 first version.
 * V0.0X01.0X01
 * 1.add flip and mirror support
 * 2.fix stream on sequential
 *
 */

// #define DEBUG
#include <linux/clk.h>
#include <linux/device.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/pm_runtime.h>
#include <linux/of.h>
#include <linux/of_graph.h>
#include <linux/regulator/consumer.h>
#include <linux/sysfs.h>
#include <linux/slab.h>
#include <linux/version.h>
#include <linux/compat.h>
#include <linux/rk-camera-module.h>
#include <media/media-entity.h>
#include <media/v4l2-async.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-device.h>
#include <media/v4l2-event.h>
#include <media/v4l2-fwnode.h>
#include <media/v4l2-image-sizes.h>
#include <media/v4l2-mediabus.h>
#include <media/v4l2-subdev.h>
#include <linux/pinctrl/consumer.h>
#include <linux/slab.h>
#include <linux/of_gpio.h>
#define USE_OLD_GPIO_API 1

#define DRIVER_VERSION			KERNEL_VERSION(0, 0x01, 0x01)

#ifndef V4L2_CID_DIGITAL_GAIN
#define V4L2_CID_DIGITAL_GAIN		V4L2_CID_GAIN
#endif

#define gc13a0c_LINK_FREQ_600MHZ	600000000U
#define gc13a0c_LINK_FREQ_284MHZ	284000000U
/* pixel rate = link frequency * 2 * lanes / BITS_PER_SAMPLE */
#define gc13a0c_PIXEL_RATE		(gc13a0c_LINK_FREQ_600MHZ * 2LL * 4LL / 10LL)
#define gc13a0c_XVCLK_FREQ		24000000

#define CHIP_ID				0x13a0
#define gc13a0c_REG_CHIP_ID_H		0x03f0
#define gc13a0c_REG_CHIP_ID_L		0x03f1

#define gc13a0c_REG_CTRL_MODE		0x0100
#define gc13a0c_MODE_SW_STANDBY	0x0
#define gc13a0c_MODE_STREAMING		0x01
#define gc13a0c_REG_STREAM_ON		0x3C1E

#define gc13a0c_REG_EXPOSURE		0x0202
#define	gc13a0c_EXPOSURE_MIN		1
#define	gc13a0c_EXPOSURE_STEP		1
#define gc13a0c_VTS_MAX		0xfffe

#define gc13a0c_REG_ANALOG_GAIN	0x0204
#define gc13a0c_GAIN_MIN		0x400
#define gc13a0c_GAIN_MAX		0x4000
#define gc13a0c_GAIN_STEP		1
#define gc13a0c_GAIN_DEFAULT		0x800

#define gc13a0c_REG_TEST_PATTERN	0x0601
#define	gc13a0c_TEST_PATTERN_ENABLE	0x80
#define	gc13a0c_TEST_PATTERN_DISABLE	0x0

#define gc13a0c_REG_VTS		0x0340

#define REG_NULL			0xFFFF

#define gc13a0c_REG_VALUE_08BIT	1
#define gc13a0c_REG_VALUE_16BIT	2
#define gc13a0c_REG_VALUE_24BIT	3

#define gc13a0c_LANES			4
#define gc13a0c_BITS_PER_SAMPLE	10

#define gc13a0c_CHIP_REVISION_REG	0x0002

#define OF_CAMERA_PINCTRL_STATE_DEFAULT	"rockchip,camera_default"
#define OF_CAMERA_PINCTRL_STATE_SLEEP	"rockchip,camera_sleep"

#define gc13a0c_NAME			"gc13a0c"

// #define gc13a0c_MIRROR
// #define gc13a0c_FLIP
// #define gc13a0c_FLIP_MIRROR
#ifdef gc13a0c_MIRROR
#define gc13a0c_MEDIA_BUS_FMT		MEDIA_BUS_FMT_SRGGB10_1X10
#elif defined gc13a0c_FLIP
#define gc13a0c_MEDIA_BUS_FMT		MEDIA_BUS_FMT_SBGGR10_1X10
#elif defined gc13a0c_FLIP_MIRROR
#define gc13a0c_MEDIA_BUS_FMT		MEDIA_BUS_FMT_SGBRG10_1X10
#else
#define gc13a0c_MEDIA_BUS_FMT		MEDIA_BUS_FMT_SGRBG10_1X10
#endif

// static const char * const gc13a0c_supply_names[] = {
// 	"avdd",		/* Analog power */
// 	"iovdd",	/* Digital I/O power */
// 	"dvdd",		/* Digital core power */
// };

// #define gc13a0c_NUM_SUPPLIES ARRAY_SIZE(gc13a0c_supply_names)

struct regval {
	u16 addr;
	u16 val;
};

struct gc13a0c_mode {
	u32 width;
	u32 height;
	struct v4l2_fract max_fps;
	u32 hts_def;
	u32 vts_def;
	u32 exp_def;
	u32 link_freq_idx;
	u32 bpp;
	const struct regval *reg_list;
};

struct gc13a0c {
	struct i2c_client	*client;
	struct clk		*xvclk;
	// struct gpio_desc	*power_gpio;
	// struct gpio_desc	*reset_gpio;
	// struct gpio_desc	*pwdn_gpio;
	struct regulator	*avdd;	/* Analog power */
	struct regulator	*iovdd;	/* Digital I/O power */
	struct regulator	*dvdd;	/* Digital core powe */
	//struct regulator_bulk_data supplies[gc13a0c_NUM_SUPPLIES];

	struct pinctrl		*pinctrl;
	struct pinctrl_state	*pins_default;
	struct pinctrl_state	*pins_sleep;

	struct v4l2_subdev	subdev;
	struct media_pad	pad;
	struct v4l2_ctrl_handler ctrl_handler;
	struct v4l2_ctrl	*exposure;
	struct v4l2_ctrl	*anal_gain;
	struct v4l2_ctrl	*digi_gain;
	struct v4l2_ctrl	*hblank;
	struct v4l2_ctrl	*vblank;
	struct v4l2_ctrl	*pixel_rate;
	struct v4l2_ctrl	*link_freq;
	struct v4l2_ctrl	*test_pattern;
	struct mutex		mutex;
	bool			streaming;
	bool			power_on;
	const struct gc13a0c_mode *cur_mode;
	u32			module_index;
	const char		*module_facing;
	const char		*module_name;
	const char		*len_name;

	int power_gpio;
	int reset_gpio;
	int pwdn_gpio;
	int avdd_gpio;
	int iovdd_gpio;
	int dvdd_gpio;

};

#define to_gc13a0c(sd) container_of(sd, struct gc13a0c, subdev)

static const struct regval gc13a0c_4208x3120_30fps_regs[] = {
{0x031c, 0x20}, 
{0x0337, 0x05}, 
{0x0335, 0x01}, 
{0x0253, 0x04}, 
{0x0254, 0x84}, 
{0x0336, 0x7e}, 
{0x0321, 0x10}, 
{0x031a, 0x00}, 
{0x0315, 0xd7}, 
{0x0c0d, 0x34}, 
{0x0c0c, 0x4f}, 
{0x0c0e, 0x20}, 
{0x0314, 0x11}, 
{0x03a2, 0x0f}, 
{0x0334, 0x40}, 
{0x0c0d, 0xb4}, 
{0x031c, 0x9f}, 
{0x0c08, 0x18}, 
{0x0059, 0x11}, 
{0x0057, 0x08}, 
{0x0084, 0x30}, 
{0x0087, 0x51}, 
{0x05a0, 0x02}, 
{0x0074, 0x0b}, 
{0x0218, 0x00}, 
{0x0241, 0x88}, 
{0x0101, 0x00}, 
{0x00a1, 0x0d}, 
{0x0c17, 0x12}, 
{0x0c16, 0x24}, 
{0x0c15, 0x04}, 
{0x0c57, 0x12}, 
{0x0c56, 0x24}, 
{0x0c55, 0x04}, 
{0x0346, 0x00}, 
{0x0347, 0x04}, 
{0x0348, 0x10}, 
{0x0349, 0x80}, 
{0x034a, 0x0c}, 
{0x034b, 0x40},
{0x0244, 0x17}, 
{0x0245, 0x17}, 
{0x0202, 0x0b}, 
{0x0203, 0x64}, 
{0x0342, 0x07}, 
{0x0343, 0x9e}, 
{0x0340, 0x25}, 
{0x0341, 0xe0}, 
{0x0210, 0x53}, 
{0x0225, 0x04}, 
{0x0226, 0x00}, 
{0x0227, 0x30}, 
{0x0219, 0x05}, 
{0x0e0a, 0x01}, 
{0x0e0b, 0x01}, 
{0x0220, 0x08}, 
{0x0e22, 0x04}, 
{0x0e23, 0x08}, 
{0x0e01, 0x64}, 
{0x0e15, 0x58}, 
{0x0e16, 0x84}, 
{0x0e0c, 0x38}, 
{0x0e28, 0x38}, 
{0x0e49, 0x6a}, 
{0x0e18, 0x68}, 
{0x0e17, 0x66}, 
{0x0e1a, 0x48}, 
{0x0e19, 0x46}, 
{0x0e2b, 0x64}, 
{0x0e35, 0x80}, 
{0x0e36, 0x06}, 
{0x0e33, 0x4c}, 
{0x025c, 0x40}, 
{0x0e37, 0x30}, 
{0x0e38, 0x30}, 
{0x0c47, 0x3e}, 
{0x02b8, 0x04}, 
{0x02b5, 0x74}, 
{0x02b6, 0x87}, 
{0x0e4f, 0x00}, 
{0x0e44, 0x00}, 
{0x0e42, 0x0f},
{0x0e43, 0x80}, 
{0x0c41, 0x0b}, 
{0x0c45, 0x9f}, 
{0x0c46, 0xfd}, 
{0x0c09, 0x24}, 
{0x0c07, 0x14}, 
{0x0c05, 0xff}, 
{0x02b7, 0x09}, 
{0x031c, 0x80},
{0x03fe, 0x10}, 
{0x03fe, 0x00},
{0x031c, 0x9f},
{0x03fe, 0x00},
{0x03fe, 0x00},
{0x03fe, 0x00},
{0x03fe, 0x00},
{0x031c, 0x80},
{0x03fe, 0x10}, 
{0x03fe, 0x00},
{0x031c, 0x9f},
{0x0360, 0x01}, 
{0x0360, 0x00},
{0x0316, 0x01}, 
{0x0a67, 0x80}, 
{0x0313, 0x00}, 
{0x0a65, 0x05}, 
{0x0a68, 0x11}, 
{0x0a58, 0x00}, 
{0x0a4f, 0x00}, 
{0x00a4, 0x00}, 
{0x00a5, 0x01}, 
{0x00a2, 0x00}, 
{0x00a3, 0x00}, 
{0x00ab, 0x00}, 
{0x00ac, 0x00}, 
{0x00a7, 0x0c}, 
{0x00a8, 0x40}, 
{0x00a9, 0x10}, 
{0x00aa, 0x80}, 
{0x0a8a, 0x00}, 
{0x0a8b, 0xe0}, 
{0x0a8c, 0x1b}, 
{0x0a8d, 0xf0}, 
{0x0a90, 0x0a}, 
{0x0a91, 0x19}, 
{0x0a92, 0xf8}, 
{0x0a71, 0x52}, 
{0x0a72, 0x22}, 
{0x0a73, 0x64}, 
{0x0a75, 0x41}, 
{0x0a70, 0x07}, 
{0x0313, 0x80}, 
{0x0311, 0xb0}, 
{0x02db, 0x01},
{0x0b00, 0x0f}, 
{0x0b01, 0xa2}, 
{0x0b02, 0x03}, 
{0x0b03, 0x07}, 
{0x0b04, 0x11},
{0x0b05, 0x14},
{0x0b06, 0x03},
{0x0b07, 0x07},
{0x0b08, 0xb4},
{0x0b09, 0x0d},
{0x0b0a, 0x0c},
{0x0b0b, 0x07},
{0x0b0c, 0x40},
{0x0b0d, 0x34},
{0x0b0e, 0x03},
{0x0b0f, 0x07},
{0x0b10, 0x80},
{0x0b11, 0x1c},
{0x0b12, 0x03},
{0x0b13, 0x07},
{0x0b14, 0x10},
{0x0b15, 0xfe},
{0x0b16, 0x03},
{0x0b17, 0x07},	
{0x0b18, 0x00},
{0x0b19, 0xfe},
{0x0b1a, 0x03},
{0x0b1b, 0x07},	
{0x0b1c, 0x9f},
{0x0b1d, 0x1c},
{0x0b1e, 0x03},
{0x0b1f, 0x07},	
{0x0b20, 0x00},
{0x0b21, 0xfe},
{0x0b22, 0x03},
{0x0b23, 0x07},	
{0x0b24, 0x00},
{0x0b25, 0xfe},
{0x0b26, 0x03},
{0x0b27, 0x07},	
{0x0b28, 0x80},
{0x0b29, 0x1c},
{0x0b2a, 0x03},
{0x0b2b, 0x07},	
{0x0b2c, 0x10},
{0x0b2d, 0xfe},
{0x0b2e, 0x03},
{0x0b2f, 0x07},		
{0x0b30, 0x00},
{0x0b31, 0xfe},
{0x0b32, 0x03},
{0x0b33, 0x07},	
{0x0b34, 0x9f},
{0x0b35, 0x1c},
{0x0b36, 0x03},
{0x0b37, 0x07},		
{0x0b38, 0x44},
{0x0b39, 0x80},
{0x0b3a, 0x01},
{0x0b3b, 0x07},	
{0x0b3c, 0x99},
{0x0b3d, 0x02},
{0x0b3e, 0x01},
{0x0b3f, 0x07},		
{0x0b40, 0xd9},
{0x0b41, 0x02},
{0x0b42, 0x01},
{0x0b43, 0x07},
{0x0b44, 0x00},
{0x0b45, 0xfe},
{0x0b46, 0x03},
{0x0b47, 0x07},
{0x0b48, 0x06},
{0x0b49, 0x14},
{0x0b4a, 0x03},
{0x0b4b, 0x07}, 	
{0x0b4c, 0x34},
{0x0b4d, 0x0d},
{0x0b4e, 0x0c},
{0x0b4f, 0x07}, 
{0x0b50, 0x00},
{0x0b51, 0x34},
{0x0b52, 0x03},
{0x0b53, 0x07}, 	
{0x0b54, 0xe0},
{0x0b55, 0x1c},
{0x0b56, 0x03},
{0x0b57, 0x07}, 	
{0x0b58, 0x04},
{0x0b59, 0x80},
{0x0b5a, 0x01}, 
{0x0b5b, 0x07}, 
{0x0b5c, 0x07},
{0x0b5d, 0xa2},
{0x0b5e, 0x03},
{0x0b5f, 0x07}, 
{0x0aab, 0x09}, 
{0x0aa8, 0xb0}, 
{0x0264, 0x00}, 
{0x0265, 0x04}, 
{0x0266, 0x1c}, 
{0x0267, 0x80}, 
{0x0aa9, 0x10}, 
{0x0aaa, 0x18}, 
{0x05a0, 0x82}, 
{0x05ac, 0x00}, 
{0x05ad, 0x01}, 
{0x05ae, 0x00}, 
{0x059a, 0x00}, 
{0x059b, 0x00}, 
{0x059c, 0x01}, 
{0x0597, 0x0d}, 
{0x0598, 0x00}, 
{0x05ab, 0x09}, 
{0x05a4, 0x01}, 
{0x05a3, 0x05}, 
{0x0800, 0x0b}, 
{0x0801, 0x16}, 
{0x0802, 0x2c}, 
{0x0803, 0x3e}, 
{0x0804, 0x0e}, 
{0x0805, 0x33}, 
{0x0806, 0x31}, 
{0x0807, 0x25}, 
{0x0808, 0x1b}, 
{0x0809, 0x14}, 
{0x080a, 0x10}, 
{0x080b, 0x00},
{0x080c, 0x00},
{0x080d, 0x01}, 
{0x080e, 0x00},				
{0x080f, 0x01}, 
{0x0810, 0x00},
{0x0811, 0x00}, 
{0x0812, 0x02}, 	
{0x0813, 0x01}, 
{0x0814, 0x6b}, 
{0x0815, 0x00}, 
{0x0816, 0x03}, 	
{0x0817, 0x01}, 
{0x0818, 0xfa}, 
{0x0819, 0x00}, 
{0x081a, 0x04}, 	
{0x081b, 0x02}, 
{0x081c, 0xd2}, 
{0x081d, 0x00}, 
{0x081e, 0x05}, 
{0x081f, 0x03}, 
{0x0820, 0xf1}, 
{0x0821, 0x00}, 
{0x0822, 0x06}, 	
{0x0823, 0x05}, 
{0x0824, 0x8a}, 
{0x0825, 0x09}, 
{0x0826, 0x36},	
{0x0827, 0x07}, 
{0x0828, 0xe4}, 
{0x0829, 0x10}, 
{0x082a, 0x06}, 	
{0x082b, 0x0b}, 
{0x082c, 0x10}, 
{0x082d, 0x14}, 
{0x082e, 0xa6},	
{0x082f, 0x0f}, 
{0x0830, 0x80},
{0x0831, 0x17},
{0x0832, 0xf6},
{0x05ac, 0x01}, 
{0x05a0, 0xc2}, 
{0x0207, 0xc4}, 
{0x0089, 0x03}, 
{0x0080, 0xd0}, 
{0x009a, 0x00}, 
{0x0040, 0x22}, 
{0x0047, 0xf0}, 
{0x0048, 0x0f}, 
{0x004b, 0x0f}, 
{0x004c, 0x00}, 
{0x0046, 0x0a}, 
{0x0041, 0x20}, 
{0x0043, 0x50}, 
{0x0044, 0x00}, 
{0x005b, 0x02}, 
{0x004f, 0x0a}, 
{0x0050, 0x40}, 
{0x0051, 0x20}, 
{0x0052, 0x18}, 
{0x0082, 0x00}, 
{0x009b, 0x40}, 
{0x0208, 0x01}, 
{0x0209, 0x5a},
{0x0204, 0x04}, 
{0x0205, 0x00},
{0x0096, 0x81}, 
{0x0097, 0x08}, 
{0x0098, 0x87}, 
{0x00c0, 0x00}, 
{0x00c1, 0x80}, 
{0x00c2, 0x11}, 
{0x0460, 0x04}, 
{0x0462, 0x08},
{0x0464, 0x0a},
{0x0466, 0x0a},
{0x0468, 0x12},
{0x046a, 0x12},
{0x046c, 0x10},
{0x046e, 0x0c},
{0x0461, 0x03}, 
{0x0463, 0x03},
{0x0465, 0x03},
{0x0467, 0x03},
{0x0469, 0x04},
{0x046b, 0x04},
{0x046d, 0x04},
{0x046f, 0x04},
{0x0470, 0x04}, 
{0x0472, 0x10},
{0x0474, 0x38},
{0x0476, 0x38},
{0x0478, 0x20}, 
{0x047a, 0x30},
{0x047c, 0x38},
{0x047e, 0x60},
{0x0471, 0x05}, 
{0x0473, 0x05},
{0x0475, 0x05},
{0x0477, 0x05},
{0x0479, 0x04},
{0x047b, 0x04},
{0x047d, 0x04},
{0x047f, 0x04},
{0x0351, 0x00}, 
{0x0352, 0x08},
{0x0353, 0x00}, 
{0x0354, 0x08},
{0x034c, 0x10}, 
{0x034d, 0x70}, 
{0x034e, 0x0c}, 
{0x034f, 0x30},
{0x0a70, 0x11}, 
{0x0313, 0x80}, 
{0x00e6, 0x11}, 
{0x00e0, 0x20}, 
{0x00e1, 0x10}, 
{0x00e2, 0x20}, 
{0x00e3, 0x0c}, 
{0x00e4, 0x30}, 
{0x00e5, 0x08}, 
{0x00a0, 0x31}, 
{0x00c3, 0x10}, 
{0x0114, 0x03}, 
{0x0115, 0x30}, 
{0x0180, 0x44}, 
{0x0181, 0xf0}, 
{0x0184, 0x5d}, 
{0x0185, 0x40}, 
{0x0121, 0x0e}, 
{0x0122, 0x0c}, 
{0x0123, 0x28}, 
{0x0124, 0x02}, 
{0x0125, 0x10}, 
{0x0126, 0x0d}, 
{0x0129, 0x0c}, 
{0x012a, 0x12}, 
{0x012b, 0x0e}, 
{0x00a4, 0x80}, 
{0x0a70, 0x00}, 
{0x0316, 0x00}, 
{0x0a67, 0x00}, 
{0x0084, 0x10}, 
{0x0102, 0x09}, 
{0x0103, 0x04}, 
{0x011b, 0x12}, 
{0x011c, 0x12}, 
{0x0100, 0x01},
{REG_NULL, 0x00},
};

static const struct regval gc13a0c_2104x1560_30fps_regs[] = {
// #ifdef gc13a0c_MIRROR
// 	{0x0100, 0x0001},
// #elif defined gc13a0c_FLIP
// 	{0x0100, 0x0002},
// #elif defined gc13a0c_FLIP_MIRROR
// 	{0x0100, 0x0003},
// #else
// 	{0x0100, 0x0000},
// #endif
// 	{0x0000, 0x0050},
// 	{0x0000, 0x30C6},
// 	{0x0A02, 0x3400},
// 	{0x3084, 0x1314},
// 	{0x3266, 0x0001},
// 	{0x3242, 0x2020},
// 	{0x306A, 0x2F4C},
// 	{0x306C, 0xCA01},
// 	{0x307A, 0x0D20},
// 	{0x309E, 0x002D},
// 	{0x3072, 0x0013},
// 	{0x3074, 0x0977},
// 	{0x3076, 0x9411},
// 	{0x3024, 0x0016},
// 	{0x3070, 0x3D00},
// 	{0x3002, 0x0E00},
// 	{0x3006, 0x1000},
// 	{0x300A, 0x0C00},
// 	{0x3010, 0x0400},
// 	{0x3018, 0xC500},
// 	{0x303A, 0x0204},
// 	{0x3452, 0x0001},
// 	{0x3454, 0x0001},
// 	{0x3456, 0x0001},
// 	{0x3458, 0x0001},
// 	{0x345a, 0x0002},
// 	{0x345C, 0x0014},
// 	{0x345E, 0x0002},
// 	{0x3460, 0x0014},
// 	{0x3464, 0x0006},
// 	{0x3466, 0x0012},
// 	{0x3468, 0x0012},
// 	{0x346A, 0x0012},
// 	{0x346C, 0x0012},
// 	{0x346E, 0x0012},
// 	{0x3470, 0x0012},
// 	{0x3472, 0x0008},
// 	{0x3474, 0x0004},
// 	{0x3476, 0x0044},
// 	{0x3478, 0x0004},
// 	{0x347A, 0x0044},
// 	{0x347E, 0x0006},
// 	{0x3480, 0x0010},
// 	{0x3482, 0x0010},
// 	{0x3484, 0x0010},
// 	{0x3486, 0x0010},
// 	{0x3488, 0x0010},
// 	{0x348A, 0x0010},
// 	{0x348E, 0x000C},
// 	{0x3490, 0x004C},
// 	{0x3492, 0x000C},
// 	{0x3494, 0x004C},
// 	{0x3496, 0x0020},
// 	{0x3498, 0x0006},
// 	{0x349A, 0x0008},
// 	{0x349C, 0x0008},
// 	{0x349E, 0x0008},
// 	{0x34A0, 0x0008},
// 	{0x34A2, 0x0008},
// 	{0x34A4, 0x0008},
// 	{0x34A8, 0x001A},
// 	{0x34AA, 0x002A},
// 	{0x34AC, 0x001A},
// 	{0x34AE, 0x002A},
// 	{0x34B0, 0x0080},
// 	{0x34B2, 0x0006},
// 	{0x32A2, 0x0000},
// 	{0x32A4, 0x0000},
// 	{0x32A6, 0x0000},
// 	{0x32A8, 0x0000},
// 	{0x3066, 0x7E00},
// 	{0x3004, 0x0800},
// 	//mode setting
// 	{0x0344, 0x0008},
// 	{0x0346, 0x0008},
// 	{0x0348, 0x1077},
// 	{0x034A, 0x0C37},
// 	{0x034C, 0x0838},
// 	{0x034E, 0x0618},
// 	{0x0900, 0x0122},
// 	{0x0380, 0x0001},
// 	{0x0382, 0x0001},
// 	{0x0384, 0x0001},
// 	{0x0386, 0x0003},
// 	{0x0114, 0x0330},
// 	{0x0110, 0x0002},
// 	{0x0136, 0x1800},
// 	{0x0304, 0x0004},
// 	{0x0306, 0x0078},
// 	{0x3C1E, 0x0000},
// 	{0x030C, 0x0003},
// 	{0x030E, 0x0047},
// 	{0x3C16, 0x0001},
// 	{0x0300, 0x0006},
// 	{0x0342, 0x1320},
// 	{0x0340, 0x0CBC},
// 	{0x38C4, 0x0004},
// 	{0x38D8, 0x0011},
// 	{0x38DA, 0x0005},
// 	{0x38DC, 0x0005},
// 	{0x38C2, 0x0005},
// 	{0x38C0, 0x0004},
// 	{0x38D6, 0x0004},
// 	{0x38D4, 0x0004},
// 	{0x38B0, 0x0007},
// 	{0x3932, 0x1000},
// 	{0x3934, 0x0180},
// 	{0x3938, 0x000C},
// 	{0x0820, 0x0238},
// 	{0x380C, 0x0049},
// 	{0x3064, 0xFFCF},
// 	{0x309C, 0x0640},
// 	{0x3090, 0x8000},
// 	{0x3238, 0x000B},
// 	{0x314A, 0x5F02},
// 	{0x3300, 0x0000},
// 	{0x3400, 0x0000},
// 	{0x3402, 0x4E46},
// 	{0x32B2, 0x0008},
// 	{0x32B4, 0x0008},
// 	{0x32B6, 0x0008},
// 	{0x32B8, 0x0008},
// 	{0x3C34, 0x0048},
// 	{0x3C36, 0x3000},
// 	{0x3C38, 0x0020},
// 	{0x393E, 0x4000},
// 	{0x303A, 0x0204},
// 	{0x3034, 0x4B01},
// 	{0x3036, 0x0029},
// 	{0x3032, 0x4800},
// 	{0x320E, 0x049E},
// 	{REG_NULL, 0x0000},
};

static const struct gc13a0c_mode supported_modes[] = {
	{
		.width = 4208,
		.height = 3120,
		.max_fps = {
			.numerator = 10000,
			.denominator = 300000,
		},
		.exp_def = 0x0cb0,
		.hts_def = 0x1320,
		.vts_def = 0x0cbc,
		.bpp = 10,
		.reg_list = gc13a0c_4208x3120_30fps_regs,
		.link_freq_idx = 0,
	},
	// {
	// 	.width = 2104,
	// 	.height = 1560,
	// 	.max_fps = {
	// 		.numerator = 10000,
	// 		.denominator = 300000,
	// 	},
	// 	.exp_def = 0x0cb0,
	// 	.hts_def = 0x1320,
	// 	.vts_def = 0x0cbc,
	// 	.bpp = 10,
	// 	.reg_list = gc13a0c_2104x1560_30fps_regs,
	// 	.link_freq_idx = 1,
	// },
};

static const s64 link_freq_items[] = {
	gc13a0c_LINK_FREQ_600MHZ,
	gc13a0c_LINK_FREQ_284MHZ,
};

static const char * const gc13a0c_test_pattern_menu[] = {
	"Disabled",
	"Vertical Color Bar Type 1",
	"Vertical Color Bar Type 2",
	"Vertical Color Bar Type 3"
};

/* Write registers up to 4 at a time */
static int gc13a0c_write_reg(struct i2c_client *client, u16 reg,
			     u32 len, u32 val)
{
	struct i2c_msg msg;
	u8 buf[3];
	int ret;

	buf[0] = reg >> 8;
	buf[1] = reg & 0xff;
	buf[2] = val;

	msg.addr = client->addr;
	msg.flags = client->flags;
	msg.buf = buf;
	msg.len = sizeof(buf);

	ret = i2c_transfer(client->adapter, &msg, 1);
	if (ret >= 0)
		return 0;

	dev_err(&client->dev,
		"gc13a0c write reg(0x%x val:0x%x) failed !\n", reg, val);

	return ret;
}

static int gc13a0c_write_array(struct i2c_client *client,
			       const struct regval *regs)
{
	u32 i;
	int ret = 0;

	for (i = 0; ret == 0 && regs[i].addr != REG_NULL; i++)
		ret = gc13a0c_write_reg(client, regs[i].addr,
					gc13a0c_REG_VALUE_16BIT,
					regs[i].val);

	return ret;
}

/* Read registers up to 4 at a time */
static int gc13a0c_read_reg(struct i2c_client *client, u16 reg,
			    unsigned int len, u32 *val)
{
	struct i2c_msg msgs[2];
	u8 *data_be_p;
	__be32 data_be = 0;
	__be16 reg_addr_be = cpu_to_be16(reg);
	int ret;

	if (len > 4 || !len)
		return -EINVAL;

	data_be_p = (u8 *)&data_be;
	/* Write register address */
	msgs[0].addr = client->addr;
	msgs[0].flags = 0;
	msgs[0].len = 2;
	msgs[0].buf = (u8 *)&reg_addr_be;

	/* Read data from register */
	msgs[1].addr = client->addr;
	msgs[1].flags = I2C_M_RD;
	msgs[1].len = len;
	msgs[1].buf = &data_be_p[4 - len];

	ret = i2c_transfer(client->adapter, msgs, ARRAY_SIZE(msgs));
	if (ret != ARRAY_SIZE(msgs))
		return -EIO;

	*val = be32_to_cpu(data_be);

	return 0;
}

static int gc13a0c_get_reso_dist(const struct gc13a0c_mode *mode,
				 struct v4l2_mbus_framefmt *framefmt)
{
	return abs(mode->width - framefmt->width) +
	       abs(mode->height - framefmt->height);
}

static const struct gc13a0c_mode *
gc13a0c_find_best_fit(struct v4l2_subdev_format *fmt)
{
	struct v4l2_mbus_framefmt *framefmt = &fmt->format;
	int dist;
	int cur_best_fit = 0;
	int cur_best_fit_dist = -1;
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(supported_modes); i++) {
		dist = gc13a0c_get_reso_dist(&supported_modes[i], framefmt);
		if (cur_best_fit_dist == -1 || dist < cur_best_fit_dist) {
			cur_best_fit_dist = dist;
			cur_best_fit = i;
		}
	}

	return &supported_modes[cur_best_fit];
}

static int gc13a0c_set_fmt(struct v4l2_subdev *sd,
			   struct v4l2_subdev_state *sd_state,
			  struct v4l2_subdev_format *fmt)
{
	struct gc13a0c *gc13a0c = to_gc13a0c(sd);
	const struct gc13a0c_mode *mode;
	s64 h_blank, vblank_def;
	u64 pixel_rate = 0;
	u32 lane_num = gc13a0c_LANES;

	mutex_lock(&gc13a0c->mutex);

	mode = gc13a0c_find_best_fit(fmt);
	fmt->format.code = gc13a0c_MEDIA_BUS_FMT;
	fmt->format.width = mode->width;
	fmt->format.height = mode->height;
	fmt->format.field = V4L2_FIELD_NONE;
	if (fmt->which == V4L2_SUBDEV_FORMAT_TRY) {
#ifdef CONFIG_VIDEO_V4L2_SUBDEV_API
		*v4l2_subdev_get_try_format(sd, sd_state, fmt->pad) = fmt->format;
#else
		mutex_unlock(&gc13a0c->mutex);
		return -ENOTTY;
#endif
	} else {
		gc13a0c->cur_mode = mode;
		h_blank = mode->hts_def - mode->width;
		__v4l2_ctrl_modify_range(gc13a0c->hblank, h_blank,
					 h_blank, 1, h_blank);
		vblank_def = mode->vts_def - mode->height;
		__v4l2_ctrl_modify_range(gc13a0c->vblank, vblank_def,
					 gc13a0c_VTS_MAX - mode->height,
					 1, vblank_def);
		pixel_rate = (u32)link_freq_items[mode->link_freq_idx] / mode->bpp * 2 * lane_num;

		__v4l2_ctrl_s_ctrl_int64(gc13a0c->pixel_rate,
					 pixel_rate);
		__v4l2_ctrl_s_ctrl(gc13a0c->link_freq,
				   mode->link_freq_idx);
	}

	mutex_unlock(&gc13a0c->mutex);

	return 0;
}

static int gc13a0c_get_fmt(struct v4l2_subdev *sd,
			   struct v4l2_subdev_state *sd_state,
			   struct v4l2_subdev_format *fmt)
{
	struct gc13a0c *gc13a0c = to_gc13a0c(sd);
	const struct gc13a0c_mode *mode = gc13a0c->cur_mode;

	mutex_lock(&gc13a0c->mutex);
	if (fmt->which == V4L2_SUBDEV_FORMAT_TRY) {
#ifdef CONFIG_VIDEO_V4L2_SUBDEV_API
		fmt->format = *v4l2_subdev_get_try_format(sd, sd_state, fmt->pad);
#else
		mutex_unlock(&gc13a0c->mutex);
		return -ENOTTY;
#endif
	} else {
		fmt->format.width = mode->width;
		fmt->format.height = mode->height;
		fmt->format.code = gc13a0c_MEDIA_BUS_FMT;
		fmt->format.field = V4L2_FIELD_NONE;
	}
	mutex_unlock(&gc13a0c->mutex);

	return 0;
}

static int gc13a0c_enum_mbus_code(struct v4l2_subdev *sd,
				  struct v4l2_subdev_state *sd_state,
				  struct v4l2_subdev_mbus_code_enum *code)
{
	if (code->index != 0)
		return -EINVAL;
	code->code = gc13a0c_MEDIA_BUS_FMT;

	return 0;
}

static int gc13a0c_enum_frame_sizes(struct v4l2_subdev *sd,
				    struct v4l2_subdev_state *sd_state,
				   struct v4l2_subdev_frame_size_enum *fse)
{
	if (fse->index >= ARRAY_SIZE(supported_modes))
		return -EINVAL;

	if (fse->code != gc13a0c_MEDIA_BUS_FMT)
		return -EINVAL;

	fse->min_width  = supported_modes[fse->index].width;
	fse->max_width  = supported_modes[fse->index].width;
	fse->max_height = supported_modes[fse->index].height;
	fse->min_height = supported_modes[fse->index].height;

	return 0;
}

static int gc13a0c_enable_test_pattern(struct gc13a0c *gc13a0c, u32 pattern)
{
	u32 val;

	if (pattern)
		val = (pattern - 1) | gc13a0c_TEST_PATTERN_ENABLE;
	else
		val = gc13a0c_TEST_PATTERN_DISABLE;

	return gc13a0c_write_reg(gc13a0c->client,
				 gc13a0c_REG_TEST_PATTERN,
				 gc13a0c_REG_VALUE_08BIT,
				 val);
}

static int gc13a0c_g_frame_interval(struct v4l2_subdev *sd,
				    struct v4l2_subdev_frame_interval *fi)
{
	struct gc13a0c *gc13a0c = to_gc13a0c(sd);
	const struct gc13a0c_mode *mode = gc13a0c->cur_mode;

	mutex_lock(&gc13a0c->mutex);
	fi->interval = mode->max_fps;
	mutex_unlock(&gc13a0c->mutex);

	return 0;
}

static void gc13a0c_get_module_inf(struct gc13a0c *gc13a0c,
				   struct rkmodule_inf *inf)
{
	memset(inf, 0, sizeof(*inf));
	strscpy(inf->base.sensor, gc13a0c_NAME, sizeof(inf->base.sensor));
	strscpy(inf->base.module, gc13a0c->module_name,
		sizeof(inf->base.module));
	strscpy(inf->base.lens, gc13a0c->len_name, sizeof(inf->base.lens));
}

static long gc13a0c_ioctl(struct v4l2_subdev *sd, unsigned int cmd, void *arg)
{
	struct gc13a0c *gc13a0c = to_gc13a0c(sd);
	long ret = 0;
	u32 stream = 0;

	switch (cmd) {
	case RKMODULE_GET_MODULE_INFO:
		gc13a0c_get_module_inf(gc13a0c, (struct rkmodule_inf *)arg);
		break;
	case RKMODULE_SET_QUICK_STREAM:

		stream = *((u32 *)arg);

		if (stream)
			ret = gc13a0c_write_reg(gc13a0c->client,
				 gc13a0c_REG_CTRL_MODE,
				 gc13a0c_REG_VALUE_08BIT,
				 gc13a0c_MODE_STREAMING);
		else
			ret = gc13a0c_write_reg(gc13a0c->client,
				 gc13a0c_REG_CTRL_MODE,
				 gc13a0c_REG_VALUE_08BIT,
				 gc13a0c_MODE_SW_STANDBY);
		break;
	default:
		ret = -ENOIOCTLCMD;
		break;
	}

	return ret;
}

#ifdef CONFIG_COMPAT
static long gc13a0c_compat_ioctl32(struct v4l2_subdev *sd,
				   unsigned int cmd, unsigned long arg)
{
	void __user *up = compat_ptr(arg);
	struct rkmodule_inf *inf;
	struct rkmodule_awb_cfg *cfg;
	long ret = 0;
	u32 stream = 0;

	switch (cmd) {
	case RKMODULE_GET_MODULE_INFO:
		inf = kzalloc(sizeof(*inf), GFP_KERNEL);
		if (!inf) {
			ret = -ENOMEM;
			return ret;
		}

		ret = gc13a0c_ioctl(sd, cmd, inf);
		if (!ret) {
			ret = copy_to_user(up, inf, sizeof(*inf));
			if (ret)
				ret = -EFAULT;
		}
		kfree(inf);
		break;
	case RKMODULE_AWB_CFG:
		cfg = kzalloc(sizeof(*cfg), GFP_KERNEL);
		if (!cfg) {
			ret = -ENOMEM;
			return ret;
		}

		ret = copy_from_user(cfg, up, sizeof(*cfg));
		if (!ret)
			ret = gc13a0c_ioctl(sd, cmd, cfg);
		else
			ret = -EFAULT;
		kfree(cfg);
		break;
	case RKMODULE_SET_QUICK_STREAM:
		ret = copy_from_user(&stream, up, sizeof(u32));
		if (!ret)
			ret = gc13a0c_ioctl(sd, cmd, &stream);
		else
			ret = -EFAULT;
		break;
	default:
		ret = -ENOIOCTLCMD;
		break;
	}

	return ret;
}
#endif

static int __gc13a0c_start_stream(struct gc13a0c *gc13a0c)
{
	int ret;

	ret = gc13a0c_write_array(gc13a0c->client, gc13a0c->cur_mode->reg_list);
	if (ret)
		return ret;

	/* In case these controls are set before streaming */
	mutex_unlock(&gc13a0c->mutex);
	ret = v4l2_ctrl_handler_setup(&gc13a0c->ctrl_handler);
	mutex_lock(&gc13a0c->mutex);
	if (ret)
		return ret;

	gc13a0c_write_reg(gc13a0c->client,
				 gc13a0c_REG_STREAM_ON,
				 gc13a0c_REG_VALUE_08BIT,
				 gc13a0c_MODE_STREAMING);
	gc13a0c_write_reg(gc13a0c->client,
				 gc13a0c_REG_CTRL_MODE,
				 gc13a0c_REG_VALUE_08BIT,
				 gc13a0c_MODE_STREAMING);
	gc13a0c_write_reg(gc13a0c->client,
				 gc13a0c_REG_STREAM_ON,
				 gc13a0c_REG_VALUE_08BIT,
				 gc13a0c_MODE_SW_STANDBY);

	return 0;
}

static int __gc13a0c_stop_stream(struct gc13a0c *gc13a0c)
{
	return gc13a0c_write_reg(gc13a0c->client,
				 gc13a0c_REG_CTRL_MODE,
				 gc13a0c_REG_VALUE_08BIT,
				 gc13a0c_MODE_SW_STANDBY);
}

static int gc13a0c_s_stream(struct v4l2_subdev *sd, int on)
{
	struct gc13a0c *gc13a0c = to_gc13a0c(sd);
	struct i2c_client *client = gc13a0c->client;
	int ret = 0;

	dev_info(&client->dev, "%s: on: %d, %dx%d@%d\n", __func__, on,
				gc13a0c->cur_mode->width,
				gc13a0c->cur_mode->height,
		DIV_ROUND_CLOSEST(gc13a0c->cur_mode->max_fps.denominator,
				  gc13a0c->cur_mode->max_fps.numerator));

	mutex_lock(&gc13a0c->mutex);
	on = !!on;
	if (on == gc13a0c->streaming)
		goto unlock_and_return;

	if (on) {
		ret = pm_runtime_get_sync(&client->dev);
		if (ret < 0) {
			pm_runtime_put_noidle(&client->dev);
			goto unlock_and_return;
		}

		ret = __gc13a0c_start_stream(gc13a0c);
		if (ret) {
			v4l2_err(sd, "start stream failed while write regs\n");
			pm_runtime_put(&client->dev);
			goto unlock_and_return;
		}
	} else {
		__gc13a0c_stop_stream(gc13a0c);
		pm_runtime_put(&client->dev);
	}

	gc13a0c->streaming = on;

unlock_and_return:
	mutex_unlock(&gc13a0c->mutex);

	return ret;
}

static int gc13a0c_s_power(struct v4l2_subdev *sd, int on)
{
	struct gc13a0c *gc13a0c = to_gc13a0c(sd);
	struct i2c_client *client = gc13a0c->client;
	int ret = 0;

	mutex_lock(&gc13a0c->mutex);

	/* If the power state is not modified - no work to do. */
	if (gc13a0c->power_on == !!on)
		goto unlock_and_return;

	if (on) {
		ret = pm_runtime_get_sync(&client->dev);
		if (ret < 0) {
			pm_runtime_put_noidle(&client->dev);
			goto unlock_and_return;
		}

		gc13a0c->power_on = true;
	} else {
		pm_runtime_put(&client->dev);
		gc13a0c->power_on = false;
	}

unlock_and_return:
	mutex_unlock(&gc13a0c->mutex);

	return ret;
}

/* Calculate the delay in us by clock rate and clock cycles */
static inline u32 gc13a0c_cal_delay(u32 cycles)
{
	return DIV_ROUND_UP(cycles, gc13a0c_XVCLK_FREQ / 1000 / 1000);
}

static int __gc13a0c_power_on(struct gc13a0c *gc13a0c)
{
	int ret;
	u32 delay_us;
	struct device *dev = &gc13a0c->client->dev;
	struct device_node *node = dev->of_node;

    dev_info(dev, "%s(%d) enter!\n", __func__, __LINE__);

	if (!IS_ERR_OR_NULL(gc13a0c->pins_default)) {
		ret = pinctrl_select_state(gc13a0c->pinctrl,
					   gc13a0c->pins_default);
		if (ret < 0)
			dev_err(dev, "could not set pins\n");
	}
	ret = clk_set_rate(gc13a0c->xvclk, gc13a0c_XVCLK_FREQ);
	if (ret < 0)
		dev_warn(dev, "Failed to set xvclk rate (24MHz)\n");
	if (clk_get_rate(gc13a0c->xvclk) != gc13a0c_XVCLK_FREQ)
		dev_warn(dev, "xvclk mismatched, modes are based on 24MHz\n");
	ret = clk_prepare_enable(gc13a0c->xvclk);
	if (ret < 0) {
		dev_err(dev, "Failed to enable xvclk\n");
		return ret;
	}
//add factory compatible
#if USE_OLD_GPIO_API
	
//防止重复申请
if ((gc13a0c->reset_gpio <= 0) || (gc13a0c->pwdn_gpio <= 0))
{
	dev_err(dev, "admin: power on requset \n");
	//reset
	gc13a0c->reset_gpio = of_get_named_gpio(node, "reset-gpios", 0);
	if (gc13a0c->reset_gpio < 0) {
		dev_err(dev, "%s:admin : Can not read property reset \n", __func__);
		return -1;
	}
	ret = gpio_request(gc13a0c->reset_gpio, "reset-gpios");
	if (ret) {
		gc13a0c->reset_gpio = -1;
		dev_err(dev, "admin: Unable to request reset-gpios [%d]\n", gc13a0c->reset_gpio);
	}else{
		ret = gpio_direction_output(gc13a0c->reset_gpio, 0);
	}

	//pwdn
	gc13a0c->pwdn_gpio = of_get_named_gpio(node, "pwdn-gpios", 0);
	if (gc13a0c->pwdn_gpio < 0) {
		dev_err(dev, "%s:admin : Can not read property pwdn-gpios \n", __func__);
		return -1;
	}
	ret = gpio_request(gc13a0c->pwdn_gpio, "pwdn-gpios");
	if (ret) {
		gc13a0c->pwdn_gpio = -1;
		dev_err(dev, "admin: Unable to request pwdn-gpios [%d]\n", gc13a0c->pwdn_gpio);
	}else{
		ret = gpio_direction_output(gc13a0c->pwdn_gpio, 0);
	}
}
#endif

	gpio_direction_output(gc13a0c->iovdd_gpio, 0);
    gpio_direction_output(gc13a0c->dvdd_gpio, 0);
    gpio_direction_output(gc13a0c->avdd_gpio, 0);
	gpio_direction_output(gc13a0c->pwdn_gpio, 0);
	gpio_direction_output(gc13a0c->reset_gpio, 0);


	clk_set_rate(gc13a0c->xvclk, 0);
	usleep_range(1000, 1100);

	clk_set_rate(gc13a0c->xvclk, gc13a0c_XVCLK_FREQ);
	usleep_range(1 * 1000, 2 * 1000);

    ret = regulator_enable(gc13a0c->avdd);
    if (ret) {
        dev_err(dev, "Failed to enable avdd regulator\n");
        goto disable_clk;
    }

	usleep_range(5 * 1000, 6 * 1000);

    ret = regulator_enable(gc13a0c->dvdd);
    if (ret) {
        dev_err(dev, "Failed to enable dvdd regulator\n");
        goto disable_avdd;
    }

	usleep_range(5 * 1000, 6 * 1000);

    ret = regulator_enable(gc13a0c->iovdd);
    if (ret) {
        dev_err(dev, "Failed to enable iovdd regulator\n");
        goto disable_dvdd;
    }

	usleep_range(5 * 1000, 6 * 1000);

    gpio_direction_output(gc13a0c->reset_gpio, 1);
    usleep_range(5 * 1000, 6 * 1000);
	gpio_direction_output(gc13a0c->pwdn_gpio, 1);

	usleep_range(5*1000, 6*1000);

	/* 8192 cycles prior to first SCCB transaction */
	delay_us = gc13a0c_cal_delay(8192);
	usleep_range(delay_us, delay_us * 2);

	return 0;

	disable_dvdd:
    regulator_disable(gc13a0c->dvdd);
	disable_avdd:
    regulator_disable(gc13a0c->avdd);
	disable_clk:
    clk_disable_unprepare(gc13a0c->xvclk);
	return ret;
}

static void __gc13a0c_power_off(struct gc13a0c *gc13a0c)
{
	int ret;
	struct device *dev = &gc13a0c->client->dev;
    //return;
    gpio_direction_output(gc13a0c->reset_gpio, 0);
	gpio_direction_output(gc13a0c->pwdn_gpio, 0);
	

	clk_disable_unprepare(gc13a0c->xvclk);
	if (!IS_ERR_OR_NULL(gc13a0c->pins_sleep)) {
		ret = pinctrl_select_state(gc13a0c->pinctrl,
					   gc13a0c->pins_sleep);
		if (ret < 0)
			dev_dbg(dev, "could not set pins\n");
	}

    if (gc13a0c->iovdd)
        regulator_disable(gc13a0c->iovdd);
    
    if (gc13a0c->dvdd)
        regulator_disable(gc13a0c->dvdd);
    
    if (gc13a0c->avdd)
        regulator_disable(gc13a0c->avdd);
}

static int __maybe_unused gc13a0c_runtime_resume(struct device *dev)
{
	struct i2c_client *client = to_i2c_client(dev);
	struct v4l2_subdev *sd = i2c_get_clientdata(client);
	struct gc13a0c *gc13a0c = to_gc13a0c(sd);

	return __gc13a0c_power_on(gc13a0c);
}

static int __maybe_unused gc13a0c_runtime_suspend(struct device *dev)
{
	struct i2c_client *client = to_i2c_client(dev);
	struct v4l2_subdev *sd = i2c_get_clientdata(client);
	struct gc13a0c *gc13a0c = to_gc13a0c(sd);

	__gc13a0c_power_off(gc13a0c);

	return 0;
}

#ifdef CONFIG_VIDEO_V4L2_SUBDEV_API
static int gc13a0c_open(struct v4l2_subdev *sd, struct v4l2_subdev_fh *fh)
{
	struct gc13a0c *gc13a0c = to_gc13a0c(sd);
	struct v4l2_mbus_framefmt *try_fmt =
				v4l2_subdev_get_try_format(sd, fh->state, 0);
	const struct gc13a0c_mode *def_mode = &supported_modes[0];

	mutex_lock(&gc13a0c->mutex);
	/* Initialize try_fmt */
	try_fmt->width = def_mode->width;
	try_fmt->height = def_mode->height;
	try_fmt->code = gc13a0c_MEDIA_BUS_FMT;
	try_fmt->field = V4L2_FIELD_NONE;

	mutex_unlock(&gc13a0c->mutex);
	/* No crop or compose */

	return 0;
}
#endif

static int gc13a0c_enum_frame_interval(struct v4l2_subdev *sd,
				       struct v4l2_subdev_state *sd_state,
				       struct v4l2_subdev_frame_interval_enum *fie)
{
	if (fie->index >= ARRAY_SIZE(supported_modes))
		return -EINVAL;

	fie->code = gc13a0c_MEDIA_BUS_FMT;

	fie->width = supported_modes[fie->index].width;
	fie->height = supported_modes[fie->index].height;
	fie->interval = supported_modes[fie->index].max_fps;

	return 0;
}

static int gc13a0c_g_mbus_config(struct v4l2_subdev *sd, unsigned int pad,
				struct v4l2_mbus_config *config)
{
	config->type = V4L2_MBUS_CSI2_DPHY;
	config->bus.mipi_csi2.num_data_lanes = gc13a0c_LANES;

	return 0;
}

#define CROP_START(SRC, DST) (((SRC) - (DST)) / 2 / 4 * 4)
#define DST_WIDTH_2096 2096
#define DST_HEIGHT_1560 1560

static int gc13a0c_get_selection(struct v4l2_subdev *sd,
				struct v4l2_subdev_state *sd_state,
				struct v4l2_subdev_selection *sel)
{
	struct gc13a0c *gc13a0c = to_gc13a0c(sd);

	if (sel->target == V4L2_SEL_TGT_CROP_BOUNDS) {
		if (gc13a0c->cur_mode->width == 2104) {
			sel->r.left = CROP_START(gc13a0c->cur_mode->width, DST_WIDTH_2096);
			sel->r.width = DST_WIDTH_2096;
			sel->r.top = CROP_START(gc13a0c->cur_mode->height, DST_HEIGHT_1560);
			sel->r.height = DST_HEIGHT_1560;
		} else {
			sel->r.left = CROP_START(gc13a0c->cur_mode->width,
							gc13a0c->cur_mode->width);
			sel->r.width = gc13a0c->cur_mode->width;
			sel->r.top = CROP_START(gc13a0c->cur_mode->height,
							gc13a0c->cur_mode->height);
			sel->r.height = gc13a0c->cur_mode->height;
		}
		return 0;
	}

	return -EINVAL;
}

static const struct dev_pm_ops gc13a0c_pm_ops = {
	SET_RUNTIME_PM_OPS(gc13a0c_runtime_suspend,
			   gc13a0c_runtime_resume, NULL)
};

#ifdef CONFIG_VIDEO_V4L2_SUBDEV_API
static const struct v4l2_subdev_internal_ops gc13a0c_internal_ops = {
	.open = gc13a0c_open,
};
#endif

static const struct v4l2_subdev_core_ops gc13a0c_core_ops = {
	.s_power = gc13a0c_s_power,
	.ioctl = gc13a0c_ioctl,
#ifdef CONFIG_COMPAT
	.compat_ioctl32 = gc13a0c_compat_ioctl32,
#endif
};

static const struct v4l2_subdev_video_ops gc13a0c_video_ops = {
	.s_stream = gc13a0c_s_stream,
	.g_frame_interval = gc13a0c_g_frame_interval,
};

static const struct v4l2_subdev_pad_ops gc13a0c_pad_ops = {
	.enum_mbus_code = gc13a0c_enum_mbus_code,
	.enum_frame_size = gc13a0c_enum_frame_sizes,
	.enum_frame_interval = gc13a0c_enum_frame_interval,
	.get_fmt = gc13a0c_get_fmt,
	.set_fmt = gc13a0c_set_fmt,
	.get_selection = gc13a0c_get_selection,
	.get_mbus_config = gc13a0c_g_mbus_config,
};

static const struct v4l2_subdev_ops gc13a0c_subdev_ops = {
	.core	= &gc13a0c_core_ops,
	.video	= &gc13a0c_video_ops,
	.pad	= &gc13a0c_pad_ops,
};

static int gc13a0c_set_ctrl(struct v4l2_ctrl *ctrl)
{
	struct gc13a0c *gc13a0c = container_of(ctrl->handler,
					     struct gc13a0c, ctrl_handler);
	struct i2c_client *client = gc13a0c->client;
	s64 max;
	int ret = 0;

	/* Propagate change of current control to all related controls */
	switch (ctrl->id) {
	case V4L2_CID_VBLANK:
		/* Update max exposure while meeting expected vblanking */
		max = gc13a0c->cur_mode->height + ctrl->val - 4;
		__v4l2_ctrl_modify_range(gc13a0c->exposure,
					 gc13a0c->exposure->minimum, max,
					 gc13a0c->exposure->step,
					 gc13a0c->exposure->default_value);
		break;
	}

	if (!pm_runtime_get_if_in_use(&client->dev))
		return 0;

	switch (ctrl->id) {
	case V4L2_CID_EXPOSURE:
		/* 4 least significant bits of expsoure are fractional part */
		ret = gc13a0c_write_reg(gc13a0c->client,
					gc13a0c_REG_EXPOSURE,
					gc13a0c_REG_VALUE_16BIT,
					ctrl->val);
		break;
	case V4L2_CID_ANALOGUE_GAIN:
		ret = gc13a0c_write_reg(gc13a0c->client,
					gc13a0c_REG_ANALOG_GAIN,
					gc13a0c_REG_VALUE_16BIT,
					ctrl->val);
		break;
	case V4L2_CID_VBLANK:
		ret = gc13a0c_write_reg(gc13a0c->client,
					gc13a0c_REG_VTS,
					gc13a0c_REG_VALUE_16BIT,
					ctrl->val + gc13a0c->cur_mode->height);
		break;
	case V4L2_CID_TEST_PATTERN:
		ret = gc13a0c_enable_test_pattern(gc13a0c, ctrl->val);
		break;
	default:
		dev_warn(&client->dev, "%s Unhandled id:0x%x, val:0x%x\n",
			 __func__, ctrl->id, ctrl->val);
		break;
	}

	pm_runtime_put(&client->dev);

	return ret;
}

static const struct v4l2_ctrl_ops gc13a0c_ctrl_ops = {
	.s_ctrl = gc13a0c_set_ctrl,
};

static int gc13a0c_initialize_controls(struct gc13a0c *gc13a0c)
{
	const struct gc13a0c_mode *mode;
	struct v4l2_ctrl_handler *handler;
	s64 exposure_max, vblank_def;
	u32 h_blank;
	int ret;
	u64 dst_pixel_rate = 0;
	u32 lane_num = gc13a0c_LANES;

	handler = &gc13a0c->ctrl_handler;
	mode = gc13a0c->cur_mode;
	ret = v4l2_ctrl_handler_init(handler, 8);
	if (ret)
		return ret;
	handler->lock = &gc13a0c->mutex;

	gc13a0c->link_freq = v4l2_ctrl_new_int_menu(handler, NULL,
			V4L2_CID_LINK_FREQ,
			1, 0, link_freq_items);

	dst_pixel_rate = (u32)link_freq_items[mode->link_freq_idx] / mode->bpp * 2 * lane_num;

	gc13a0c->pixel_rate = v4l2_ctrl_new_std(handler, NULL,
			V4L2_CID_PIXEL_RATE,
			0, gc13a0c_PIXEL_RATE,
			1, dst_pixel_rate);

	__v4l2_ctrl_s_ctrl(gc13a0c->link_freq,
			   mode->link_freq_idx);

	h_blank = mode->hts_def - mode->width;
	gc13a0c->hblank = v4l2_ctrl_new_std(handler, NULL, V4L2_CID_HBLANK,
				h_blank, h_blank, 1, h_blank);
	if (gc13a0c->hblank)
		gc13a0c->hblank->flags |= V4L2_CTRL_FLAG_READ_ONLY;

	vblank_def = mode->vts_def - mode->height;
	gc13a0c->vblank = v4l2_ctrl_new_std(handler, &gc13a0c_ctrl_ops,
				V4L2_CID_VBLANK, vblank_def,
				gc13a0c_VTS_MAX - mode->height,
				1, vblank_def);

	exposure_max = mode->vts_def - 4;
	gc13a0c->exposure = v4l2_ctrl_new_std(handler, &gc13a0c_ctrl_ops,
				V4L2_CID_EXPOSURE, gc13a0c_EXPOSURE_MIN,
				exposure_max, gc13a0c_EXPOSURE_STEP,
				mode->exp_def);

	gc13a0c->anal_gain = v4l2_ctrl_new_std(handler, &gc13a0c_ctrl_ops,
				V4L2_CID_ANALOGUE_GAIN, gc13a0c_GAIN_MIN,
				gc13a0c_GAIN_MAX, gc13a0c_GAIN_STEP,
				gc13a0c_GAIN_DEFAULT);

	gc13a0c->test_pattern = v4l2_ctrl_new_std_menu_items(handler,
				&gc13a0c_ctrl_ops, V4L2_CID_TEST_PATTERN,
				ARRAY_SIZE(gc13a0c_test_pattern_menu) - 1,
				0, 0, gc13a0c_test_pattern_menu);

	if (handler->error) {
		ret = handler->error;
		dev_err(&gc13a0c->client->dev,
			"Failed to init controls(%d)\n", ret);
		goto err_free_handler;
	}

	gc13a0c->subdev.ctrl_handler = handler;

	return 0;

err_free_handler:
	v4l2_ctrl_handler_free(handler);

	return ret;
}

static int gc13a0c_check_sensor_id(struct gc13a0c *gc13a0c,
				struct i2c_client *client)
{
	struct device *dev = &gc13a0c->client->dev;
	u32 id = 0;
	u32 reg_H = 0;
	u32 reg_L = 0;
	int ret;
 
	ret = gc13a0c_read_reg(client, gc13a0c_REG_CHIP_ID_H,gc13a0c_REG_VALUE_08BIT,&reg_H);
	ret |= gc13a0c_read_reg(client, gc13a0c_REG_CHIP_ID_L,gc13a0c_REG_VALUE_08BIT,&reg_L);
	id = ((reg_H << 8) & 0xff00) | (reg_L & 0xff);
	if (id != CHIP_ID) {
		dev_err(dev, "Unexpected sensor id(%06x), ret(%d)\n", id, ret);
		return -ENODEV;
	}
	dev_info(dev, "detected gc%04x sensor\n", id);
	return ret;
}

// static int gc13a0c_configure_regulators(struct gc13a0c *gc13a0c)
// {
// 	unsigned int i;

// 	for (i = 0; i < gc13a0c_NUM_SUPPLIES; i++)
// 		gc13a0c->supplies[i].supply = gc13a0c_supply_names[i];

// 	return devm_regulator_bulk_get(&gc13a0c->client->dev,
// 				       gc13a0c_NUM_SUPPLIES,
// 				       gc13a0c->supplies);
// }

static int gc13a0c_probe(struct i2c_client *client,
			 const struct i2c_device_id *id)
{
	struct device *dev = &client->dev;
	struct device_node *node = dev->of_node;
	struct gc13a0c *gc13a0c;
	struct v4l2_subdev *sd;
	char facing[2];
	int ret;

	dev_info(dev, "driver version: %02x.%02x.%02x",
		DRIVER_VERSION >> 16,
		(DRIVER_VERSION & 0xff00) >> 8,
		DRIVER_VERSION & 0x00ff);

	gc13a0c = devm_kzalloc(dev, sizeof(*gc13a0c), GFP_KERNEL);
	if (!gc13a0c)
		return -ENOMEM;

	ret = of_property_read_u32(node, RKMODULE_CAMERA_MODULE_INDEX,
				   &gc13a0c->module_index);
	ret |= of_property_read_string(node, RKMODULE_CAMERA_MODULE_FACING,
				       &gc13a0c->module_facing);
	ret |= of_property_read_string(node, RKMODULE_CAMERA_MODULE_NAME,
				       &gc13a0c->module_name);
	ret |= of_property_read_string(node, RKMODULE_CAMERA_LENS_NAME,
				       &gc13a0c->len_name);
	if (ret) {
		dev_err(dev, "could not get module information!\n");
		return -EINVAL;
	}

	gc13a0c->client = client;
	gc13a0c->cur_mode = &supported_modes[0];

	gc13a0c->xvclk = devm_clk_get(dev, "xvclk");
	if (IS_ERR(gc13a0c->xvclk)) {
		dev_err(dev, "Failed to get xvclk\n");
		return -EINVAL;
	}

	// ret = gc13a0c_configure_regulators(gc13a0c);
	// if (ret) {
	// 	dev_err(dev, "Failed to get power regulators\n");
	// 	return ret;
	// }

	gc13a0c->avdd = devm_regulator_get(dev, "avdd");
	if (IS_ERR(gc13a0c->avdd)) {
		dev_err(dev, "Failed to get avdd-supply\n");
		return -EINVAL;
	}

	gc13a0c->iovdd = devm_regulator_get(dev, "iovdd");
	if (IS_ERR(gc13a0c->iovdd)) {
		dev_err(dev, "Failed to get iovdd-supply\n");
		return -EINVAL;
	}

	gc13a0c->dvdd = devm_regulator_get(dev, "dvdd");
	if (IS_ERR(gc13a0c->dvdd)) {
		dev_err(dev, "Failed to get dvdd-supply\n");
		return -EINVAL;
	}

	gc13a0c->pinctrl = devm_pinctrl_get(dev);
	if (!IS_ERR(gc13a0c->pinctrl)) {
		gc13a0c->pins_default =
			pinctrl_lookup_state(gc13a0c->pinctrl,
					     OF_CAMERA_PINCTRL_STATE_DEFAULT);
		if (IS_ERR(gc13a0c->pins_default))
			dev_err(dev, "could not get default pinstate\n");

		gc13a0c->pins_sleep =
			pinctrl_lookup_state(gc13a0c->pinctrl,
					     OF_CAMERA_PINCTRL_STATE_SLEEP);
		if (IS_ERR(gc13a0c->pins_sleep))
			dev_err(dev, "could not get sleep pinstate\n");
	}

	mutex_init(&gc13a0c->mutex);

	sd = &gc13a0c->subdev;
	v4l2_i2c_subdev_init(sd, client, &gc13a0c_subdev_ops);
	ret = gc13a0c_initialize_controls(gc13a0c);
	if (ret)
		goto err_destroy_mutex;

	ret = __gc13a0c_power_on(gc13a0c);
	if (ret)
		goto err_free_handler;

	ret = gc13a0c_check_sensor_id(gc13a0c, client);
	if (ret)
		goto err_power_off;

#ifdef CONFIG_VIDEO_V4L2_SUBDEV_API
	sd->internal_ops = &gc13a0c_internal_ops;
	sd->flags |= V4L2_SUBDEV_FL_HAS_DEVNODE;
#endif
#if defined(CONFIG_MEDIA_CONTROLLER)
	gc13a0c->pad.flags = MEDIA_PAD_FL_SOURCE;
	sd->entity.function = MEDIA_ENT_F_CAM_SENSOR;
	ret = media_entity_pads_init(&sd->entity, 1, &gc13a0c->pad);
	if (ret < 0)
		goto err_power_off;
#endif

	memset(facing, 0, sizeof(facing));
	if (strcmp(gc13a0c->module_facing, "back") == 0)
		facing[0] = 'b';
	else
		facing[0] = 'f';

	snprintf(sd->name, sizeof(sd->name), "m%02d_%s_%s %s",
		 gc13a0c->module_index, facing,
		 gc13a0c_NAME, dev_name(sd->dev));
	ret = v4l2_async_register_subdev_sensor(sd);
	if (ret) {
		dev_err(dev, "v4l2 async register subdev failed\n");
		goto err_clean_entity;
	}

	pm_runtime_set_active(dev);
	pm_runtime_enable(dev);
	pm_runtime_idle(dev);

	return 0;

err_clean_entity:
#if defined(CONFIG_MEDIA_CONTROLLER)
	media_entity_cleanup(&sd->entity);
#endif
 err_power_off:
 	__gc13a0c_power_off(gc13a0c);
err_free_handler:
	v4l2_ctrl_handler_free(&gc13a0c->ctrl_handler);
err_destroy_mutex:
	mutex_destroy(&gc13a0c->mutex);

	return ret;
}

static void gc13a0c_remove(struct i2c_client *client)
{
	struct v4l2_subdev *sd = i2c_get_clientdata(client);
	struct gc13a0c *gc13a0c = to_gc13a0c(sd);

	v4l2_async_unregister_subdev(sd);
#if defined(CONFIG_MEDIA_CONTROLLER)
	media_entity_cleanup(&sd->entity);
#endif
	v4l2_ctrl_handler_free(&gc13a0c->ctrl_handler);
	mutex_destroy(&gc13a0c->mutex);

	pm_runtime_disable(&client->dev);
	if (!pm_runtime_status_suspended(&client->dev))
		__gc13a0c_power_off(gc13a0c);
	pm_runtime_set_suspended(&client->dev);
}

#if IS_ENABLED(CONFIG_OF)
static const struct of_device_id gc13a0c_of_match[] = {
	{ .compatible = "quec,gc13a0c" },
	{},
};
MODULE_DEVICE_TABLE(of, gc13a0c_of_match);
#endif

static const struct i2c_device_id gc13a0c_match_id[] = {
	{ "quec,gc13a0c", 0 },
	{},
};

static struct i2c_driver gc13a0c_i2c_driver = {
	.driver = {
		.name = gc13a0c_NAME,
		.pm = &gc13a0c_pm_ops,
		.of_match_table = of_match_ptr(gc13a0c_of_match),
	},
	.probe		= &gc13a0c_probe,
	.remove		= &gc13a0c_remove,
	.id_table	= gc13a0c_match_id,
};

static int __init sensor_mod_init(void)
{
	return i2c_add_driver(&gc13a0c_i2c_driver);
}

static void __exit sensor_mod_exit(void)
{
	i2c_del_driver(&gc13a0c_i2c_driver);
}

device_initcall_sync(sensor_mod_init);
module_exit(sensor_mod_exit);

MODULE_DESCRIPTION("quec gc13a0c sensor driver");
MODULE_LICENSE("GPL v2");
