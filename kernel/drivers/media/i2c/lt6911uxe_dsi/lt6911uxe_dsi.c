#include <linux/i2c.h>
#include <linux/gpio.h>
#include <linux/gpio/consumer.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/printk.h>
#include <linux/kernel.h>
#include <linux/delay.h>
#include <linux/mutex.h>
#include <linux/kmod.h>
#include <linux/module.h>
#include <linux/kthread.h>
#include <linux/firmware.h>
#include <linux/slab.h>
#include <linux/ctype.h>

#define FW_FILE "LT6911UXE.bin"
#define LT_PAGE_SIZE 256
#define FLASH_SIZE  (32 * 1024)
#define LT6911UXE_I2C_RETRY_TIMES 3
#define LT6911UXE_FW_LOAD_RETRY_TIMES 30
#define LT6911UXE_FW_LOAD_RETRY_MS 1000

#define LT_REG_INT_TYPE		0x84
#define LT_REG_PCLK_H		0x85
#define LT_REG_PCLK_M		0x86
#define LT_REG_PCLK_L		0x87
#define LT_REG_HTOTAL_H		0x88
#define LT_REG_HTOTAL_L		0x89
#define LT_REG_VTOTAL_H		0x8a
#define LT_REG_VTOTAL_L		0x8b
#define LT_REG_HACT_H		0x8c
#define LT_REG_HACT_L		0x8d
#define LT_REG_VACT_H		0x8e
#define LT_REG_VACT_L		0x8f
#define LT_REG_BUS_FMT		0x96
#define LT_REG_AUDIO_FS_H	0x90
#define LT_REG_AUDIO_FS_L	0x91
#define LT_REG_BYTECLK_H	0x92
#define LT_REG_BYTECLK_M	0x93
#define LT_REG_BYTECLK_L	0x94
#define LT_REG_LANE_NUM		0x95
#define LT_REG_VFP_H		0x97
#define LT_REG_VFP_L		0x98

static struct task_struct *kthread_obj;
static int debug;

module_param(debug, int, 0644);
MODULE_PARM_DESC(debug, "debug level (0-3)");

struct lt6911uxe {
	struct device *dev;
	struct mutex ocm_lock;
	struct gpio_desc *reset_gpio;
	struct gpio_desc *power_gpio;
	struct gpio_desc *interrupt_gpio;
	struct i2c_client *client;
	const struct firmware *fw;
	struct gpio_desc *hdmi_reset_gpio;
	u8 *fw_tmp;
	const char *fw_name;

	u8 fw_crc;
	u8 flash_crc;
	u64 ver;
	bool fw_need_upgrade;
};

struct crc_info {
	u8 width;
	u32 poly;
	u32 crc_init;
	u32 xor_out;
	bool refin;
	bool refout;
};

struct lt6911uxe_rx_status {
	u8 reg80;
	u8 reg81;
	u8 reg82;
	u8 reg83;
	u8 int_type;
	u8 bus_fmt;
	u8 lane_num;
	u16 audio_fs;
	u32 hact;
	u32 vact;
	u32 htotal;
	u32 vtotal;
	u64 pixel_clock;
	u64 byte_clock;
};

static void lt6911uxe_config(struct lt6911uxe *lt6911uxe);
static void lt6911uxe_wrdi(struct lt6911uxe *lt6911uxe);
static void lt6911uxe_flash_to_fifo(struct lt6911uxe *lt6911uxe, u32 addr);

static unsigned int bits_reverse(u32 in_val, u8 bits)
{
	u32 out_val = 0;
	u8 i;

	for (i = 0; i < bits; i++) {
		if (in_val & (1 << i))
			out_val |= 1 << (bits - 1 - i);
	}

	return out_val;
}

static unsigned int get_crc(struct crc_info type, const u8 *buf, u64 buf_len)
{
	u8 width = type.width;
	u32 poly = type.poly;
	u32 crc = type.crc_init;
	u32 xorout = type.xor_out;
	bool refin = type.refin;
	bool refout = type.refout;
	u8 n;
	u32 bits;
	u32 data;
	u8 i;

	n = (width < 8) ? 0 : (width - 8);
	crc = (width < 8) ? (crc << (8 - width)) : crc;
	bits = (width < 8) ? 0x80 : (1 << (width - 1));
	poly = (width < 8) ? (poly << (8 - width)) : poly;
	while (buf_len--) {
		data = *(buf++);
		if (refin)
			data = bits_reverse(data, 8);
		crc ^= (data << n);
		for (i = 0; i < 8; i++) {
			if (crc & bits)
				crc = (crc << 1) ^ poly;
			else
				crc = crc << 1;
		}
	}
	crc = (width < 8) ? (crc >> (8 - width)) : crc;
	if (refout)
		crc = bits_reverse(crc, width);
	crc ^= xorout;

	return (crc & ((2 << (width - 1)) - 1));
}

static u8 calculate_crc(struct lt6911uxe *lt6911uxe)
{
	struct crc_info type = {
		.width = 8,
		.poly = 0x31,
		.crc_init = 0,
		.xor_out = 0,
		.refout = false,
		.refin = false,
	};
	const u8 *upgrade_data;
	u64 len;
	u64 crc_size = FLASH_SIZE - 1;
	u8 default_val = 0xff;

	upgrade_data = lt6911uxe->fw->data;
	len = lt6911uxe->fw->size;

	type.crc_init = get_crc(type, upgrade_data, len);

	crc_size -= len;
	while (crc_size--)
		type.crc_init = get_crc(type, &default_val, 1);

	return type.crc_init;
}


