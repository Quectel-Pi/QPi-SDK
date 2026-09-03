// SPDX-License-Identifier: GPL-2.0
/*******************************************************************************
 **** Copyright (C), 2022, Shanghai awinic technology Co.,Ltd.
												all rights reserved. ***********
 *******************************************************************************
 * File Name     : tcpc_aw35616.c
 * Author        : awinic
 * Date          : 2022-12-16
 * Description   : .C file function description
 * Version       : 1.0
 * Function List :
 ******************************************************************************/
#include <linux/init.h>
#include <linux/module.h>
#include <linux/device.h>
#include <linux/slab.h>
#include <linux/i2c.h>
#include <linux/of_gpio.h>
#include <linux/gpio.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/interrupt.h>
#include <linux/semaphore.h>
#include <linux/pm_runtime.h>
#include <linux/workqueue.h>
#include <linux/kthread.h>
#include <linux/cpu.h>
#include <linux/version.h>
#include <linux/pm_wakeup.h>
#include <linux/sched/clock.h>
#include <linux/sched/types.h>
#include <linux/kernel.h>
#include <linux/compiler.h>
#include <linux/mutex.h>
#include <linux/atomic.h>
#include <linux/hrtimer.h>
#include <linux/sched/rt.h>
#include <uapi/linux/sched/types.h>
#include <linux/usb/typec.h>
#include <linux/usb/role.h>
#include <linux/regulator/consumer.h>

#include "typec_aw35616.h"

#define AW35616_DRIVER_VERSION	"V0.1.0"

#define AW35616_IRQ_WAKE_TIME	(1000) /* ms */
#define AW35616_STATUS_CHECK_TIME	(500) /* ms */

const unsigned char aw35616_reg_access[AW35616_REG_MAX] = {
	[AW35616_REG_DEV_ID] = REG_RD_ACCESS,
	[AW35616_REG_CTR] = REG_RD_ACCESS|REG_WR_ACCESS,
	[AW35616_REG_INT] = REG_RD_ACCESS,
	[AW35616_REG_STATUS] = REG_RD_ACCESS,
	[AW35616_REG_STATUS1] = REG_RD_ACCESS,
	[AW35616_REG_RSTN] = REG_WR_ACCESS,
	[AW35616_REG_USB_VID0] = REG_RD_ACCESS,
	[AW35616_REG_USB_VID1] = REG_RD_ACCESS,
	[AW35616_REG_CTR2] = REG_RD_ACCESS|REG_WR_ACCESS
};

/******************************************************
 *
 * aw35616 i2c write/read
 *
 ******************************************************/
static int aw35616_i2c_write(struct aw35616_chip *chip,
		u8 reg_addr, u8 reg_data)
{
	int ret = -1;
	unsigned char cnt = 0;

	__pm_stay_awake(chip->for_i2c_wake_lock);

	while (cnt++ < AW35616_I2C_RETRIES) {
		ret = i2c_smbus_write_byte_data(chip->client, reg_addr, reg_data);
		if (ret < 0) {
			pr_err("%s: i2c_write cnt=%d error=%d\n", __func__,
					cnt, ret);
		} else {
			break;
		}
		usleep_range(1000, 2000);
	}

	__pm_relax(chip->for_i2c_wake_lock);

	return ret;
}

static int aw35616_i2c_read(struct aw35616_chip *chip,
		u8 reg_addr, u8 *reg_data)
{
	int ret = -1;
	unsigned char cnt = 0;

	__pm_stay_awake(chip->for_i2c_wake_lock);

	while (cnt++ < AW35616_I2C_RETRIES) {
		ret = i2c_smbus_read_byte_data(chip->client, reg_addr);
		if (ret < 0) {
			pr_err("%s: i2c_read cnt=%d error=%d\n", __func__,
					cnt, ret);
		} else {
			*reg_data = ret;
			break;
		}
		usleep_range(1000, 2000);
	}

	__pm_relax(chip->for_i2c_wake_lock);

	return ret;
}

