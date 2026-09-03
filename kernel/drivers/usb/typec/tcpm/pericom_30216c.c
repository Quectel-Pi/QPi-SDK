#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/i2c.h>
#include <linux/interrupt.h>
#include <linux/delay.h>
#include <linux/regulator/consumer.h>
#include <linux/gpio/consumer.h>
#include <linux/err.h>
#include <linux/of.h>
#include <linux/property.h>
#include <linux/of_graph.h>
#include <linux/usb/typec.h>
#include <linux/usb/role.h>
#include <linux/bits.h>
#include "pericom_30216c.h"

#define DRIVER_NAME "pericom_30216c"

struct pericom_30216c_data {
	struct i2c_client *i2c_client;
	int irq;
	struct mutex i2c_rw_mutex;
	struct gpio_desc *sw_gpio;
	struct usb_role_switch *role_sw;
	struct typec_port *port;
	struct typec_partner *partner;
	bool connected;
};

static int pericom_30216c_i2c_read(struct pericom_30216c_data *pericom_data,
		unsigned char *data, unsigned short length)
{
	int retval;
	unsigned char retry;
	struct i2c_msg msg[] = {
		{
			.addr = pericom_data->i2c_client->addr,
			.flags = I2C_M_RD,
			.len = length,
			.buf = data,
		},
	};

	mutex_lock(&(pericom_data->i2c_rw_mutex));

	for (retry = 0; retry < PERICOM_I2C_RETRY_TIMES; retry++) {
		if (i2c_transfer(pericom_data->i2c_client->adapter, msg, 1) > 0) {
			retval = length;
			break;
		}
		dev_err(&pericom_data->i2c_client->dev,"%s: I2C retry %d\n", __func__, retry + 1);
		usleep_range(10000, 11000);
	}

	if (retry == PERICOM_I2C_RETRY_TIMES) {
		dev_err(&pericom_data->i2c_client->dev, "%s: I2C read fail\n", __func__);
		retval = -EIO;
	}

	mutex_unlock(&(pericom_data->i2c_rw_mutex));

	return retval;
}

static int pericom_30216c_i2c_write(struct pericom_30216c_data *pericom_data,
		unsigned char *data, unsigned short length)
{
	int retval;
	unsigned char retry;
	struct i2c_msg msg[] = {
		{
			.addr = pericom_data->i2c_client->addr,
			.flags = 0,
			.len = length,
			.buf = data,
		}
	};

	mutex_lock(&(pericom_data->i2c_rw_mutex));

	for (retry = 0; retry < PERICOM_I2C_RETRY_TIMES; retry++) {
		if (i2c_transfer(pericom_data->i2c_client->adapter, msg, 1) == 1) {
			retval = length;
			break;
		}
		dev_err(&pericom_data->i2c_client->dev,"%s: I2C retry %d\n", __func__, retry + 1);
		usleep_range(10000, 11000);
	}

	if (retry == PERICOM_I2C_RETRY_TIMES) {
		dev_err(&pericom_data->i2c_client->dev, "%s: I2C write fail\n", __func__);
		retval = -EIO;
	}

	mutex_unlock(&(pericom_data->i2c_rw_mutex));

	return retval;
}

static int pericom_30216c_set_power_mode(struct pericom_30216c_data *pericom_data, enum pericom_power_mode mode)
{
	int ret;
	char buf[2] = {0x20, 0};

	pericom_30216c_i2c_read(pericom_data, buf, 2);

	buf[1] = (buf[1] & ~PERICOM_POWER_SAVING_MASK) | ((mode << PERICOM_POWER_SAVING_OFFSET) & PERICOM_POWER_SAVING_MASK);
	buf[1] &= ~PERICOM_INTERRUPT_MASK;

	ret = pericom_30216c_i2c_write(pericom_data, buf, 2);
	return ret;
}