static int write_i2c_byte(struct lt6911uxe *lt6911uxe, u8 addr, u8 val)
{
	struct i2c_client *client = lt6911uxe->client;
	u8 buf[2] = { addr, val };
	int ret;
	int retry;

	for (retry = 0; retry < LT6911UXE_I2C_RETRY_TIMES; retry++) {
		ret = i2c_master_send(client, buf, sizeof(buf));
		if (ret == sizeof(buf)) {
			if (debug >= 2)
				dev_info(lt6911uxe->dev,
					 "i2c write reg[0x%02x] = 0x%02x\n",
					 addr, val);
			return 0;
		}

		if (ret >= 0)
			ret = -EIO;

		dev_warn(lt6911uxe->dev,
			 "i2c write retry %d/%d failed: reg[0x%02x] = 0x%02x, err=%d\n",
			 retry + 1, LT6911UXE_I2C_RETRY_TIMES, addr, val, ret);
		usleep_range(2000, 3000);
	}

	dev_err(lt6911uxe->dev,
		"i2c write error: reg[0x%02x] = 0x%02x, err=%d\n",
		addr, val, ret);
	return ret;
}

static int read_i2c_byte(struct lt6911uxe *lt6911uxe, u8 addr)
{
	struct i2c_client *client = lt6911uxe->client;
	struct i2c_msg msgs[2];
	u8 reg = addr;
	u8 val = 0;
	int ret;
	int retry;

	msgs[0].addr = client->addr;
	msgs[0].flags = 0;
	msgs[0].len = 1;
	msgs[0].buf = &reg;

	msgs[1].addr = client->addr;
	msgs[1].flags = I2C_M_RD;
	msgs[1].len = 1;
	msgs[1].buf = &val;

	for (retry = 0; retry < LT6911UXE_I2C_RETRY_TIMES; retry++) {
		ret = i2c_transfer(client->adapter, msgs, ARRAY_SIZE(msgs));
		if (ret == ARRAY_SIZE(msgs)) {
			if (debug >= 2)
				dev_info(lt6911uxe->dev,
					 "i2c read reg[0x%02x] = 0x%02x\n",
					 addr, val);
			return val;
		}

		if (ret >= 0)
			ret = -EIO;

		dev_warn(lt6911uxe->dev,
			 "i2c read retry %d/%d failed: reg[0x%02x], err=%d\n",
			 retry + 1, LT6911UXE_I2C_RETRY_TIMES, addr, ret);
		usleep_range(2000, 3000);
	}

	dev_err(lt6911uxe->dev,
		"i2c read error: reg[0x%02x], err=%d\n", addr, ret);
	return ret;
}

static int lt6911uxe_i2c_enable(struct lt6911uxe *lt6911uxe)
{
	int ret;

	mutex_lock(&lt6911uxe->ocm_lock);
	ret = write_i2c_byte(lt6911uxe, 0xff, 0xe0);
	if (ret) {
		mutex_unlock(&lt6911uxe->ocm_lock);
		return ret;
	}

	ret = write_i2c_byte(lt6911uxe, 0xee, 0x01);
	if (ret) {
		mutex_unlock(&lt6911uxe->ocm_lock);
		return ret;
	}

	return ret;
}

static int lt6911uxe_i2c_disable(struct lt6911uxe *lt6911uxe)
{
	int ret;

	ret = write_i2c_byte(lt6911uxe, 0xff, 0xe0);
	if(ret) {
		mutex_unlock(&lt6911uxe->ocm_lock);
		return ret;
	}
	ret = write_i2c_byte(lt6911uxe, 0xee, 0x00);
	if(ret) {
		mutex_unlock(&lt6911uxe->ocm_lock);
		return ret;
	}
	mutex_unlock(&lt6911uxe->ocm_lock);
	return ret;
}

static void lt6911uxe_chip_id(struct lt6911uxe *lt6911uxe)
{
	int id0, id1, eco;

	write_i2c_byte(lt6911uxe, 0xff, 0xe1);
	id0 = read_i2c_byte(lt6911uxe, 0x00);
	id1 = read_i2c_byte(lt6911uxe, 0x01);
	eco = read_i2c_byte(lt6911uxe, 0x02);

	dev_info(lt6911uxe->dev, "chip id: 0x%02x 0x%02x, eco: 0x%02x\n",
		 id0, id1, eco);
}

static void lt6911uxe_dump_e080_e083(struct lt6911uxe *lt6911uxe)
{
	int reg80, reg81, reg82, reg83;

	write_i2c_byte(lt6911uxe, 0xff, 0xe0);
	reg80 = read_i2c_byte(lt6911uxe, 0x80);
	reg81 = read_i2c_byte(lt6911uxe, 0x81);
	reg82 = read_i2c_byte(lt6911uxe, 0x82);
	reg83 = read_i2c_byte(lt6911uxe, 0x83);

	if (reg80 < 0 || reg81 < 0 || reg82 < 0 || reg83 < 0) {
		dev_warn(lt6911uxe->dev,
			 "failed to read E080-E083: E080=%d E081=%d E082=%d E083=%d\n",
			 reg80, reg81, reg82, reg83);
		return;
	}

	dev_info(lt6911uxe->dev,
		 "E080-E083: E080=0x%02x E081=0x%02x E082=0x%02x E083=0x%02x\n",
		 reg80, reg81, reg82, reg83);
}

static int lt6911uxe_get_rx_status(struct lt6911uxe *lt6911uxe,
				   struct lt6911uxe_rx_status *status)
{
	int pclk_h, pclk_m, pclk_l;
	int htotal_h, htotal_l, vtotal_h, vtotal_l;
	int hact_h, hact_l, vact_h, vact_l;
	int byteclk_h, byteclk_m, byteclk_l;
	int audio_fs_h, audio_fs_l;

	memset(status, 0, sizeof(*status));

	write_i2c_byte(lt6911uxe, 0xff, 0xe0);

