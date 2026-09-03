/*
 * ============================================================
 *  Quectel M2 (RK3576) PCIe 设备枚举示例
 * ------------------------------------------------------------
 *  功能: 枚举 PCIe 总线设备, 显示 VID/PID 与链路信息
 *  预期现象: 列出 PCIe 设备; 5G 模组(RM520N)或 NVMe 被识别
 * ============================================================
 *  注意: M2 的 PCIe 同一时刻只能插一个设备 (5G 模组 或 NVMe)
 *  常见设备 ID:
 *    Qualcomm/RM520N: 2c7c:0800 (VID:PID)
 *    NVMe SSD:        144d (Samsung) / 15b7 (WD) 等
 */

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DETAIL {{DETAIL_SELECT}}   /* 0=detail 1=brief */

static void read_file(const char *path, char *out, size_t size)
{
    FILE *fp = fopen(path, "r");
    if (!fp) { snprintf(out, size, "?"); return; }
    if (!fgets(out, size, fp)) snprintf(out, size, "?");
    fclose(fp);
    size_t n = strlen(out);
    while (n && (out[n-1] == '\n' || out[n-1] == '\r')) out[--n] = '\0';
}

int main(void)
{
    const char *dev_dir = "/sys/bus/pci/devices";
    struct dirent **list;
    int n = scandir(dev_dir, &list, NULL, alphasort);
    if (n < 0) { perror("scandir"); return 1; }

    printf("PCIe devices under %s:\n", dev_dir);
    int found = 0;
    for (int i = 0; i < n; i++) {
        if (list[i]->d_name[0] == '.') { free(list[i]); continue; }
        found = 1;
        printf("\n[%s]\n", list[i]->d_name);
        if (DETAIL == 0) {
            char buf[256], path[512];
            snprintf(path, sizeof(path), "%s/%s/vendor", dev_dir, list[i]->d_name);
            read_file(path, buf, sizeof(buf));
            printf("  vendor : %s\n", buf);
            snprintf(path, sizeof(path), "%s/%s/device", dev_dir, list[i]->d_name);
            read_file(path, buf, sizeof(buf));
            printf("  device : %s\n", buf);
            snprintf(path, sizeof(path), "%s/%s/class", dev_dir, list[i]->d_name);
            read_file(path, buf, sizeof(buf));
            printf("  class  : %s\n", buf);
            /* 链路速率 (PCIe 3.0 x1 -> 8GT/s) */
            snprintf(path, sizeof(path), "%s/%s/current_link_speed", dev_dir, list[i]->d_name);
            read_file(path, buf, sizeof(buf));
            printf("  link   : %s\n", buf);
        }
        free(list[i]);
    }
    free(list);
    if (!found) printf("  (无 PCIe 设备, 请检查是否插入 5G 模组或 NVMe SSD)\n");

    printf("\nDone!\n");
    return 0;
}
