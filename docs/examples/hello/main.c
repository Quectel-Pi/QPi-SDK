/*
 * hello - Quectel PI H1 (QCS6490) 示例应用
 *
 * 模板占位符由扩展「新建工程」或 SDK `newapp` 替换:
 *   hello         应用名 (默认 myapp)
 *   Hello from QPi H1 (example)          启动输出文本
 *   info        日志级别 (choice 选项值)
 *   1 日志级别下标 (choice 注入, 0 起)
 */
#include <stdio.h>

#define APP_NAME          "hello"
#define LOG_LEVEL_NAME    "info"
#define LOG_LEVEL_ID      1

static const char *log_level_str(int id)
{
    switch (id) {
    case 0:  return "debug";
    case 1:  return "info";
    case 2:  return "warn";
    default: return "unknown";
    }
}

int main(void)
{
    printf("Hello from QPi H1 (example)\n");
    printf("app=%s log_level=%s (id=%d)\n",
           APP_NAME, log_level_str(LOG_LEVEL_ID), LOG_LEVEL_ID);
    return 0;
}