	status->reg80 = read_i2c_byte(lt6911uxe, 0x80);
	status->reg81 = read_i2c_byte(lt6911uxe, 0x81);
	status->reg82 = read_i2c_byte(lt6911uxe, 0x82);
	status->reg83 = read_i2c_byte(lt6911uxe, 0x83);
	status->int_type = read_i2c_byte(lt6911uxe, LT_REG_INT_TYPE);
	pclk_h = read_i2c_byte(lt6911uxe, LT_REG_PCLK_H);
	pclk_m = read_i2c_byte(lt6911uxe, LT_REG_PCLK_M);
	pclk_l = read_i2c_byte(lt6911uxe, LT_REG_PCLK_L);
	htotal_h = read_i2c_byte(lt6911uxe, LT_REG_HTOTAL_H);
	htotal_l = read_i2c_byte(lt6911uxe, LT_REG_HTOTAL_L);
	vtotal_h = read_i2c_byte(lt6911uxe, LT_REG_VTOTAL_H);
	vtotal_l = read_i2c_byte(lt6911uxe, LT_REG_VTOTAL_L);
	hact_h = read_i2c_byte(lt6911uxe, LT_REG_HACT_H);
	hact_l = read_i2c_byte(lt6911uxe, LT_REG_HACT_L);
	vact_h = read_i2c_byte(lt6911uxe, LT_REG_VACT_H);
	vact_l = read_i2c_byte(lt6911uxe, LT_REG_VACT_L);
	audio_fs_h = read_i2c_byte(lt6911uxe, LT_REG_AUDIO_FS_H);
	audio_fs_l = read_i2c_byte(lt6911uxe, LT_REG_AUDIO_FS_L);
	byteclk_h = read_i2c_byte(lt6911uxe, LT_REG_BYTECLK_H);
	byteclk_m = read_i2c_byte(lt6911uxe, LT_REG_BYTECLK_M);
	byteclk_l = read_i2c_byte(lt6911uxe, LT_REG_BYTECLK_L);
	status->lane_num = read_i2c_byte(lt6911uxe, LT_REG_LANE_NUM);
	status->bus_fmt = read_i2c_byte(lt6911uxe, LT_REG_BUS_FMT);

	if (pclk_h < 0 || pclk_m < 0 || pclk_l < 0 ||
	    status->int_type < 0 ||
	    htotal_h < 0 || htotal_l < 0 ||
	    vtotal_h < 0 || vtotal_l < 0 ||
	    hact_h < 0 || hact_l < 0 ||
	    vact_h < 0 || vact_l < 0 ||
	    audio_fs_h < 0 || audio_fs_l < 0 ||
	    byteclk_h < 0 || byteclk_m < 0 || byteclk_l < 0 ||
	    status->lane_num < 0 || status->bus_fmt < 0)
		return -EIO;

	status->pixel_clock = (((u64)pclk_h << 16) |
			       ((u64)pclk_m << 8) | (u64)pclk_l) * 1000ULL * 2ULL;
	status->byte_clock = (((u64)byteclk_h << 16) |
			      ((u64)byteclk_m << 8) | (u64)byteclk_l) * 1000ULL;
	status->htotal = (((u32)htotal_h << 8) | (u32)htotal_l) * 2U;
	status->vtotal = ((u32)vtotal_h << 8) | (u32)vtotal_l;
	status->hact = (((u32)hact_h << 8) | (u32)hact_l) * 2U;
	status->vact = ((u32)vact_h << 8) | (u32)vact_l;
	status->audio_fs = ((u16)audio_fs_h << 8) | (u16)audio_fs_l;

	return 0;
}

static void lt6911uxe_log_rx_status(struct lt6911uxe *lt6911uxe,
				    const struct lt6911uxe_rx_status *status)
{
	dev_info(lt6911uxe->dev,
		 "rx status: int=0x%02x lanes=%u fmt=0x%02x act=%ux%u total=%ux%u pclk=%llu byteclk=%llu audio_fs=0x%04x\n",
		 status->int_type, status->lane_num, status->bus_fmt,
		 status->hact, status->vact, status->htotal, status->vtotal,
		 status->pixel_clock, status->byte_clock, status->audio_fs);
}

static void lt6911uxe_power_on(struct lt6911uxe *lt6911uxe)
{
	if (!lt6911uxe->power_gpio)
		return;

	gpiod_set_value(lt6911uxe->power_gpio, 1);
	msleep(10);
}
static void lt6911uxe_hdmi_reset(struct lt6911uxe *lt6911uxe)
{
	if (!lt6911uxe->hdmi_reset_gpio)
		return;

	/* ACTIVE_LOW: 1=assert(reset), 0=deassert(release) */
	gpiod_set_value_cansleep(lt6911uxe->hdmi_reset_gpio, 1);
	usleep_range(60000,100000);
	gpiod_set_value_cansleep(lt6911uxe->hdmi_reset_gpio, 0);
	usleep_range(60000,100000);

	dev_info(lt6911uxe->dev, "hdmi reset done.\n");
}

static void lt6911uxe_reset(struct lt6911uxe *lt6911uxe)
{
	if (lt6911uxe->reset_gpio) {
		gpiod_set_value_cansleep(lt6911uxe->reset_gpio, 1);
		msleep(5);
		gpiod_set_value_cansleep(lt6911uxe->reset_gpio, 0);
		msleep(5);
		gpiod_set_value_cansleep(lt6911uxe->reset_gpio, 1);
		msleep(5);

		dev_info(lt6911uxe->dev, "chip reset done.\n");
	}

	/* 在 reset-gpios 复位之后，再复位 HDMI */
	lt6911uxe_hdmi_reset(lt6911uxe);
}

static void lt6911uxe_log_interrupt_gpio(struct lt6911uxe *lt6911uxe,
					 const char *stage)
{
	int logical;
	int raw;

	if (!lt6911uxe->interrupt_gpio)
		return;

	logical = gpiod_get_value_cansleep(lt6911uxe->interrupt_gpio);
	raw = gpiod_get_raw_value_cansleep(lt6911uxe->interrupt_gpio);
	if (logical < 0 || raw < 0) {
		dev_warn(lt6911uxe->dev,
			 "%s: failed to read interrupt gpio, logical=%d raw=%d\n",
			 stage, logical, raw);
		return;
	}

	dev_info(lt6911uxe->dev,
		 "%s: interrupt gpio logical=%d raw=%d\n",
		 stage, logical, raw);
}

