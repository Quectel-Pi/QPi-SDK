/*
 * ============================================================
 *  Quectel M2 (RK3576) 串口通信示例
 * ------------------------------------------------------------
 *  功能: 打开串口设备, 配置波特率, 回显收到的数据
 *  预期现象: 串口接入后, 发送字符会在板子终端中回显
 * ============================================================
 *  注意: 需要板子设备树已使能对应 UART 且未被系统占用
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#define SERIAL_DEV "{{SERIAL_DEV}}"
#define BAUD_RATE  {{BAUD}}

static int set_baud(struct termios *tio, int baud)
{
    speed_t speed;
    switch (baud) {
        case 9600:   speed = B9600;   break;
        case 115200: speed = B115200; break;
        case 460800: speed = B460800; break;
        case 921600: speed = B921600; break;
        default:     speed = B115200; break;
    }
    cfsetispeed(tio, speed);
    cfsetospeed(tio, speed);
    return 0;
}

int main(void)
{
    int fd;
    struct termios tio;

    fd = open(SERIAL_DEV, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) {
        perror("open " SERIAL_DEV);
        return 1;
    }

    memset(&tio, 0, sizeof(tio));
    set_baud(&tio, BAUD_RATE);
    tio.c_cflag |= (CLOCAL | CREAD);
    tio.c_cflag &= ~CSIZE;
    tio.c_cflag |= CS8;          /* 8 数据位 */
    tio.c_cflag &= ~PARENB;      /* 无校验 */
    tio.c_cflag &= ~CSTOPB;      /* 1 停止位 */
    tio.c_iflag = IGNPAR;
    tio.c_oflag = 0;
    tio.c_lflag = 0;
    tcflush(fd, TCIFLUSH);
    tcsetattr(fd, TCSANOW, &tio);

    printf("Serial demo on %s @ %d baud\n", SERIAL_DEV, BAUD_RATE);
    printf("Echoing received data, Ctrl+C to exit...\n");

    for (;;) {
        char buf[256];
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n > 0) {
            buf[n] = '\0';
            printf("[RX] %s\n", buf);
            /* 原样回显给发送方 */
            write(fd, buf, n);
        } else if (n < 0 && errno != EAGAIN) {
            perror("read");
            break;
        }
        usleep(20 * 1000);
    }

    close(fd);
    return 0;
}
