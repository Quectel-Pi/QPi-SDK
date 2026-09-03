/*
 * ============================================================
 *  Quectel M2 (RK3576) GPIO 控制示例
 * ------------------------------------------------------------
 *  功能: 通过 sysfs 接口控制 GPIO
 *        输出模式: LED 常亮 / 闪烁
 *        输入模式: 读取按键电平
 *  预期现象: 见 template.json 中的 expected 描述
 * ============================================================
 *  GPIO 编号计算:  bank * 32 + 组(A=0 B=1 C=2 D=3) * 8 + 引脚
 *  例: GPIO3_D5 -> 3*32 + 3*8 + 5 = 125
 *      具体编号请查阅 M2 硬件原理图 / 40Pin 定义
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define GPIO_NUM   {{GPIO_NUM}}
#define GPIO_SYSFS "/sys/class/gpio"

static int gpio_export(int num)
{
    FILE *fp = fopen(GPIO_SYSFS "/export", "w");
    if (!fp) { perror("open export"); return -1; }
    fprintf(fp, "%d", num);
    fclose(fp);
    usleep(100 * 1000); /* 等待设备节点生成 */
    return 0;
}

static int gpio_direction(int num, const char *dir)
{
    char path[128];
    FILE *fp;
    snprintf(path, sizeof(path), GPIO_SYSFS "/gpio%d/direction", num);
    fp = fopen(path, "w");
    if (!fp) { perror("open direction"); return -1; }
    fprintf(fp, "%s", dir);
    fclose(fp);
    return 0;
}

static int gpio_write(int num, int value)
{
    char path[128];
    FILE *fp;
    snprintf(path, sizeof(path), GPIO_SYSFS "/gpio%d/value", num);
    fp = fopen(path, "w");
    if (!fp) { perror("open value"); return -1; }
    fprintf(fp, "%d", value);
    fclose(fp);
    return 0;
}

static int gpio_read(int num)
{
    char path[128], buf[8];
    FILE *fp;
    snprintf(path, sizeof(path), GPIO_SYSFS "/gpio%d/value", num);
    fp = fopen(path, "r");
    if (!fp) { perror("open value"); return -1; }
    if (fgets(buf, sizeof(buf), fp))
        return atoi(buf);
    return -1;
}

int main(void)
{
    int mode = {{MODE_SELECT}}; /* 由向导生成: 0=blink 1=steady 2=input */

    printf("GPIO demo: gpio%d mode=%d\n", GPIO_NUM, mode);

    if (gpio_export(GPIO_NUM) != 0)
        return 1;

    if (mode == 2) {
        /* ---------- 输入模式: 读取按键电平 ---------- */
        int last = -1;
        gpio_direction(GPIO_NUM, "in");
        printf("Input mode, press Ctrl+C to exit...\n");
        for (;;) {
            int v = gpio_read(GPIO_NUM);
            if (v != last) {
                printf("GPIO%d = %d\n", GPIO_NUM, v);
                last = v;
            }
            usleep(50 * 1000);
        }
    } else {
        /* ---------- 输出模式: 常亮 / 闪烁 ---------- */
        gpio_direction(GPIO_NUM, "out");
        if (mode == 1) {
            gpio_write(GPIO_NUM, 1);
            printf("GPIO%d set HIGH (steady on)\n", GPIO_NUM);
        } else {
            for (;;) {
                gpio_write(GPIO_NUM, 1);
                usleep(500 * 1000);
                gpio_write(GPIO_NUM, 0);
                usleep(500 * 1000);
            }
        }
    }
    return 0;
}