static u64 lt6911uxe_read_version(struct lt6911uxe *lt6911uxe)
{
	u64 version =0;

	write_i2c_byte(lt6911uxe, 0xff, 0xe0);
	version = ((version << 8) | read_i2c_byte(lt6911uxe, 0x80));
	version = ((version << 8) | read_i2c_byte(lt6911uxe, 0x81));
	version = ((version << 8) | read_i2c_byte(lt6911uxe, 0x82));
	version = ((version << 8) | read_i2c_byte(lt6911uxe, 0x83));

	return version;
}

static bool lt6911uxe_parse_fw_version_from_name(const char *fw_name, u32 *version)
{
	const char *best = NULL;
	int best_len = 0;
	const char *p;
	int i;
	u32 parsed = 0;

	if (!fw_name || !version)
		return false;

	for (p = fw_name; *p; ) {
		const char *start;
		int len = 0;

		while (*p && !isdigit(*p))
			p++;
		start = p;
		while (*p && isdigit(*p)) {
			p++;
			len++;
		}

		if (len == 8 || len == 10) {
			best = start;
			best_len = len;
		}
	}

	if (!best)
		return false;

	if (best_len == 10) {
		if (best[0] != '2' || best[1] != '0')
			return false;
		best += 2;
		best_len = 8;
	}

	for (i = 0; i < best_len; i += 2) {
		u8 byte;

		if (!isdigit(best[i]) || !isdigit(best[i + 1]))
			return false;

		byte = ((best[i] - '0') << 4) | (best[i + 1] - '0');
		parsed = (parsed << 8) | byte;
	}

	*version = parsed;
	return true;
}

static int lt6911uxe_read_flash_crc(struct lt6911uxe *lt6911uxe, u8 *flash_crc)
{
	int ret;

	if (!flash_crc)
		return -EINVAL;

	lt6911uxe_config(lt6911uxe);
	lt6911uxe_flash_to_fifo(lt6911uxe, FLASH_SIZE - 1);
	write_i2c_byte(lt6911uxe, 0x58, 0x21);
	ret = read_i2c_byte(lt6911uxe, 0x5f);
	lt6911uxe_wrdi(lt6911uxe);
	if (ret < 0)
		return ret;

	*flash_crc = ret;
	return 0;
}

static void lt6911uxe_config(struct lt6911uxe *lt6911uxe)
{
	write_i2c_byte(lt6911uxe, 0xff, 0xe0);
	write_i2c_byte(lt6911uxe, 0xee, 0x01);
	write_i2c_byte(lt6911uxe, 0x5e, 0xc1);
	write_i2c_byte(lt6911uxe, 0x58, 0x00);
	write_i2c_byte(lt6911uxe, 0x59, 0x50);
	write_i2c_byte(lt6911uxe, 0x5a, 0x10);
	write_i2c_byte(lt6911uxe, 0x5a, 0x00);
	write_i2c_byte(lt6911uxe, 0x58, 0x21);
}

static void lt6911uxe_wren(struct lt6911uxe *lt6911uxe)
{
	write_i2c_byte(lt6911uxe, 0x5a, 0x04);
	write_i2c_byte(lt6911uxe, 0x5a, 0x00);
}

static void lt6911uxe_wrdi(struct lt6911uxe *lt6911uxe)
{
	write_i2c_byte(lt6911uxe, 0x5a, 0x08);
	write_i2c_byte(lt6911uxe, 0x5a, 0x00);
}
static u8 lt6911uxe_read_flash_status(struct lt6911uxe *lt6911uxe)
{
	u8 flash_status = 0;
	write_i2c_byte(lt6911uxe, 0xff, 0xe1);
	write_i2c_byte(lt6911uxe, 0x03, 0x3f);
	write_i2c_byte(lt6911uxe, 0x03, 0xff);

	write_i2c_byte(lt6911uxe, 0xff, 0xe0);
	write_i2c_byte(lt6911uxe, 0x5e, 0x40);
	write_i2c_byte(lt6911uxe, 0x56, 0x05);
	write_i2c_byte(lt6911uxe, 0x55, 0x25);
	write_i2c_byte(lt6911uxe, 0x55, 0x01);
	write_i2c_byte(lt6911uxe, 0x58, 0x21);
	flash_status = read_i2c_byte(lt6911uxe, 0x5f);
	return flash_status;
}

static void lt6911uxe_block_erase(struct lt6911uxe *lt6911uxe)
{
	u32 addr = 0;
	u32 i = 0;
	u8 flash_status = 0;
	u8 block_num = 0;

	for (block_num = 0; block_num < 1; block_num++) {
		addr = block_num * 0x008000;
		write_i2c_byte(lt6911uxe, 0xff, 0xe0);
		write_i2c_byte(lt6911uxe, 0xee, 0x01);

		write_i2c_byte(lt6911uxe, 0x5a, 0x04);
		write_i2c_byte(lt6911uxe, 0x5a, 0x00);
		write_i2c_byte(lt6911uxe, 0x5b, (addr >> 16) & 0xff);
		write_i2c_byte(lt6911uxe, 0x5c, (addr >> 8) & 0xff);
		write_i2c_byte(lt6911uxe, 0x5d, addr & 0xff);
		write_i2c_byte(lt6911uxe, 0x5a, 0x01);
		write_i2c_byte(lt6911uxe, 0x5a, 0x00);
		msleep(100);
		i = 0;
		while (1) {
			flash_status = lt6911uxe_read_flash_status(lt6911uxe);
			if ((flash_status & 0x01) == 0) {
				break;
			}
			if (i > 50) {
				break;
			}
			i++;
			msleep(50);
		}
	}
	dev_info(lt6911uxe->dev, "erase flash done.\n");
}