static int aw35616_i2c_read_bits(struct aw35616_chip *chip,
		u8 reg_addr, u8 *buf, u8 len)
{
	int ret = 0;
	unsigned char *rdbuf = NULL;
	unsigned char cnt = 0;
	struct i2c_msg msgs[] = {
		{
			.addr	 = chip->client->addr,
			.flags  = 0,
			.len	 = 1,
			.buf	 = &reg_addr,
		},
		{
			.addr	 = chip->client->addr,
			.flags  = I2C_M_RD,
			.len	 = len,
		},
	};

	__pm_stay_awake(chip->for_i2c_wake_lock);

	if (chip->client == NULL) {
		pr_err("msg %s i2c client is NULL\n", __func__);
		return -ENODEV;
	}

	rdbuf = kmalloc(len, GFP_KERNEL);
	if (rdbuf == NULL)
		return -ENOMEM;

	msgs[1].buf = rdbuf;

	while (cnt < AW35616_I2C_RETRIES) {
		ret = i2c_transfer(chip->client->adapter, msgs, ARRAY_SIZE(msgs));
		if (ret < 0)
			pr_err("msg %s i2c read error: %d\n", __func__, ret);
		else
			break;
		cnt++;
		usleep_range(1000, 2000);
	}

	if (buf != NULL)
		memcpy(buf, rdbuf, len);

	kfree(rdbuf);

	__pm_relax(chip->for_i2c_wake_lock);

	return ret;
}

static int aw35616_set_vbus(struct aw35616_chip *chip, bool on)
{
	int ret;

	if (!chip->vbus)
		return 0;

	if (chip->vbus_on == on)
		return 0;

	if (on) {
		ret = regulator_enable(chip->vbus);
		AW_LOG("enable vbus for otg mode\n");
	} else {
		ret = regulator_disable(chip->vbus);
		AW_LOG("disable vbus\n");
	}

	if (ret < 0) {
		dev_err(chip->dev, "failed to %s vbus: %d\n",
			on ? "enable" : "disable", ret);
		return ret;
	}

	chip->vbus_on = on;

	return 0;
}

static int aw35616_tcpc_init(struct aw35616_chip *chip)
{
	AW_LOG("enter\n");

		/* set toggle cycle time */
	chip->reg.ctr2.tog_save_md = chip->toggle_cycle;
	aw35616_i2c_write(chip, AW35616_REG_CTR2, chip->reg.ctr2.byte);

	/* set power role mode */
	switch (chip->role_def) {
	case 1: /* set only sink */
		chip->reg.ctr.wkmd = SNK;
		chip->reg.ctr.try_md = NO_TRY;
		break;
	case 2: /* set only source */
		chip->reg.ctr.wkmd = SRC;
		chip->reg.ctr.try_md = NO_TRY;
		break;
	case 3: /* set only drp */
		chip->reg.ctr.wkmd = DRP;
		chip->reg.ctr.try_md = NO_TRY;
		break;
	case 4: /* set try src */
		chip->reg.ctr.wkmd = DRP;
		chip->reg.ctr.try_md = TRY_SRC;
		break;
	case 5: /* set try snk */
		chip->reg.ctr.wkmd = DRP;
		chip->reg.ctr.try_md = TRY_SNK;
		break;
	default:
		break;
	}

	/* set source current */
	chip->reg.ctr.src_cur_md = chip->rp_lvl;

	/* set acc mode */
	chip->reg.ctr.accdis = chip->acc_support;
	aw35616_i2c_write(chip, AW35616_REG_CTR, chip->reg.ctr.byte);
	aw35616_i2c_write(chip, AW35616_reg_val1, AW35616_reg_val2);
	aw35616_i2c_write(chip, AW35616_reg_val3, AW35616_reg_val4);
	aw35616_i2c_write(chip, AW35616_reg_val1, AW35616_reg_val5);

	/* The first detection interrupt can be completed. delay 150ms */
	msleep(150);

	schedule_delayed_work(&chip->first_check_typec_work, msecs_to_jiffies(5000));

	return 0;
}

static int first_check_flag;

static enum typec_orientation aw35616_get_orientation(struct aw35616_chip *chip)
{
	switch (chip->reg.status.plug_ori) {
	case CC1:
		return TYPEC_ORIENTATION_NORMAL;
	case CC2:
		return TYPEC_ORIENTATION_REVERSE;
	default:
		return TYPEC_ORIENTATION_NONE;
	}
}

static void aw35616_set_orientation(struct aw35616_chip *chip,
				    enum typec_orientation orientation)
{
	int ret;

	ret = typec_set_orientation(chip->port, orientation);
	if (ret)
		AW_LOG("typec_set_orientation(%d) ret=%d\n",
		       orientation, ret);
	else
		AW_LOG("typec_set_orientation(%d) OK\n", orientation);
}