static int pericom_30216c_set_role_mode(struct pericom_30216c_data *pericom_data,
		enum pericom_role_mode mode)
{
	int ret, i;
	char buf[4] = {0, 0, 0, 0};
	uint8_t role_bits = 0;
	uint8_t try_bits = 0;

	pericom_30216c_i2c_read(pericom_data, buf, 2);
	
	switch (mode) {
		case DEVICE_MODE:
			role_bits = PERICOM_ROLE_DEVICE;
			break;
		case HOST_MODE:
			role_bits = PERICOM_ROLE_HOST;
			break;
		case DRP_MODE:
			role_bits = PERICOM_ROLE_DRP;
			break;
		case TRYSNK_DRP_MODE:
			role_bits = PERICOM_ROLE_DRP_TRY;
			try_bits = PERICOM_DRP2_TRY_SNK;
			break;
		default:
			role_bits = PERICOM_ROLE_DRP;
			break;
	}

	buf[1] &= ~(PERICOM_ROLE_MODE_MASK | PERICOM_DRP2_TRY_SNK);
	buf[1] |= (role_bits | try_bits);

	buf[1] |= PERICOM_INTERRUPT_MASK;
	
	ret = pericom_30216c_i2c_write(pericom_data, buf, 2);

	for (i = 0; i <= 5; i++) {
		msleep(50);
		pericom_30216c_i2c_read(pericom_data, buf, 4);
		
		if ((buf[1] & PERICOM_ROLE_MODE_MASK) == role_bits){
			break;
		}	
	}

	if (i > 5){
		dev_warn(&pericom_data->i2c_client->dev, "Warning: Set role to %d timed out\n", mode);
	}
		
	buf[1] &= ~PERICOM_INTERRUPT_MASK;
	ret = pericom_30216c_i2c_write(pericom_data, buf, 2);

	return ret;
}

static int pericom_30216c_set_trysnk_drp_mode(struct pericom_30216c_data *pericom_data)
{
	return pericom_30216c_set_role_mode(pericom_data, TRYSNK_DRP_MODE);
}

static int pericom_30216c_set_powersaving_mode(struct pericom_30216c_data *pericom_data)
{
	return pericom_30216c_set_power_mode(pericom_data, POWERSAVING_MODE);
}

static int pericom_30216c_set_poweractive_mode(struct pericom_30216c_data *pericom_data)
{
	return pericom_30216c_set_power_mode(pericom_data, ACTIVE_MODE);
}

static bool ic_is_present(struct pericom_30216c_data *pericom_data)
{
	int ret;
	unsigned char buf = 0; 

	ret = pericom_30216c_i2c_read(pericom_data, &buf, 1);

	if (ret < 0) {
		dev_err(&pericom_data->i2c_client->dev, "Failed to detect IC (I2C read error: %d)\n", ret);
		return false;
	}

	dev_info(&pericom_data->i2c_client->dev, "IC present! ret=%d, Device ID=0x%02x (Expected: 0x20)\n", ret, buf);

	return true;
}

static void pericom_30216c_apply_usb_role(struct pericom_30216c_data *pericom_data, 
                                          enum pericom_target_role target)
{
	int ret;

	if (target == PERICOM_SWITCH_TO_HOST) {
		if (pericom_data->role_sw) {
			ret = usb_role_switch_set_role(pericom_data->role_sw, USB_ROLE_HOST);
			dev_info(&pericom_data->i2c_client->dev, "usb_role_switch_set_role(HOST) ret=%d\n", ret);
		} else {
			dev_warn(&pericom_data->i2c_client->dev, "role_sw is NULL!\n");
		}
	
		if (pericom_data->port) {
			typec_set_data_role(pericom_data->port, TYPEC_HOST);
			typec_set_pwr_role(pericom_data->port, TYPEC_SOURCE);
			typec_set_vconn_role(pericom_data->port, TYPEC_SOURCE);
		}
		dev_info(&pericom_data->i2c_client->dev, ">> Action: Switching to HOST (Source) Mode\n");
	} else {
		if (pericom_data->role_sw) {
			ret = usb_role_switch_set_role(pericom_data->role_sw, USB_ROLE_DEVICE);
			dev_info(&pericom_data->i2c_client->dev, "usb_role_switch_set_role(DEVICE) ret=%d\n", ret);
		} else {
			dev_warn(&pericom_data->i2c_client->dev, "role_sw is NULL!\n");
		}
		
		if (pericom_data->port) {
			typec_set_data_role(pericom_data->port, TYPEC_DEVICE);
			typec_set_pwr_role(pericom_data->port, TYPEC_SINK);
			typec_set_vconn_role(pericom_data->port, TYPEC_SINK);
		}
		dev_info(&pericom_data->i2c_client->dev, ">> Action: Switching to DEVICE (Sink) Mode\n");
	}
}

