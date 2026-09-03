/*
 * ============================================================
 *  Quectel M2 (RK3576) I2C 传感器读写示例
 * ------------------------------------------------------------
 *  功能: 扫描 I2C 总线设备, 并对指定设备读取寄存器
 *  预期现象: 打印总线上的设备地址; 读取寄存器值
 * ============================================================
 *  常见设备:
 *    GT911 触摸   -> i2c0 0x14
 *    背光控制器   -> i2c0 0x45
 *  (具体地址以原理图/数据手册为准)
 */

#include <errno.h>
#include <fcntl.h>
#include <linux/i2c-dev.h>
#include <linux/i2c.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define I2C_BUS   {{I2C_BUS}}
#define DEV_ADDR  {{DEV_ADDR}}
#define REG_ADDR  {{REG_ADDR}}

int main(void)
{
    char path[64];
    snprintf(path, sizeof(path), "/dev/i2c-%d", I2C_BUS);

    int fd = open(path, O_RDWR);
    if (fd < 0) { perror(path); return 1; }

    /* ---------- 1. 扫描总线 ---------- */
    printf("Scanning %s...\n", path);
    for (int addr = 0x03; addr <= 0x77; addr++) {
        if (ioctl(fd, I2C_SLAVE_FORCE, addr) == 0) {
            unsigned char buf = 0;
            struct i2c_msg msg = { .addr = addr, .flags = 0,
                                   .len = 0, .buf = &buf };
            struct i2c_rdwr_ioctl_data data = { .msgs = &msg, .nmsgs = 1 };
            if (ioctl(fd, I2C_RDWR, &data) >= 0 || errno != EBUSY)
                printf("  found device at 0x%02x\n", addr);
        }
    }

    /* ---------- 2. 读取指定寄存器 ---------- */
    if (DEV_ADDR > 0) {
        struct i2c_rdwr_ioctl_data data;
        struct i2c_msg msgs[2];
        unsigned char reg = REG_ADDR;
        unsigned char val = 0;

        if (ioctl(fd, I2C_SLAVE, DEV_ADDR) < 0) {
            perror("I2C_SLAVE"); close(fd); return 1;
        }

        /* 写寄存器地址 -> 读 1 字节 */
        msgs[0].addr = DEV_ADDR; msgs[0].flags = 0; msgs[0].len = 1; msgs[0].buf = &reg;
        msgs[1].addr = DEV_ADDR; msgs[1].flags = I2C_M_RD; msgs[1].len = 1; msgs[1].buf = &val;
        data.msgs = msgs; data.nmsgs = 2;

        if (ioctl(fd, I2C_RDWR, &data) < 0) {
            perror("I2C_RDWR (read register)");
        } else {
            printf("read: dev=0x%02x reg=0x%02x -> 0x%02x (%d)\n",
                   DEV_ADDR, REG_ADDR, val, val);
        }
    }

    close(fd);
    printf("Done!\n");
    return 0;
}
