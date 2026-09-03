/*
 * ============================================================
 *  Quectel M2 (RK3576) NVMe SSD 检测示例
 * ------------------------------------------------------------
 *  功能: 检测 NVMe SSD 枚举与容量, 可选挂载到 /mnt
 *  预期现象: 打印 NVMe 型号/容量; 挂载后读写测试文件
 * ============================================================
 *  注意:
 *  - M2 的 PCIe 同一时刻只能插一个设备 (5G 模组 或 NVMe 二选一)
 *  - 需要 root 权限执行挂载
 *  - 首次使用需先分区+格式化: fdisk /dev/nvme0n1 && mkfs.ext4 /dev/nvme0n1p1
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define ACTION {{ACTION_SELECT}}   /* 0=info 1=mount */

static void read_file(const char *path, char *out, size_t size)
{
    FILE *fp = fopen(path, "r");
    if (!fp) { snprintf(out, size, "(不可读)"); return; }
    if (!fgets(out, size, fp)) snprintf(out, size, "(空)");
    fclose(fp);
    size_t n = strlen(out);
    while (n && (out[n-1] == '\n' || out[n-1] == '\r')) out[--n] = '\0';
}

int main(void)
{
    char buf[256];

    /* 1. 检查 PCIe 是否枚举 NVMe */
    FILE *lspci = popen("ls /sys/bus/pci/devices/ 2>/dev/null", "r");
    if (!lspci) { perror("popen"); return 1; }
    printf("PCIe devices:\n");
    while (fgets(buf, sizeof(buf), lspci)) {
        if (buf[0] != '\n') printf("  %s", buf);
    }
    pclose(lspci);

    /* 2. 读取 NVMe 信息 */
    read_file("/sys/class/block/nvme0n1/device/model", buf, sizeof(buf));
    printf("NVMe model : %s\n", buf);
    read_file("/sys/class/block/nvme0n1/size", buf, sizeof(buf));
    long long sectors = atoll(buf);
    printf("Capacity   : %.1f GB (%lld sectors)\n",
           sectors * 512.0 / 1e9, sectors);

    /* 3. 可选挂载 */
    if (ACTION == 1) {
        printf("Mounting /dev/nvme0n1p1 -> /mnt ...\n");
        if (system("mkdir -p /mnt && mount /dev/nvme0n1p1 /mnt 2>/dev/null") != 0) {
            printf("挂载失败: 请确认已分区并格式化 (fdisk && mkfs.ext4)\n");
            return 1;
        }
        FILE *tf = fopen("/mnt/m2_test.txt", "w");
        if (tf) {
            fprintf(tf, "NVMe write test OK!\n");
            fclose(tf);
            printf("Wrote /mnt/m2_test.txt OK\n");
        }
        system("umount /mnt");
        printf("Unmounted.\n");
    }

    printf("Done!\n");
    return 0;
}