static irqreturn_t pericom_30216c_irq_handler(int irq, void *dev_id)
{
	struct pericom_30216c_data *pericom_data = (struct pericom_30216c_data *)dev_id;
	char reg[4] = {0, 0, 0, 0};
	uint8_t interrupt_status;
	uint8_t attach_state;
	uint8_t cc_status;

	struct typec_partner_desc desc;
	memset(&desc, 0, sizeof(desc));
	desc.accessory = TYPEC_ACCESSORY_NONE;
	desc.identity = NULL;

	pericom_30216c_i2c_read(pericom_data, reg, 2);
	reg[1] |= PERICOM_INTERRUPT_MASK;
	pericom_30216c_i2c_write(pericom_data, reg, 2);

	msleep(30);

	pericom_30216c_i2c_read(pericom_data, reg, 4);
	
	interrupt_status = reg[2];  /* 0x03 Interrupt Register */
	attach_state = reg[3] & PERICOM_ATTACH_STATUS_MASK; 
	cc_status = reg[3] & CC_MASK;

	dev_info(&pericom_data->i2c_client->dev, "IRQ: Int=0x%x, CC_Stat=0x%x (AttachState=0x%x)\n", interrupt_status, reg[3], attach_state);

	if ((interrupt_status & PERICOM_INT_DETACH) || (attach_state == PERICOM_ATTACH_STANDBY)) {
		dev_info(&pericom_data->i2c_client->dev, "Event: Detach Detected\n");
		pericom_30216c_apply_usb_role(pericom_data, PERICOM_SWITCH_TO_DEVICE);
	}
	else if (interrupt_status & PERICOM_INT_ATTACH) {
		dev_info(&pericom_data->i2c_client->dev, "Event: Attach Detected\n");
		if (cc_status == CC1_STATUS) {
			gpiod_set_value_cansleep(pericom_data->sw_gpio, 1);
			dev_info(&pericom_data->i2c_client->dev, "CC1 connected\n");
		} else if (cc_status == CC2_STATUS) {
			gpiod_set_value_cansleep(pericom_data->sw_gpio, 0);
			dev_info(&pericom_data->i2c_client->dev, "CC2 connected\n");
		} else {
			dev_warn(&pericom_data->i2c_client->dev, "CC polarity undetermined\n");
		}

		switch (attach_state) {
			case PERICOM_ATTACH_HOST:
				pericom_30216c_apply_usb_role(pericom_data, PERICOM_SWITCH_TO_DEVICE); 
				break;

			case PERICOM_ATTACH_DEVICE:
				pericom_30216c_apply_usb_role(pericom_data, PERICOM_SWITCH_TO_HOST);
				break;

			case PERICOM_ATTACH_AUDIO_ACC:
				dev_info(&pericom_data->i2c_client->dev, "Mode: Audio Accessory [0x0C]\n");
				break;

			case PERICOM_ATTACH_DEBUG_ACC:
				dev_info(&pericom_data->i2c_client->dev, "Mode: Debug Accessory [0x10]\n");
				break;

			default:
				dev_warn(&pericom_data->i2c_client->dev, "Mode: Unknown/Reserved (0x%x)\n", attach_state);
				break;
		}
	}

	msleep(20);
	reg[1] &= ~PERICOM_INTERRUPT_MASK;
	pericom_30216c_i2c_write(pericom_data, reg, 2);

	return IRQ_HANDLED;
}