static void lt6911uxe_flash_to_fifo(struct lt6911uxe *lt6911uxe, u32 addr)
{
	write_i2c_byte(lt6911uxe, 0x5e, 0x40);

	write_i2c_byte(lt6911uxe, 0x5a, 0x20);
	write_i2c_byte(lt6911uxe, 0x5a, 0x00);
	write_i2c_byte(lt6911uxe, 0x5b, (addr >> 16) & 0xff);
	write_i2c_byte(lt6911uxe, 0x5c, (addr >> 8) & 0xff);
	write_i2c_byte(lt6911uxe, 0x5d, addr & 0xff);
	write_i2c_byte(lt6911uxe, 0x5a, 0x10);
	write_i2c_byte(lt6911uxe, 0x5a, 0x00);
}

static void lt6911uxe_sram_to_flash(struct lt6911uxe *lt6911uxe)
{
	write_i2c_byte(lt6911uxe, 0x5a, 0x30);
	write_i2c_byte(lt6911uxe, 0x5a, 0x00);
}

static void lt6911uxe_i2c_to_sram_data(struct lt6911uxe *lt6911uxe)
{
	write_i2c_byte(lt6911uxe, 0xff, 0xe0);
	write_i2c_byte(lt6911uxe, 0xee, 0x01);
	write_i2c_byte(lt6911uxe, 0x55, 0x80);
	write_i2c_byte(lt6911uxe, 0x5e, 0xc0);
	write_i2c_byte(lt6911uxe, 0x58, 0x21);
}

static int lt6911uxe_write_data(struct lt6911uxe *lt6911uxe, u32 addr)
{
	int ret;
	u32 page = 0;
	u32 i = 0;
	u32 num = 0;
	const  u8 *pfile = lt6911uxe->fw_tmp;
	u32 len = FLASH_SIZE;

	page = (len % LT_PAGE_SIZE) ? ((len / LT_PAGE_SIZE) + 1) : (len / LT_PAGE_SIZE);
	dev_info(lt6911uxe->dev, "page = %u, len = %u\n", page, len);

	for (num = 0; num < page; num++) {
		lt6911uxe_i2c_to_sram_data(lt6911uxe);

		for (i = 0; i < LT_PAGE_SIZE; i++) {

			if ((num * LT_PAGE_SIZE + i) < len) {

				ret = write_i2c_byte(lt6911uxe, 0x59, *(pfile + (num * LT_PAGE_SIZE + i)));
				if (ret < 0) {
					dev_err(lt6911uxe->dev, "Error writing data at page %u, index %u\n", num, i);
					return ret;
				}
			} else {
				ret = write_i2c_byte(lt6911uxe, 0x59, 0xff);
				if (ret < 0) {
					dev_err(lt6911uxe->dev, "Error writing data at page %u, index %u\n", num, i);
					return ret;
				}
			}
		}

		lt6911uxe_wren(lt6911uxe);
		lt6911uxe_sram_to_flash(lt6911uxe);
		usleep_range(150, 200);
	}

	lt6911uxe_wrdi(lt6911uxe);

	return 0;
}

static int lt6911uxe_upgrade_judgment(struct lt6911uxe *lt6911uxe)
{
	int ret;

	ret = lt6911uxe_read_flash_crc(lt6911uxe, &lt6911uxe->flash_crc);
	if (ret)
		return ret;
	dev_info(lt6911uxe->dev, "flash crc is :0x%02x\n",
		 lt6911uxe->flash_crc);

	lt6911uxe->fw_need_upgrade = lt6911uxe->fw_crc != lt6911uxe->flash_crc;
	return lt6911uxe->fw_need_upgrade;
}

static int lt6911uxe_firmware_upgrade(struct lt6911uxe *lt6911uxe)
{
	int ret;

	lt6911uxe_config(lt6911uxe);
	lt6911uxe_block_erase(lt6911uxe);

	ret = lt6911uxe_write_data(lt6911uxe, 0);
	if (ret < 0) {
		dev_err(lt6911uxe->dev, "Failed to write firmware data: %d\n", ret);
		return ret;
	}

	dev_info(lt6911uxe->dev,"write to flash done!\n");
	return 0;
}


static int lt6911uxe_prepare_firmware_data(struct lt6911uxe *lt6911uxe)
{
	int ret;

	ret = request_firmware(&lt6911uxe->fw, lt6911uxe->fw_name,
			       lt6911uxe->dev);
	if (ret) {
		dev_err(lt6911uxe->dev,
			"Failed to request firmware %s: %d\n",
			lt6911uxe->fw_name, ret);
		return ret;
	}

	if (lt6911uxe->fw->size > FLASH_SIZE - 1) {
		dev_err(lt6911uxe->dev, "firmware size exceeds limit\n");
		release_firmware(lt6911uxe->fw);
		lt6911uxe->fw = NULL;
		return -EINVAL;
	}

	lt6911uxe->fw_tmp = kzalloc(FLASH_SIZE, GFP_KERNEL);
	if (!lt6911uxe->fw_tmp) {
		dev_err(lt6911uxe->dev, "Failed to allocate firmware buffer\n");
		release_firmware(lt6911uxe->fw);
		lt6911uxe->fw = NULL;
		return -ENOMEM;
	}

	memset(lt6911uxe->fw_tmp, 0xff, FLASH_SIZE);
	memcpy(lt6911uxe->fw_tmp, lt6911uxe->fw->data, lt6911uxe->fw->size);

	lt6911uxe->fw_crc = calculate_crc(lt6911uxe);
	lt6911uxe->fw_tmp[FLASH_SIZE - 1] = lt6911uxe->fw_crc;
	dev_info(lt6911uxe->dev, "firmware %s crc: 0x%02x\n",
		 lt6911uxe->fw_name, lt6911uxe->fw_crc);

	release_firmware(lt6911uxe->fw);
	lt6911uxe->fw = NULL;

	return 0;
}

