#!/usr/bin/env python
# SPDX-License-Identifier: (GPL-2.0+ OR MIT)
# Copyright (c) 2018 Fuzhou Rockchip Electronics Co., Ltd
#


"""
Multiple dtb package tool

Usage: scripts/mkmultidtb.py board
The board is what you defined in DTBS dictionary like DTBS['board'],
Such as: PX30-EVB, RK3308-EVB

"""
import os
import sys
import shutil
from collections import OrderedDict

DTBS = {}

DTBS['PX30-EVB'] = OrderedDict([('px30-evb-ddr3-v10', '#_saradc_ch0=1024'),
				('px30-evb-ddr3-lvds-v10', '#_saradc_ch0=512')])

DTBS['RK3308-EVB'] = OrderedDict([('rk3308-evb-dmic-i2s-v10', '#_saradc_ch3=288'),
				  ('rk3308-evb-dmic-pdm-v10', '#_saradc_ch3=1024'),
				  ('rk3308-evb-amic-v10', '#_saradc_ch3=407')])

DTBS['RK3576-EVB'] = [('rk3576-evb1-v10-linux', '#_saradc_ch2=2054'),
                  ('rk3576s-evb1-v10-linux', '#_saradc_ch2=410'),
                  ('rk3576-evb1-v12-v31', '#_saradc_ch2=3721'),
                  ('rk3576s-evb1-v12-v31', '#_saradc_ch2=3412'),
                  ('rk3576-qtl-socketevb', '#_saradc_ch5=0#_saradc_ch2=3721'),
                  ('rk3576-qtl-socketevb', '#_saradc_ch5=0#_saradc_ch2=2054')]

def main():
    if (len(sys.argv) < 2) or (sys.argv[1] == '-h'):
        print(__doc__)
        sys.exit(2)

    BOARD = sys.argv[1]

    # Use RK_KERNEL_DTS_NAME from environment if set (single custom DTS)
    kernel_dts_name = os.environ.get('RK_KERNEL_DTS_NAME', '')
    if kernel_dts_name:
        TARGET_DTBS = OrderedDict([(kernel_dts_name, '')])
    else:
        TARGET_DTBS = DTBS[BOARD]

    target_dtb_list = ''
    default_dtb = True

    if hasattr(TARGET_DTBS, 'items'):
        dtb_iter = TARGET_DTBS.items()
    else:
        dtb_iter = TARGET_DTBS

    for dtb, value in dtb_iter:
        ori_file = 'arch/arm64/boot/dts/rockchip/' + dtb + '.dtb'
        if not os.path.exists(ori_file):
            print("Warning: %s not found, skipping" % ori_file)
            continue
        if default_dtb:
            shutil.copyfile(ori_file, "rk-kernel.dtb")
            target_dtb_list += 'rk-kernel.dtb '
            default_dtb = False
            continue
        new_file = dtb + value + '.dtb'
        shutil.copyfile(ori_file, new_file)
        target_dtb_list += ' ' + new_file

    print(target_dtb_list)
    os.system('scripts/resource_tool quectel_720p.bmp quectel_720p_kernel.bmp ' + target_dtb_list)
    os.system('rm ' + target_dtb_list)
    print "Image:  resource.img (with "+"quectel_720p_fastboot.bmp "+"quectel_720p.bmp "+target_dtb_list+") is ready"

if __name__ == '__main__':
    main()