static int pericom_30216c_register_typec(struct device *dev, struct pericom_30216c_data *pericom_data)
{
	struct typec_capability typec_cap = { };
	struct fwnode_handle *connector, *ep;
	struct typec_partner_desc desc;
	int ret;

	connector = device_get_named_child_node(dev, "connector");
	if (!connector) {
		dev_info(dev, "No 'connector' child node, using graph endpoint\n");
		ep = fwnode_graph_get_next_endpoint(dev_fwnode(dev), NULL);
		if (!ep) {
			return dev_err_probe(dev, -ENODEV, "connector endpoint not defined\n");
		}
		
		connector = fwnode_graph_get_remote_port_parent(ep);
		fwnode_handle_put(ep);
		if (!connector) {
			return dev_err_probe(dev, -ENODEV, "connector fwnode missing\n");
		}
	}

	typec_cap.prefer_role = TYPEC_NO_PREFERRED_ROLE;
	typec_cap.driver_data = pericom_data;
	typec_cap.type = TYPEC_PORT_DRP;
	typec_cap.data = TYPEC_PORT_DRD;
	typec_cap.fwnode = connector;

	pericom_data->port = typec_register_port(dev, &typec_cap);
	if (IS_ERR(pericom_data->port)) {
		ret = dev_err_probe(dev, PTR_ERR(pericom_data->port), "Failed to register Type-C port\n");
		goto err_put_connector;
	}

	desc.accessory = TYPEC_ACCESSORY_NONE;
	desc.identity = NULL;
	pericom_data->partner = typec_register_partner(pericom_data->port, &desc);
	pericom_data->connected = true;

	
	ep = fwnode_graph_get_next_endpoint(dev_fwnode(dev), NULL);
	if (ep) {
		struct fwnode_handle *remote;
		remote = fwnode_graph_get_remote_port_parent(ep);
		if (remote) {
			pericom_data->role_sw = fwnode_usb_role_switch_get(remote);
			fwnode_handle_put(remote);
		}
		fwnode_handle_put(ep);
	}

	if (IS_ERR(pericom_data->role_sw)) {
		ret = PTR_ERR(pericom_data->role_sw);
		if (ret == -EPROBE_DEFER) {
			dev_err_probe(dev, ret, "Deferring: fwnode role switch not ready\n");
			goto err_unregister_partner;
		}
		pericom_data->role_sw = NULL;
	}

	if (!pericom_data->role_sw) {
		pericom_data->role_sw = usb_role_switch_get(dev);
	}

	if (IS_ERR(pericom_data->role_sw)) {
		ret = dev_err_probe(dev, PTR_ERR(pericom_data->role_sw), "Failed to get usb role switch\n");
		goto err_unregister_partner;
	}

	fwnode_handle_put(connector);
	dev_info(dev, "typec/role-switch registered\n");
	return 0;

err_unregister_partner:
	if (pericom_data->partner) {
		typec_unregister_partner(pericom_data->partner);
		pericom_data->partner = NULL;
	}

	if (pericom_data->port) {
		typec_unregister_port(pericom_data->port);
		pericom_data->port = NULL;
	}
err_put_connector:
	fwnode_handle_put(connector);
	return ret;
}

