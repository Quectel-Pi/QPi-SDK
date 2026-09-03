/*
 * ============================================================
 *  Quectel M2 (RK3576) Hello World 示例
 * ------------------------------------------------------------
 *  功能: 打印一条消息 + 系统信息, 验证交叉编译/部署/运行全流程
 *  预期现象: 板子上运行后终端输出你的消息和系统版本号
 * ============================================================
 */

#include <stdio.h>
#include <sys/utsname.h>

int main(void)
{
    struct utsname info;

    /* 打印在向导中填写的消息 */
    printf("{{MESSAGE}}\n");

    /* 读取并打印系统信息 */
    if (uname(&info) == 0) {
        printf("System  : %s %s\n", info.sysname, info.release);
        printf("Machine : %s\n", info.machine);
    }

    printf("Project : {{PROJECT_NAME}}\n");
    printf("Done!\n");
    return 0;
}
