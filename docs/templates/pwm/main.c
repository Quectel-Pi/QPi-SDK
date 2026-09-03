/*
 * ============================================================
 *  Quectel M2 (RK3576) PWM 输出示例
 * ------------------------------------------------------------
 *  功能: 通过 sysfs 配置 PWM 频率和占空比并输出
 *        可用于 PWM 风扇调速、屏幕背光等场景
 *  预期现象: 外设随占空比变化 (风扇转速 / 亮度变化)
 * ============================================================
 *  注意: 需要设备树已使能对应 PWM 控制器
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define PWM_CHIP     {{PWM_CHIP}}
#define PWM_CHANNEL  {{PWM_CHANNEL}}
#define PERIOD_NS    {{PERIOD_NS}}
#define DUTY_PERCENT {{DUTY_PERCENT}}

static int pwm_write(const char *attr, long value)
{
    char path[160], buf[32];
    FILE *fp;

    snprintf(path, sizeof(path),
             "/sys/class/pwm/pwmchip%d/pwm%d/%s",
             PWM_CHIP, PWM_CHANNEL, attr);
    fp = fopen(path, "w");
    if (!fp) {
        perror(path);
        return -1;
    }
    snprintf(buf, sizeof(buf), "%ld", value);
    fprintf(fp, "%s", buf);
    fclose(fp);
    return 0;
}

int main(void)
{
    long duty_ns = PERIOD_NS * DUTY_PERCENT / 100;

    printf("PWM demo: pwmchip%d channel%d period=%ldns duty=%ld%%\n",
           PWM_CHIP, PWM_CHANNEL, (long)PERIOD_NS, (long)DUTY_PERCENT);

    /* 1. 导出通道 */
    {
        char path[160];
        FILE *fp;
        snprintf(path, sizeof(path), "/sys/class/pwm/pwmchip%d/export", PWM_CHIP);
        fp = fopen(path, "w");
        if (!fp) { perror(path); return 1; }
        fprintf(fp, "%d", PWM_CHANNEL);
        fclose(fp);
        usleep(100 * 1000);
    }

    /* 2. 设置周期与占空比 */
    if (pwm_write("period", PERIOD_NS) != 0) return 1;
    if (pwm_write("duty_cycle", duty_ns) != 0) return 1;

    /* 3. 使能输出 */
    if (pwm_write("enable", 1) != 0) return 1;

    printf("PWM enabled, keeping output for 10s...\n");
    sleep(10);

    /* 4. 关闭并释放 */
    pwm_write("enable", 0);
    {
        char path[160];
        FILE *fp;
        snprintf(path, sizeof(path), "/sys/class/pwm/pwmchip%d/unexport", PWM_CHIP);
        fp = fopen(path, "w");
        if (fp) { fprintf(fp, "%d", PWM_CHANNEL); fclose(fp); }
    }

    printf("Done!\n");
    return 0;
}