static int pericom_30216c_probe(struct i2c_client *client,
		const struct i2c_device_id *dev_id)
{
	int retval = 0;
	struct device *dev = &client->dev;
	struct pericom_30216c_data *pericom_data;

	dev_info(&client->dev, "%s: probe begin\n", __func__);

	if (!i2c_check_functionality(client->adapter, I2C_FUNC_SMBUS_BYTE_DATA)) {
		dev_err(&client->dev, "%s: SMBus byte data not supported\n", __func__);
		return -EIO;
	}

	pericom_data = devm_kzalloc(&client->dev, sizeof(*pericom_data), GFP_KERNEL);
	if (!pericom_data){
		dev_err(&client->dev, "%s: Failed to allocate memory\n", __func__);
		return -ENOMEM;
	}
		
	msleep(100);

	mutex_init(&(pericom_data->i2c_rw_mutex));
	pericom_data->i2c_client = client;
	pericom_data->irq = client->irq;
	i2c_set_clientdata(client, pericom_data);

	if (!ic_is_present(pericom_data)) {
		dev_err(&client->dev, "The device is absent\n");
		return -ENXIO;
	}

	pericom_data->sw_gpio = devm_gpiod_get(dev, "swcc", GPIOD_OUT_HIGH);
	if (IS_ERR(pericom_data->sw_gpio)){
		dev_warn(dev, "Failed to get swcc-gpios\n");
	}

	pericom_30216c_set_trysnk_drp_mode(pericom_data);
	pericom_30216c_set_poweractive_mode(pericom_data);

	retval = devm_request_threaded_irq(dev, pericom_data->irq, NULL,
				      pericom_30216c_irq_handler,
				      IRQF_TRIGGER_LOW | IRQF_ONESHOT,
				      DRIVER_NAME, pericom_data);
	if (retval < 0) {
		dev_err(&client->dev, "%s: Failed to create irq thread\n", __func__);
		return retval;
	}

	retval = pericom_30216c_register_typec(dev, pericom_data);
	if (retval){
		dev_err(&client->dev, "%s: Failed to register typec\n", __func__);
		return retval;
	}
		
	dev_info(&client->dev, "%s: probe success\n", __func__);
	return 0;
}

static void pericom_30216c_remove(struct i2c_client *client)
{
	struct pericom_30216c_data *pericom_data = i2c_get_clientdata(client);

	pericom_30216c_set_powersaving_mode(pericom_data);

	if (pericom_data->partner) {
		typec_unregister_partner(pericom_data->partner);
		pericom_data->partner = NULL;
		pericom_data->connected = false;
	}

	if (pericom_data->port) {
		typec_unregister_port(pericom_data->port);
		pericom_data->port = NULL;
	}
	if (pericom_data->role_sw) {
		usb_role_switch_put(pericom_data->role_sw);
		pericom_data->role_sw = NULL;
	}
}

static void pericom_30216c_shutdown(struct i2c_client *client)
{
	struct pericom_30216c_data *pericom_data = i2c_get_clientdata(client);
	pericom_30216c_set_powersaving_mode(pericom_data);
}

static const struct i2c_device_id pericom_30216c_id_table[] = {
	{ DRIVER_NAME, 0 },
	{ },
};
MODULE_DEVICE_TABLE(i2c, pericom_30216c_id_table);

static const struct of_device_id pericom_match_table[] = {
	{ .compatible = "pericom,30216c", },
	{ },
};
MODULE_DEVICE_TABLE(of, pericom_match_table);

static struct i2c_driver pericom_30216c_driver = {
	.driver = {
		.name = DRIVER_NAME,
		.owner = THIS_MODULE,
		.of_match_table = pericom_match_table,
	},
	.probe = pericom_30216c_probe,
	.remove = pericom_30216c_remove,
	.shutdown = pericom_30216c_shutdown,
	.id_table = pericom_30216c_id_table,
};

static int __init pericom_30216c_init(void)
{
	return i2c_add_driver(&pericom_30216c_driver);
}

static void __exit pericom_30216c_exit(void)
{
	i2c_del_driver(&pericom_30216c_driver);
}

module_init(pericom_30216c_init);
module_exit(pericom_30216c_exit);

MODULE_AUTHOR("Pericom, Inc.");
MODULE_DESCRIPTION("Pericom 30216C I2C Driver with Type-C role switch");
MODULE_LICENSE("GPL v2");