static int lt6911uxe_prepare_firmware_data_retry(struct lt6911uxe *lt6911uxe)
{
	int retry;
	int ret;

	for (retry = 0; retry <= LT6911UXE_FW_LOAD_RETRY_TIMES; retry++) {
		ret = lt6911uxe_prepare_firmware_data(lt6911uxe);
		if (!ret || ret != -ENOENT)
			return ret;

		if (retry == LT6911UXE_FW_LOAD_RETRY_TIMES)
			break;

		dev_info(lt6911uxe->dev,
			 "firmware %s is not ready, retry %d/%d after %d ms\n",
			 lt6911uxe->fw_name, retry + 1,
			 LT6911UXE_FW_LOAD_RETRY_TIMES,
			 LT6911UXE_FW_LOAD_RETRY_MS);
		msleep(LT6911UXE_FW_LOAD_RETRY_MS);
	}

	return ret;
}

static int lt6911uxe_upgrade_result(struct lt6911uxe *lt6911uxe)
{
	u8 crc_result;

	write_i2c_byte(lt6911uxe, 0xff, 0xe0);
	write_i2c_byte(lt6911uxe, 0xee, 0x01);
	crc_result = read_i2c_byte(lt6911uxe, 0x21);
	if (lt6911uxe->fw_crc != crc_result) {
		dev_err(lt6911uxe->dev, "crc is:0x%02x, upgrade is failed.\n", crc_result);
		return crc_result;
	}

	dev_info(lt6911uxe->dev, "crc is:0x%02x, upgrade is success.\n", crc_result);
	return 0;
}

static ssize_t firmware_upgrade_store(struct device *dev,
			struct device_attribute *attr,
			const char *buf,
			size_t count)
{
	struct lt6911uxe *lt6911uxe = dev_get_drvdata(dev);
	int ret = 0;

	dev_info(dev, "manual firmware upgrade requested\n");

	ret = lt6911uxe_i2c_enable(lt6911uxe);
	if (ret) {
		dev_err(dev, "failed to enable lt6911uxe i2c: %d\n", ret);
		return ret;
	}
	ret = lt6911uxe_prepare_firmware_data(lt6911uxe);
	if (ret) {
		dev_err(dev, "failed to prepare firmware data: %d\n", ret);
		goto out_disable_i2c;
	}

	ret = lt6911uxe_firmware_upgrade(lt6911uxe);
	if (ret) {
		dev_err(dev, "firmware upgrade failed: %d\n", ret);
		goto out_disable_i2c;
	}

	lt6911uxe_reset(lt6911uxe);
	msleep(600);
	ret = lt6911uxe_upgrade_result(lt6911uxe);
	if (ret)
		dev_err(dev, "firmware verification failed: %d\n", ret);
	else
		dev_info(dev, "manual firmware upgrade completed\n");

out_disable_i2c:
	lt6911uxe_i2c_disable(lt6911uxe);

	if (lt6911uxe->fw_tmp) {
		kfree(lt6911uxe->fw_tmp);
		lt6911uxe->fw_tmp = NULL;
	}

	if (ret)
		return ret;

	return count;
}

static ssize_t firmware_upgrade_show(struct device *dev,
			struct device_attribute *attr, char *buf)
{
	struct lt6911uxe *lt6911uxe = dev_get_drvdata(dev);

	lt6911uxe_i2c_enable(lt6911uxe);
	lt6911uxe->ver = lt6911uxe_read_version(lt6911uxe);
	lt6911uxe_i2c_disable(lt6911uxe);
	return scnprintf(buf, PAGE_SIZE, "0x%06llx\n", lt6911uxe->ver);
}

static ssize_t status_show(struct device *dev,
			   struct device_attribute *attr, char *buf)
{
	struct lt6911uxe *lt6911uxe = dev_get_drvdata(dev);
	struct lt6911uxe_rx_status status;
	int ret;

	ret = lt6911uxe_i2c_enable(lt6911uxe);
	if (ret)
		return scnprintf(buf, PAGE_SIZE, "i2c enable failed: %d\n", ret);

	ret = lt6911uxe_get_rx_status(lt6911uxe, &status);
	lt6911uxe_i2c_disable(lt6911uxe);
	if (ret)
		return scnprintf(buf, PAGE_SIZE, "rx status read failed: %d\n", ret);

	return scnprintf(buf, PAGE_SIZE,
			 "e080=0x%02x e081=0x%02x e082=0x%02x e083=0x%02x int=0x%02x lanes=%u fmt=0x%02x act=%ux%u total=%ux%u pclk=%llu byteclk=%llu audio_fs=0x%04x\n",
			 status.reg80, status.reg81, status.reg82, status.reg83,
			 status.int_type, status.lane_num, status.bus_fmt,
			 status.hact, status.vact, status.htotal, status.vtotal,
			 status.pixel_clock, status.byte_clock, status.audio_fs);
}

static ssize_t firmware_status_show(struct device *dev,
				    struct device_attribute *attr, char *buf)
{
	struct lt6911uxe *lt6911uxe = dev_get_drvdata(dev);
	u32 file_version = 0;
	u8 file_crc = 0;
	u8 flash_crc = 0;
	u64 chip_version = 0;
	int file_ret;
	int i2c_ret;
	int flash_ret = 0;
	int version_match = -1;
	int need_upgrade = -1;
	bool has_file_version;

	file_ret = lt6911uxe_prepare_firmware_data(lt6911uxe);
	if (!file_ret)
		file_crc = lt6911uxe->fw_crc;

	i2c_ret = lt6911uxe_i2c_enable(lt6911uxe);
	if (!i2c_ret) {
		chip_version = lt6911uxe_read_version(lt6911uxe);
		flash_ret = lt6911uxe_read_flash_crc(lt6911uxe, &flash_crc);
		lt6911uxe_i2c_disable(lt6911uxe);
	}

