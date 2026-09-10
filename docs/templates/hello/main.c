/*
 * {{APP_NAME}} - Quectel PI H1 (QCS6490) 示例应用
 *
 * 模板占位符由扩展「新建工程」或 SDK `newapp` 替换:
 *   {{APP_NAME}}         应用名 (默认 myapp)
 *   {{MESSAGE}}          启动输出文本
 *   {{LOG_LEVEL}}        日志级别 (choice 选项值)
 *   {{LOG_LEVEL_SELECT}} 日志级别下标 (choice 注入, 0 起)
 */
#include <stdio.h>

#define APP_NAME          "{{APP_NAME}}"
#define LOG_LEVEL_NAME    "{{LOG_LEVEL}}"
#define LOG_LEVEL_ID      {{LOG_LEVEL_SELECT}}

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
    printf("{{MESSAGE}}\n");
    printf("app=%s log_level=%s (id=%d)\n",
           APP_NAME, log_level_str(LOG_LEVEL_ID), LOG_LEVEL_ID);
    return 0;
}
