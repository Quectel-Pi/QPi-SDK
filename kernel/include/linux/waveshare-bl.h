/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef _LINUX_WAVESHARE_BL_H
#define _LINUX_WAVESHARE_BL_H

#include <linux/errno.h>
#include <linux/kconfig.h>
#include <linux/types.h>

#define WS_TOUCH_8INCH 0x14
#define WS_TOUCH_4_3INCH 0x5d

#if IS_REACHABLE(CONFIG_BACKLIGHT_WAVESHARE)
int ws_panel_i2c_read(u8 reg);
int ws_panel_i2c_write(u8 reg, u8 val);
int ws_panel_get_touch_address(void);
bool ws_panel_has_handoff(void);
int ws_panel_prepare_4_3(void);
int ws_panel_unprepare_4_3(void);
int ws_panel_detect_presence(void);
bool ws_panel_is_present(void);
int ws_panel_set_backlight(unsigned int value);
void ws_panel_switch_mipi(bool switch_ws);
void ws_panel_poweron_mipi(void);
#else
static inline bool ws_panel_has_handoff(void)
{
	return false;
}

static inline int ws_panel_get_touch_address(void)
{
	return -ENODEV;
}

static inline int ws_panel_prepare_4_3(void)
{
	return -ENODEV;
}

static inline int ws_panel_unprepare_4_3(void)
{
	return -ENODEV;
}

static inline int ws_panel_i2c_read(u8 reg)
{
	return -ENODEV;
}

static inline int ws_panel_i2c_write(u8 reg, u8 val)
{
	return -ENODEV;
}

static inline int ws_panel_detect_presence(void)
{
	return -ENODEV;
}

static inline bool ws_panel_is_present(void)
{
	return false;
}

static inline int ws_panel_set_backlight(unsigned int value)
{
	return -ENODEV;
}

static inline void ws_panel_switch_mipi(bool switch_ws)
{
}

static inline void ws_panel_poweron_mipi(void)
{
}
#endif

#endif