static int aw35616_set_usb_role(struct aw35616_chip *chip, enum usb_role role)
{
	enum usb_role current_role;
	int ret;

	/*
	 * Wait for the previous DWC3 mode switch to finish before issuing
	 * the next one.  dwc3_set_mode() only sets desired_dr_role and
	 * queue_work()s __dwc3_set_mode; it does NOT block until the XHCI
	 * host_exit / gadget_exit + GCTL core soft reset sequence completes.
	 * A rapid attach->detach->attach (or detach->attach) sequence thus
	 * overlaps two async drd_work executions: the previous XHCI teardown
	 * is still running when the new mode is forced in, which drives the
	 * DWC3 PHY state machine into a dead "illegal mode" / zombie state
	 * that is neither Host nor Device.  The GCTL core soft reset path
	 * itself waits 100ms for clock sync (core.c), so 100ms is the
	 * minimum sane debounce here.
	 */
	msleep(100);

	ret = usb_role_switch_set_role(chip->role_sw, role);
	current_role = usb_role_switch_get_role(chip->role_sw);
	AW_LOG("usb_role_switch_set_role(%s) ret=%d current=%s\n",
	       usb_role_string(role), ret, usb_role_string(current_role));

	return ret;
}

static void aw35616_schedule_status_check(struct aw35616_chip *chip)
{
	schedule_delayed_work(&chip->status_check_work,
			      msecs_to_jiffies(AW35616_STATUS_CHECK_TIME));
}

static void aw35616_handle_detach(struct aw35616_chip *chip, const char *reason)
{
	gpiod_set_value(chip->sel_gpio, 1);
	AW_LOG("plug out, reason=%s last_plug_st=%d\n",
	       reason, chip->last_plug_st);

	aw35616_set_vbus(chip, false);
	aw35616_set_usb_role(chip, USB_ROLE_HOST);
	aw35616_set_orientation(chip, TYPEC_ORIENTATION_NONE);
	typec_set_data_role(chip->port, TYPEC_HOST);
	typec_set_pwr_role(chip->port, TYPEC_SOURCE);

	chip->attached = false;
	chip->last_plug_st = STANDBY;
}

static void aw35616_handle_attach(struct aw35616_chip *chip)
{
	aw35616_i2c_read_bits(chip, AW35616_REG_STATUS,
			      chip->reg.status.byte, 2);
	AW_LOG("plug_st = %d snk_det_rp_dbg = %d\n",
	       chip->reg.status.plug_st, chip->reg.status.snk_det_rp_dbg);

	switch (chip->reg.status.plug_st) {
	case STANDBY:
		AW_LOG("plug status not connected\n");
		aw35616_handle_detach(chip, "attach-standby");
		break;
	case SINK:
		AW_LOG("plug int SINK\n");
		gpiod_set_value(chip->sel_gpio, 1);
		chip->attached = true;
		chip->last_plug_st = SINK;
		aw35616_set_orientation(chip, aw35616_get_orientation(chip));
		aw35616_set_usb_role(chip, USB_ROLE_HOST);
		aw35616_set_vbus(chip, true);
		typec_set_data_role(chip->port, TYPEC_HOST);
		typec_set_pwr_role(chip->port, TYPEC_SOURCE);
		typec_set_vconn_role(chip->port, TYPEC_SOURCE);
		aw35616_schedule_status_check(chip);
		break;
	case SOURCE:
		AW_LOG("plug int SOURCE\n");
		gpiod_set_value(chip->sel_gpio, 0);
		chip->attached = true;
		chip->last_plug_st = SOURCE;
		aw35616_set_orientation(chip, aw35616_get_orientation(chip));
		aw35616_set_usb_role(chip, USB_ROLE_DEVICE);
		typec_set_data_role(chip->port, TYPEC_DEVICE);
		typec_set_pwr_role(chip->port, TYPEC_SINK);
		aw35616_schedule_status_check(chip);
		break;
	case AUD_ACC:
		chip->attached = true;
		chip->last_plug_st = AUD_ACC;
		aw35616_schedule_status_check(chip);
		break;
	case DUG_ACC:
		chip->attached = true;
		chip->last_plug_st = DUG_ACC;
		aw35616_set_orientation(chip, aw35616_get_orientation(chip));
		if (chip->reg.status.snk_det_rp_dbg) {
			AW_LOG("plug int Rp-Rp\n");
			aw35616_set_usb_role(chip, USB_ROLE_DEVICE);
			typec_set_data_role(chip->port, TYPEC_DEVICE);
			typec_set_pwr_role(chip->port, TYPEC_SINK);
		} else {
			AW_LOG("plug int Rd-Rd\n");
		aw35616_set_usb_role(chip, USB_ROLE_HOST);
			aw35616_set_vbus(chip, true);
			typec_set_data_role(chip->port, TYPEC_HOST);
			typec_set_pwr_role(chip->port, TYPEC_SOURCE);
			typec_set_vconn_role(chip->port, TYPEC_SOURCE);
		}
		aw35616_schedule_status_check(chip);
		break;
	default:
		AW_LOG("plug status unknown = %d\n", chip->reg.status.plug_st);
		break;
	}
}

