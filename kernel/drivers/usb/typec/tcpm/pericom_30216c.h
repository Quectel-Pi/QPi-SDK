#ifndef _PERICOM_30216C_H_
#define _PERICOM_30216C_H_

#include <linux/bits.h>

#define PERICOM_I2C_RETRY_TIMES         3

/* Enums for driver usage */
enum pericom_role_mode {
	DEVICE_MODE = 0,
	HOST_MODE,
	DRP_MODE,          /* Standard DRP (No preference) */
	TRYSNK_DRP_MODE,   /* DRP with Try.SNK */
};

enum pericom_power_mode {
	ACTIVE_MODE = 0,
	POWERSAVING_MODE
};

/* ==========================================================================
 * Register 0x01: Device ID
 * ========================================================================== */
#define PERICOM_DEVICE_ID_REG           0x01


/* ==========================================================================
 * Register 0x02: Control Register
 * Datasheet Page 13
 * ========================================================================== */
#define PERICOM_CONTROL_REG             0x02

/* Bit 7: Power Saving Mode */
#define PERICOM_POWER_SAVING_MASK       BIT(7)
#define PERICOM_POWER_SAVING_OFFSET     7

/* Bit 6: Dual Role 2 Try.SRC or Try.SNK setting */
#define PERICOM_DRP2_TRY_SNK            BIT(6)

/* Bit 5: Accessory Detection in Device Mode */
#define PERICOM_ACC_DET_EN              BIT(5)

/* Bits 4:3: Charging Current Mode (Host / DRP Host) */
#define PERICOM_CHG_CURRENT_MASK        GENMASK(4, 3)
#define PERICOM_CHG_CURRENT_SHIFT       3
#define PERICOM_CHG_CURR_DEFAULT        (0u << PERICOM_CHG_CURRENT_SHIFT)
#define PERICOM_CHG_CURR_1P5A           (1u << PERICOM_CHG_CURRENT_SHIFT)
#define PERICOM_CHG_CURR_3A             (2u << PERICOM_CHG_CURRENT_SHIFT)

/* Bits 2:1: Port Role Setting */
#define PERICOM_ROLE_MODE_MASK          GENMASK(2, 1)
#define PERICOM_ROLE_OFFSET             1
#define PERICOM_ROLE_DEVICE             (0u << PERICOM_ROLE_OFFSET) /* 00b */
#define PERICOM_ROLE_HOST               (1u << PERICOM_ROLE_OFFSET) /* 01b */
#define PERICOM_ROLE_DRP                (2u << PERICOM_ROLE_OFFSET) /* 10b */
#define PERICOM_ROLE_DRP_TRY            (3u << PERICOM_ROLE_OFFSET) /* 11b */

/* Bit 0: Interrupt Mask */
#define PERICOM_INTERRUPT_MASK          BIT(0)


/* ==========================================================================
 * Register 0x03: Interrupt Register
 * Datasheet Page 13
 * ========================================================================== */
#define PERICOM_INTERRUPT_REG           0x03
#define PERICOM_INT_DETACH              BIT(1)
#define PERICOM_INT_ATTACH              BIT(0)


/* ==========================================================================
 * Register 0x04: CC Status Register
 * Datasheet Page 14
 * ========================================================================== */
#define PERICOM_CC_STATUS_REG           0x04

/* Bit 7: VBUS Detection Status */
#define PERICOM_VBUS_DET                BIT(7)

/* Bits 6:5: Charging Current Detection (Device Mode) */
#define PERICOM_CC_CHG_MASK             GENMASK(6, 5)
#define PERICOM_CC_CHG_SHIFT            5

/* Bits 4:2: Attached Port Status */
#define PERICOM_ATTACH_STATUS_MASK      GENMASK(4, 2)
#define PERICOM_ATTACH_STATUS_SHIFT     2
#define PERICOM_ATTACH_STANDBY          (0u << PERICOM_ATTACH_STATUS_SHIFT)
#define PERICOM_ATTACH_DEVICE           (1u << PERICOM_ATTACH_STATUS_SHIFT) /* 0x04 */
#define PERICOM_ATTACH_HOST             (2u << PERICOM_ATTACH_STATUS_SHIFT) /* 0x08 */
#define PERICOM_ATTACH_AUDIO_ACC        (3u << PERICOM_ATTACH_STATUS_SHIFT) /* 0x0C */
#define PERICOM_ATTACH_DEBUG_ACC        (4u << PERICOM_ATTACH_STATUS_SHIFT) /* 0x10 */
#define PERICOM_ATTACH_DEVICE_ACTIVE    (5u << PERICOM_ATTACH_STATUS_SHIFT) /* 0x14 */

/* Bits 1:0: Plug Polarity (CC Orientation) */
#define CC_MASK                         GENMASK(1, 0)
#define CC1_STATUS                      0x1
#define CC2_STATUS                      0x2
#define CC_CONNECT                      0x3

enum pericom_target_role {
    PERICOM_SWITCH_TO_DEVICE = 0,
    PERICOM_SWITCH_TO_HOST,
};

#endif /* _PERICOM_30216C_H_ */