	has_file_version = lt6911uxe_parse_fw_version_from_name(lt6911uxe->fw_name,
								&file_version);
	if (!i2c_ret && !flash_ret && !file_ret)
		need_upgrade = file_crc != flash_crc;
	if (has_file_version && !i2c_ret)
		version_match = file_version == (u32)chip_version;

	if (lt6911uxe->fw_tmp) {
		kfree(lt6911uxe->fw_tmp);
		lt6911uxe->fw_tmp = NULL;
	}

	return scnprintf(buf, PAGE_SIZE,
			 "fw_name=%s chip_ver=0x%08llx file_ver=%s0x%08x flash_crc=%s0x%02x file_crc=%s0x%02x version_match=%d need_upgrade=%d fw_load_err=%d i2c_err=%d flash_crc_err=%d\n",
			 lt6911uxe->fw_name,
			 chip_version,
			 has_file_version ? "" : "unknown:",
			 file_version,
			 flash_ret ? "error:" : "",
			 flash_crc,
			 file_ret ? "error:" : "",
			 file_crc,
			 version_match,
			 need_upgrade,
			 file_ret,
			 i2c_ret,
			 flash_ret);
}

static DEVICE_ATTR_RW(firmware_upgrade);
static DEVICE_ATTR_RO(status);
static DEVICE_ATTR_RO(firmware_status);

static struct attribute *lt6911uxe_sysfs_attrs[] = {
	&dev_attr_firmware_upgrade.attr,
	&dev_attr_status.attr,
	&dev_attr_firmware_status.attr,
	NULL,
};

static struct attribute_group lt6911uxe_sysfs_attr_grp = {
	.attrs = lt6911uxe_sysfs_attrs,
};

static int lt6911uxe_sysfs_init(struct device *dev)
{
	int rc = 0;

	if (!dev) {
		dev_err(dev, "%s: Invalid params\n", __func__);
		return -EINVAL;
	}

	rc = sysfs_create_group(&dev->kobj, &lt6911uxe_sysfs_attr_grp);
	if (rc)
		dev_err(dev,"%s: sysfs group creation failed %d\n", __func__, rc);
	return rc;
}

static void lt6911uxe_sysfs_remove(struct device *dev)
{
	if (!dev) {
		dev_err(dev, "%s: Invalid params\n", __func__);
		return;
	}
	sysfs_remove_group(&dev->kobj, &lt6911uxe_sysfs_attr_grp);
}

static int chip_parse_dts(struct lt6911uxe *lt6911uxe)
{
	struct device *dev = lt6911uxe->dev;

	lt6911uxe->fw_name = FW_FILE;
	of_property_read_string(dev->of_node, "firmware-name",
				&lt6911uxe->fw_name);

	lt6911uxe->power_gpio =
		devm_gpiod_get_optional(dev, "power", GPIOD_OUT_HIGH);
	if (IS_ERR(lt6911uxe->power_gpio)) {
		dev_err(dev, "Failed to get power GPIO\n");
		return PTR_ERR(lt6911uxe->power_gpio);
	}

	lt6911uxe->reset_gpio =
		devm_gpiod_get_optional(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(lt6911uxe->reset_gpio)) {
		dev_err(dev, "Failed to get reset GPIO\n");
		return PTR_ERR(lt6911uxe->reset_gpio);
	}

	lt6911uxe->hdmi_reset_gpio =
		devm_gpiod_get_optional(dev, "hdmi-reset", GPIOD_OUT_LOW);
	if (IS_ERR(lt6911uxe->hdmi_reset_gpio)) {
		dev_err(dev, "Failed to get hdmi-reset GPIO\n");
		return PTR_ERR(lt6911uxe->hdmi_reset_gpio);
	}

	lt6911uxe->interrupt_gpio =
		devm_gpiod_get_optional(dev, "interrupt", GPIOD_IN);
	if (IS_ERR(lt6911uxe->interrupt_gpio)) {
		dev_err(dev, "Failed to get interrupt GPIO\n");
		return PTR_ERR(lt6911uxe->interrupt_gpio);
	}

	dev_info(dev, "use firmware: %s\n", lt6911uxe->fw_name);
	lt6911uxe_log_interrupt_gpio(lt6911uxe, "parse_dts");

	return 0;
}