static void aw35616_handle_interrupt(struct aw35616_chip *chip, const char *reason)
{
	int i;
	u8 reg_data[4];

	aw35616_i2c_read(chip, AW35616_REG_INT, &chip->reg.ints.byte);
	AW_LOG("%s int_sts[0x%02x]\n", reason, chip->reg.ints.byte);

	switch (chip->reg.ints.intb_flag) {
	case NO_INTB:
		aw35616_i2c_read_bits(chip, AW35616_REG_CTR, reg_data, 4);
		for (i = 1; i < 5; i++)
			AW_LOG("reg:0x%02x=0x%02x\n", i, reg_data[i - 1]);
		break;
	case ATTACHED:
		aw35616_handle_attach(chip);
		break;
	case DETACHED:
		aw35616_handle_detach(chip, reason);
		break;
	default:
		AW_LOG("unknown int flag = %d\n", chip->reg.ints.intb_flag);
		break;
	}
}

static void aw35616_irq_work_handler(struct kthread_work *work)
{
	struct aw35616_chip *chip = container_of(work,
			struct aw35616_chip, irq_work);

	if (first_check_flag == 0)
		return;

	aw35616_handle_interrupt(chip, "irq");
}

static void aw35616_status_check_work(struct work_struct *work)
{
	struct aw35616_chip *chip = container_of(work,
			struct aw35616_chip, status_check_work.work);
	u8 int_sts;

	if (!chip->attached)
		return;

	aw35616_i2c_read(chip, AW35616_REG_INT, &int_sts);
	chip->reg.ints.byte = int_sts;
	if (chip->reg.ints.intb_flag == DETACHED) {
		AW_LOG("poll int_sts[0x%02x]\n", chip->reg.ints.byte);
		aw35616_handle_detach(chip, "poll-int");
		return;
	} else if (chip->reg.ints.intb_flag == ATTACHED) {
		AW_LOG("poll int_sts[0x%02x]\n", chip->reg.ints.byte);
		aw35616_handle_attach(chip);
		return;
	}

	aw35616_i2c_read_bits(chip, AW35616_REG_STATUS,
			      chip->reg.status.byte, 2);
	if (chip->reg.status.plug_st == STANDBY) {
		AW_LOG("poll detached, status=0x%02x status1=0x%02x\n",
		       chip->reg.status.byte[0], chip->reg.status.byte[1]);
		aw35616_handle_detach(chip, "poll-status");
		return;
	}

	aw35616_schedule_status_check(chip);
}

static irqreturn_t aw35616_intr_handler(int irq, void *data)
{
	struct aw35616_chip *chip = data;

	__pm_wakeup_event(chip->for_irq_wake_lock, AW35616_IRQ_WAKE_TIME);

	kthread_queue_work(&chip->irq_worker, &chip->irq_work);
	return IRQ_HANDLED;
}

