/*
 * ============================================================
 *  Quectel M2 (RK3576) RTC 实时时钟示例
 * ------------------------------------------------------------
 *  功能: 读取/设置 RTC 时间 (PCF8563, /dev/rtc0)
 *  预期现象: 打印当前 RTC 时间; 或系统时间写入 RTC
 * ============================================================
 *  注意: 修改 RTC 时间需要 root 权限
 */

#include <fcntl.h>
#include <linux/rtc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define RTC_DEV "{{RTC_DEV}}"
#define ACTION  {{ACTION_SELECT}}   /* 0=read 1=sync 2=both */

static void print_rtc(int fd, const char *tag)
{
    struct rtc_time tm;
    if (ioctl(fd, RTC_RD_TIME, &tm) < 0) {
        perror("RTC_RD_TIME");
        return;
    }
    printf("%s: %04d-%02d-%02d %02d:%02d:%02d\n", tag,
           tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
           tm.tm_hour, tm.tm_min, tm.tm_sec);
}

int main(void)
{
    int fd = open(RTC_DEV, O_RDWR);
    if (fd < 0) { perror("open " RTC_DEV); return 1; }

    if (ACTION == 0) {
        /* 仅读取 */
        print_rtc(fd, "RTC time");
    } else if (ACTION == 1) {
        /* 系统时间写入 RTC */
        struct rtc_time tm;
        if (ioctl(fd, RTC_RD_TIME, &tm) < 0) { perror("read first"); close(fd); return 1; }
        /* 用系统当前时间覆盖 */
        if (ioctl(fd, RTC_SET_TIME, &tm) < 0) { perror("RTC_SET_TIME"); }
        else printf("RTC updated from system time\n");
        print_rtc(fd, "RTC time now");
    } else {
        /* 读 -> 写 -> 读 */
        print_rtc(fd, "Before");
        struct rtc_time tm;
        if (ioctl(fd, RTC_RD_TIME, &tm) < 0) { perror("read"); close(fd); return 1; }
        /* 加 60 秒演示写入 */
        tm.tm_sec += 60;
        if (tm.tm_sec >= 60) { tm.tm_sec -= 60; tm.tm_min += 1; }
        if (ioctl(fd, RTC_SET_TIME, &tm) < 0) { perror("RTC_SET_TIME"); }
        else printf("+60s written to RTC\n");
        print_rtc(fd, "After");
    }

    close(fd);
    printf("Done!\n");
    return 0;
}