static int lt6911uxe_main(void *data)
{
	int ret;
	struct lt6911uxe *lt6911uxe = data;
	struct device *dev = lt6911uxe->dev;
	struct lt6911uxe_rx_status status;
	u32 target_version = 0;
	bool has_target_version;

	lt6911uxe_power_on(lt6911uxe);
	msleep(1000);
	lt6911uxe_log_interrupt_gpio(lt6911uxe, "before_reset");
	lt6911uxe_reset(lt6911uxe);
	msleep(500);
	lt6911uxe_log_interrupt_gpio(lt6911uxe, "before_i2c_enable");
	dev_info(dev, "start auto firmware flow\n");
	ret = lt6911uxe_i2c_enable(lt6911uxe);
	if (ret) {
		lt6911uxe_log_interrupt_gpio(lt6911uxe, "i2c_enable_failed");
		dev_err(dev, "i2c communication failed!\n");
		return ret;
	}

	lt6911uxe_chip_id(lt6911uxe);
	lt6911uxe_dump_e080_e083(lt6911uxe);
	ret = lt6911uxe_get_rx_status(lt6911uxe, &status);
	if (!ret)
		lt6911uxe_log_rx_status(lt6911uxe, &status);
	else
		dev_warn(dev, "failed to read rx status: %d\n", ret);

	lt6911uxe->ver = lt6911uxe_read_version(lt6911uxe);
	has_target_version = lt6911uxe_parse_fw_version_from_name(lt6911uxe->fw_name,
								  &target_version);
	if (has_target_version) {
		if ((u32)lt6911uxe->ver == target_version) {
			dev_info(dev,
				 "firmware version matches target 0x%08x, skip auto upgrade\n",
				 target_version);
			ret = 0;
			goto out_reset_disable_i2c;
		}

		dev_info(dev,
			 "firmware version mismatch: current=0x%08llx target=0x%08x, prepare auto upgrade\n",
			 lt6911uxe->ver, target_version);
	} else {
		dev_warn(dev,
			 "failed to parse target version from %s, fallback to crc check\n",
			 lt6911uxe->fw_name);
	}

	lt6911uxe_i2c_disable(lt6911uxe);

	ret = lt6911uxe_prepare_firmware_data_retry(lt6911uxe);
	if (ret < 0) {
		dev_err(dev, "Failed to prepare firmware data: %d\n", ret);
		goto out_free_fw;
	}

	ret = lt6911uxe_i2c_enable(lt6911uxe);
	if (ret) {
		dev_err(dev, "failed to re-enable lt6911uxe i2c: %d\n", ret);
		goto out_free_fw;
	}

	ret = lt6911uxe_upgrade_judgment(lt6911uxe);
	if (ret < 0) {
		dev_err(dev, "failed to judge firmware upgrade: %d\n", ret);
		goto out_disable_i2c;
	}
	if (ret) {
		dev_info(dev, "crc is different, need to upgrade the firmware");
		ret = lt6911uxe_firmware_upgrade(lt6911uxe);
		if (ret < 0) {
			goto out_disable_i2c;
		}

		lt6911uxe_reset(lt6911uxe);
		msleep(1000);
		ret = lt6911uxe_upgrade_result(lt6911uxe);
		if (ret)
			goto out_disable_i2c;

	} else {
		dev_info(dev, "crc is same, not need upgrade");
		ret = 0;
	}

	lt6911uxe->ver = lt6911uxe_read_version(lt6911uxe);

	dev_info(dev, "current  version is:0x%06llx\n", lt6911uxe->ver);
	goto out_reset_disable_i2c;

out_disable_i2c:
	lt6911uxe_i2c_disable(lt6911uxe);

out_free_fw:
	if (lt6911uxe->fw_tmp) {
		kfree(lt6911uxe->fw_tmp);
		lt6911uxe->fw_tmp = NULL;
	}

	return ret;

out_reset_disable_i2c:
	lt6911uxe_i2c_disable(lt6911uxe);
	lt6911uxe_reset(lt6911uxe);
	msleep(500);

	if (lt6911uxe->fw_tmp) {
		kfree(lt6911uxe->fw_tmp);
		lt6911uxe->fw_tmp = NULL;
	}

	return ret;
}

static int chip_probe(struct i2c_client *client, const struct i2c_device_id *id)
{
	int ret;
	struct lt6911uxe  *lt6911uxe;

	lt6911uxe = devm_kzalloc(&client->dev, sizeof(*lt6911uxe), GFP_KERNEL);
	if (lt6911uxe == NULL)
		return -ENOMEM;

	lt6911uxe->client = client;
	lt6911uxe->dev = &client->dev;

	ret = chip_parse_dts(lt6911uxe);
	if (ret) {
		dev_err(&client->dev, "Failed to parse device tree: %d\n", ret);
		return ret;
	}

	i2c_set_clientdata(client, lt6911uxe);
	mutex_init(&lt6911uxe->ocm_lock);

	ret = lt6911uxe_sysfs_init(&client->dev);
	if (ret)
		return ret;

	kthread_obj = kthread_run(lt6911uxe_main, lt6911uxe, "lt6911uxe_kthread");
	if (IS_ERR(kthread_obj)) {
		dev_err(&client->dev, "Failed to create kernel thread\n");
		lt6911uxe_sysfs_remove(&client->dev);
		return PTR_ERR(kthread_obj);
	}

	return 0;
}

static void chip_remove(struct i2c_client *client)
{
	struct lt6911uxe *lt6911uxe = i2c_get_clientdata(client);

	mutex_destroy(&lt6911uxe->ocm_lock);
	lt6911uxe_sysfs_remove(&client->dev);//manual upgrade remove

	if (lt6911uxe->fw_tmp) {
		kfree(lt6911uxe->fw_tmp);
		lt6911uxe->fw_tmp = NULL;
	}
	dev_info(lt6911uxe->dev, "driver removed\n");
}

static int chip_suspend(struct device *dev)
{
	struct lt6911uxe *lt6911uxe = dev_get_drvdata(dev);

	if (lt6911uxe->reset_gpio)
		gpiod_set_value(lt6911uxe->reset_gpio, 0);

	dev_info(lt6911uxe->dev, "lt6911uxe Suspend");
	return 0;
}

static int chip_resume(struct device *dev)
{
	struct lt6911uxe *lt6911uxe = dev_get_drvdata(dev);

	if (lt6911uxe->reset_gpio)
		gpiod_set_value(lt6911uxe->reset_gpio, 1);

	dev_info(lt6911uxe->dev, "lt6911uxe Resume");
	return 0;
}

static const struct dev_pm_ops chip_pm_ops = {
	.suspend = chip_suspend,
	.resume =  chip_resume,
};

static const struct i2c_device_id chip_ids[] = {
	{"lt6911uxe-dsi", 0},
	{ }
};
MODULE_DEVICE_TABLE(i2c, chip_ids);

static const struct of_device_id chip_id_table[] = {
	{.compatible = "lontium,lt6911uxe-dsi"},
	{ }
};
MODULE_DEVICE_TABLE(of, chip_id_table);

static struct i2c_driver chip_driver = {
	.driver = {
		.owner = THIS_MODULE,
		.name = "lt6911uxe-dsi",
		.pm = &chip_pm_ops,
		.of_match_table = chip_id_table,

	},
	.probe    = chip_probe,
	.remove   = chip_remove,
	.id_table = chip_ids,
};

module_i2c_driver(chip_driver);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("lt6911uxe driver");
MODULE_AUTHOR("Tony <syyang@lontium.com>");