static int aw35616_init_alert(struct aw35616_chip *chip)
{
	struct sched_param param = { .sched_priority = MAX_RT_PRIO - 1 };
	int ret;

	if (chip->client->irq) {
		chip->irq = chip->client->irq;
	} else {
		ret = devm_gpio_request(chip->dev, chip->irq_gpio, "aw35616,irq-gpio");
		if (ret < 0) {
			pr_err("Error: failed to request GPIO%d (ret = %d)\n", chip->irq_gpio, ret);
			goto init_alert_err;
		}
		AW_LOG("gpio = %d\n", chip->irq_gpio);

		ret = gpio_direction_input(chip->irq_gpio);
		if (ret < 0) {
			pr_err("Error: failed to set GPIO%d as input pin(ret = %d)\n", chip->irq_gpio, ret);
			goto init_alert_err;
		}

		chip->irq = gpio_to_irq(chip->irq_gpio);
		if (chip->irq <= 0) {
			pr_err("%s gpio to irq fail, chip->irq(%d)\n", __func__, chip->irq);
			goto init_alert_err;
		}
	}

	AW_LOG("IRQ number = %d\n", chip->irq);

	kthread_init_worker(&chip->irq_worker);
	chip->irq_worker_task = kthread_run(kthread_worker_fn, &chip->irq_worker, "aw35616_worker");
	if (IS_ERR(chip->irq_worker_task)) {
		pr_err("Error: Could not create tcpc task\n");
		goto init_alert_err;
	}

	sched_setscheduler(chip->irq_worker_task, SCHED_FIFO, &param);
	kthread_init_work(&chip->irq_work, aw35616_irq_work_handler);

	ret = request_irq(chip->irq, aw35616_intr_handler,
			IRQF_SHARED | IRQF_TRIGGER_RISING | IRQF_TRIGGER_FALLING | IRQF_NO_THREAD |
			IRQF_NO_SUSPEND, "awinic,int_n", chip);
	if (ret < 0) {
		pr_err("Error: failed to request irq%d (gpio = %d, ret = %d)\n",
			chip->irq, chip->irq_gpio, ret);
		goto init_alert_err;
	}

	enable_irq_wake(chip->irq);
	return 0;

init_alert_err:
	return -EINVAL;
}

static int aw35616_parse_dt(struct aw35616_chip *chip, struct device *dev)
{
	struct device_node *np = dev->of_node;
	u32 val;

	if (!np)
		return -EINVAL;

	AW_LOG("enter\n");

	if (of_property_read_u32(np, "aw35616-tcpc,role_def", &val) >= 0) {
		chip->role_def = val;
		AW_LOG("aw35616_role_def = %d\n", chip->role_def);
	} else {
		dev_err(chip->dev, "use default Role DRP\n");
		chip->role_def = 3;
	}

	if (of_property_read_u32(np, "aw35616,rp_level", &val) >= 0) {
		switch (val) {
		case 0: /* RP Default */
			chip->rp_lvl = SRC_DEF;
			break;
		case 1: /* RP 1.5V */
			chip->rp_lvl = SRC_1_5A;
			break;
		case 2: /* RP 3.0V */
			chip->rp_lvl = SRC_3_0A;
			break;
		default:
			break;
		}
		AW_LOG("aw35616_rp_level = %d\n", chip->rp_lvl);
	} else {
		dev_err(chip->dev, "use default Rp lvl\n");
		chip->rp_lvl = SRC_DEF;
	}

	if (of_property_read_u32(np, "aw35616_acc_support", &val) >= 0) {
		chip->acc_support = (bool)val;
		AW_LOG("aw35616_acc_support = %d\n", chip->acc_support);
	} else {
		dev_err(chip->dev, "use default val\n");
		chip->acc_support = 0;
	}

	if (of_property_read_u32(np, "aw35616_toggle_cycle", &val) >= 0) {
		chip->toggle_cycle = (uint8_t)val;
		AW_LOG("aw35616_toggle_cycle = %d\n", chip->toggle_cycle);
	} else {
		dev_err(chip->dev, "use default val\n");
		chip->toggle_cycle = 0;
	}

	return 0;
}

static void aw35616_first_check_typec_work(struct work_struct *work)
{
	struct aw35616_chip *chip = container_of(work,
			struct aw35616_chip, first_check_typec_work.work);

	first_check_flag = 1;
	aw35616_handle_interrupt(chip, "first-check");
}

static inline bool aw35616_check_revision(struct i2c_client *client)
{
	int rc = 0;
	int i = 0;

	for (i = 0; i <= AW35616_CHECK_RETEY; i++) {
		/* Read chip id */
		rc = i2c_smbus_read_byte_data(client, AW35616_REG_DEV_ID);
		if (rc >= 0) {
			if ((rc & 0x7) == AW35616_VENDOR_ID)
				AW_LOG("Device check passed chip id = 0x%x\n", rc);
			return true;
		}

		AW_LOG("ERROR: Could not communicate with device over i2c!\n");
		usleep_range(1000, 2000);
	}

	return false;
}

