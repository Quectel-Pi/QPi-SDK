/*
 * ============================================================
 *  Quectel M2 (RK3576) 系统信息监控示例
 * ------------------------------------------------------------
 *  功能: 读取 CPU/温度/内存/负载/磁盘等系统信息
 *  预期现象: 打印 RK3576 系统状态
 * ============================================================
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MONITOR {{MONITOR_SELECT}}   /* 0=once 1=loop */

static void read_file(const char *path, char *out, size_t size)
{
    FILE *fp = fopen(path, "r");
    if (!fp) { snprintf(out, size, "(不可读)"); return; }
    if (!fgets(out, size, fp)) snprintf(out, size, "(空)");
    fclose(fp);
    /* 去掉换行 */
    size_t n = strlen(out);
    while (n && (out[n-1] == '\n' || out[n-1] == '\r')) out[--n] = '\0';
}

static void print_sysinfo(void)
{
    char buf[256];

    printf("======== M2 System Info ========\n");

    /* CPU */
    read_file("/proc/device-tree/model", buf, sizeof(buf));
    printf("Model   : %s\n", buf);
    read_file("/proc/cpuinfo", buf, sizeof(buf));
    char *hw = strstr(buf, "Hardware");
    if (hw) { char *e = strchr(hw, '\n'); if (e) *e = '\0'; printf("%s\n", hw); }
    read_file("/proc/device-tree/compatible", buf, sizeof(buf));
    printf("SoC     : %s\n", buf);

    /* 温度 (thermal zone 0) */
    read_file("/sys/class/thermal/thermal_zone0/temp", buf, sizeof(buf));
    printf("Temp    : %.1f °C\n", atoi(buf) / 1000.0);

    /* 内存 */
    read_file("/proc/meminfo", buf, sizeof(buf));
    long mem_total = 0, mem_free = 0;
    sscanf(buf, "MemTotal: %ld kB", &mem_total);
    FILE *fp = fopen("/proc/meminfo", "r");
    if (fp) {
        char line[128];
        while (fgets(line, sizeof(line), fp)) {
            if (sscanf(line, "MemFree: %ld kB", &mem_free) == 1) break;
        }
        fclose(fp);
    }
    printf("Memory  : %ld MB total, %ld MB free (%.0f%% used)\n",
           mem_total / 1024, mem_free / 1024,
           mem_total ? 100.0 * (mem_total - mem_free) / mem_total : 0);

    /* 负载 */
    read_file("/proc/loadavg", buf, sizeof(buf));
    printf("Load    : %s\n", buf);

    /* 磁盘 */
    FILE *df = popen("df -h / | tail -1", "r");
    if (df) {
        if (fgets(buf, sizeof(buf), df)) printf("Disk    : %s", buf);
        pclose(df);
    }

    /* 内核版本 */
    read_file("/proc/version", buf, sizeof(buf));
    printf("Kernel  : %s\n", buf);
    printf("================================\n");
}

int main(void)
{
    do {
        print_sysinfo();
        if (MONITOR == 1) {
            printf("(refreshing in 2s, Ctrl+C to exit)\n");
            sleep(2);
        }
    } while (MONITOR == 1);
    printf("Done!\n");
    return 0;
}