static void aw35616_init_reg(struct aw35616_chip *chip)
{
	chip->reg.rstn.sft_rstn = 1;
	aw35616_i2c_write(chip, AW35616_REG_RSTN, chip->reg.rstn.byte);
	chip->reg.rstn.sft_rstn = 0;
	/* Detect between gpio and i2c modes */
	msleep(30);
	aw35616_i2c_read(chip, AW35616_REG_DEV_ID, &chip->reg.dev_id.byte);
	aw35616_i2c_read(chip, AW35616_REG_CTR, &chip->reg.ctr.byte);
	aw35616_i2c_read_bits(chip, AW35616_REG_STATUS, chip->reg.status.byte, 2);
	aw35616_i2c_read_bits(chip, AW35616_REG_USB_VID0, chip->reg.vid.byte, 2);
	aw35616_i2c_read(chip, AW35616_REG_CTR2, &chip->reg.ctr2.byte);
}

static int aw35616_dr_set(struct typec_port *port, enum typec_data_role role)
{
	struct aw35616_chip *aw35616 = typec_get_drvdata(port);
	enum usb_role role_val;
	int ret = 0;

	if (role == TYPEC_HOST)
		role_val = USB_ROLE_HOST;
	else
		role_val = USB_ROLE_DEVICE;

	usb_role_switch_set_role(aw35616->role_sw, role_val);
	typec_set_data_role(aw35616->port, role);

	return ret;
}

static const struct typec_operations aw35616_ops = {
	.dr_set = aw35616_dr_set
};

/******************************************************
 *
 * sys group attribute: reg
 *
 ******************************************************/
static ssize_t regdump_show(struct device *dev,
		struct device_attribute *attr, char *buf)
{
	struct i2c_client *client = to_i2c_client(dev);
	struct aw35616_chip *chip = i2c_get_clientdata(client);
	ssize_t len = 0;
	unsigned char i = 0;
	unsigned char reg_val = 0;

	for (i = 0; i < AW35616_REG_MAX; i++) {
		if (!(aw35616_reg_access[i] & REG_RD_ACCESS))
			continue;
		aw35616_i2c_read(chip, i, &reg_val);
		AW_LOG("i = %d reg_val = %x\n", i, reg_val);
		len += snprintf(buf + len, PAGE_SIZE - len, "reg:0x%02x=0x%02x\n",
				i, reg_val);
	}

	return len;
}

static ssize_t regdump_store(struct device *dev,
		struct device_attribute *attr, const char *buf, size_t count)
{
	struct i2c_client *client = to_i2c_client(dev);
	struct aw35616_chip *chip = i2c_get_clientdata(client);
	u32 databuf[2] = {0, 0};

	if (sscanf(buf, "%x %x", &databuf[0], &databuf[1]) == 2)
		aw35616_i2c_write(chip, (u8)databuf[0], (u8)databuf[1]);

	return count;
}
DEVICE_ATTR_RW(regdump);

static ssize_t typec_polarity_show(struct device *dev,
		struct device_attribute *attr, char *buf)
{
	struct i2c_client *client = to_i2c_client(dev);
	struct aw35616_chip *chip = i2c_get_clientdata(client);

	aw35616_i2c_read(chip, AW35616_REG_STATUS, &chip->reg.status.byte[0]);
	AW_LOG("reg_val[0x04] = %x\n", chip->reg.status.byte[0]);

	return sprintf(buf, "%s\n",
			(chip->reg.status.plug_ori == CC1) ? "CC1" :
			(chip->reg.status.plug_ori == CC2) ? "CC2" :
			(chip->reg.status.plug_ori == CC1_CC2) ? "CC1&&CC2" : "None");
}
DEVICE_ATTR_RO(typec_polarity);

static int aw35616_i2c_probe(struct i2c_client *client,
		const struct i2c_device_id *id)
{
	struct aw35616_chip *chip;
	struct typec_capability typec_cap = { };
	struct fwnode_handle *connector, *ep, *remote;
	int ret;
	bool chip_ret;

	AW_LOG("enter\n");
	if (i2c_check_functionality(client->adapter,
			I2C_FUNC_SMBUS_I2C_BLOCK | I2C_FUNC_SMBUS_BYTE_DATA))
		AW_LOG("I2C functionality : OK...\n");
	else
		pr_err("I2C functionality check : failuare...\n");

	chip_ret = aw35616_check_revision(client);
	if (chip_ret == false) {
		pr_err("aw35616 init fail\n");
		return -ENODEV;
	}

	chip = devm_kzalloc(&client->dev, sizeof(*chip), GFP_KERNEL);
	if (!chip)
		return -ENOMEM;

	chip->dev = &client->dev;
	chip->client = client;

	ret = aw35616_parse_dt(chip, &client->dev);
	if (ret < 0)
		return ret;

	sema_init(&chip->suspend_lock, 1);
	i2c_set_clientdata(client, chip);

	chip->vbus = devm_regulator_get_optional(chip->dev, "vbus");
	if (IS_ERR(chip->vbus)) {
		ret = PTR_ERR(chip->vbus);
		if (ret == -ENODEV) {
			chip->vbus = NULL;
		} else {
			return ret;
		}
	}

	chip->sel_gpio = devm_gpiod_get_optional(chip->dev, "usb0-sel", GPIOD_OUT_LOW);
	if (IS_ERR(chip->sel_gpio))
		chip->sel_gpio = NULL;
	else if (chip->sel_gpio)
		AW_LOG("sel_gpio OK\n");

	INIT_DELAYED_WORK(&chip->first_check_typec_work,
			aw35616_first_check_typec_work);
	INIT_DELAYED_WORK(&chip->status_check_work,
			aw35616_status_check_work);
	chip->for_irq_wake_lock =
		wakeup_source_register(chip->dev, "aw35616_irq_wakelock");
	chip->for_i2c_wake_lock =
		wakeup_source_register(chip->dev, "aw35616_i2c_wakelock");

	aw35616_init_reg(chip);

	/*
	 * The role-switch graph is on the AW35616 device node:
	 * aw35616/port -> dwc3/port.  The connector child only carries the
	 * Type-C connector capabilities and orientation-switch graph.
	 */
	connector = device_get_named_child_node(chip->dev, "connector");
	if (!connector)
		return dev_err_probe(chip->dev, -ENODEV,
				     "connector fwnode missing\n");

	ep = fwnode_graph_get_next_endpoint(dev_fwnode(chip->dev), NULL);
	if (ep) {
		remote = fwnode_graph_get_remote_port_parent(ep);
		fwnode_handle_put(ep);
		if (remote) {
			chip->role_sw = fwnode_usb_role_switch_get(remote);
			fwnode_handle_put(remote);
		}
	}

	if (!chip->role_sw)
		chip->role_sw = usb_role_switch_get(chip->dev);

	if (IS_ERR(chip->role_sw)) {
		ret = PTR_ERR(chip->role_sw);
		dev_err_probe(chip->dev, ret, "failed to get usb role switch\n");
		goto err_put_fwnode;
	}

	dev_info(chip->dev, "usb role switch linked, current role=%s\n",
		 usb_role_string(usb_role_switch_get_role(chip->role_sw)));

	typec_cap.prefer_role = TYPEC_NO_PREFERRED_ROLE;
	typec_cap.driver_data = chip;
	typec_cap.type = TYPEC_PORT_DRP;
	typec_cap.data = TYPEC_PORT_DRD;
	typec_cap.ops = &aw35616_ops;
	typec_cap.fwnode = connector;

	chip->port = typec_register_port(&client->dev, &typec_cap);
	if (IS_ERR(chip->port)) {
		ret = PTR_ERR(chip->port);
		goto err_put_role;
	}

	ret = aw35616_init_alert(chip);
	if (ret < 0) {
		pr_err("aw35616 init alert fail\n");
		goto err_unreg_port;
	}

	ret = device_create_file(&client->dev, &dev_attr_regdump);
	if (ret < 0) {
		dev_err(&client->dev, "failed to create regdump\n");
		ret = -ENODEV;
		goto err_unreg_port;
	}

	ret = device_create_file(&client->dev, &dev_attr_typec_polarity);
	if (ret < 0) {
		dev_err(&client->dev, "failed to create typec_polarity\n");
		ret = -ENODEV;
		goto err_create_fregdump_file;
	}

	aw35616_tcpc_init(chip);

	/* Cold boot: force host so HUB works immediately */
	aw35616_set_usb_role(chip, USB_ROLE_DEVICE);
	AW_LOG("probe OK!\n");
	return 0;

err_create_fregdump_file:
	device_remove_file(&client->dev, &dev_attr_regdump);
err_unreg_port:
	typec_unregister_port(chip->port);
err_put_role:
	usb_role_switch_put(chip->role_sw);
err_put_fwnode:
	fwnode_handle_put(connector);
	wakeup_source_unregister(chip->for_i2c_wake_lock);
	wakeup_source_unregister(chip->for_irq_wake_lock);

	return ret;
}

static void aw35616_i2c_remove(struct i2c_client *client)
{
	struct aw35616_chip *chip = i2c_get_clientdata(client);

	if (chip) {
		cancel_delayed_work_sync(&chip->first_check_typec_work);
		cancel_delayed_work_sync(&chip->status_check_work);
		typec_unregister_port(chip->port);
		device_remove_file(&client->dev, &dev_attr_regdump);
		device_remove_file(&client->dev, &dev_attr_typec_polarity);
		aw35616_set_vbus(chip, false);
		wakeup_source_unregister(chip->for_i2c_wake_lock);
		wakeup_source_unregister(chip->for_irq_wake_lock);
	}
}

#ifdef CONFIG_PM
static int aw35616_i2c_suspend(struct device *dev)
{
	struct aw35616_chip *chip;
	struct i2c_client *client = to_i2c_client(dev);

	if (client) {
		chip = i2c_get_clientdata(client);
		if (chip)
			down(&chip->suspend_lock);
	}

	return 0;
}

static int aw35616_i2c_resume(struct device *dev)
{
	struct aw35616_chip *chip;
	struct i2c_client *client = to_i2c_client(dev);

	if (client) {
		chip = i2c_get_clientdata(client);
		if (chip)
			up(&chip->suspend_lock);
	}

	return 0;
}

static void aw35616_shutdown(struct i2c_client *client)
{
	struct aw35616_chip *chip = i2c_get_clientdata(client);

	/* Please reset IC here */
	chip->reg.rstn.sft_rstn = 0x1;
	aw35616_i2c_write(chip, AW35616_REG_RSTN, chip->reg.rstn.byte);
	if (chip != NULL) {
		aw35616_set_vbus(chip, false);
		if (chip->irq)
			disable_irq(chip->irq);
	}
}

#ifdef CONFIG_PM_RUNTIME
static int aw35616_pm_suspend_runtime(struct device *device)
{
	AW_LOG("pm_runtime: suspending...\n");
	return 0;
}

static int aw35616_pm_resume_runtime(struct device *device)
{
	AW_LOG("pm_runtime: resuming...\n");
	return 0;
}
#endif /* CONFIG_PM_RUNTIME */

static const struct dev_pm_ops aw35616_pm_ops = {
	SET_SYSTEM_SLEEP_PM_OPS(
			aw35616_i2c_suspend,
			aw35616_i2c_resume)
#ifdef CONFIG_PM_RUNTIME
	SET_RUNTIME_PM_OPS(
			aw35616_pm_suspend_runtime,
			aw35616_pm_resume_runtime,
			NULL
	)
#endif /* CONFIG_PM_RUNTIME */
};

#define aw35616_PM_OPS (&aw35616_pm_ops)
#else
#define aw35616_PM_OPS (NULL)
#endif /* CONFIG_PM */

static const struct i2c_device_id aw35616_id_table[] = {
	{"aw35616", 0},
	{},
};
MODULE_DEVICE_TABLE(i2c, aw35616_id_table);

static const struct of_device_id aw35616_match_table[] = {
	{.compatible = "awinic,usb_type_c_aw35616",},
	{},
};

static struct i2c_driver aw35616_driver = {
	.driver = {
		.name = "usb_type_c_aw35616",
		.owner = THIS_MODULE,
		.of_match_table = aw35616_match_table,
		.pm = aw35616_PM_OPS,
	},
	.probe = aw35616_i2c_probe,
	.remove = aw35616_i2c_remove,
	.shutdown = aw35616_shutdown,
	.id_table = aw35616_id_table,
};

static int __init aw35616_init(void)
{
	AW_LOG("start driver init\n");
	AW_LOG("aw35616 driver version %s\n", AW35616_DRIVER_VERSION);

	return i2c_add_driver(&aw35616_driver);
}
subsys_initcall(aw35616_init);

static void __exit aw35616_exit(void)
{
	i2c_del_driver(&aw35616_driver);
}
module_exit(aw35616_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("AWINIC");
MODULE_DESCRIPTION("aw35616 TCPC Driver");
MODULE_VERSION(AW35616_DRIVER_VERSION);
