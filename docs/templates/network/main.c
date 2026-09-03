/*
 * ============================================================
 *  Quectel M2 (RK3576) TCP 客户端示例
 * ------------------------------------------------------------
 *  功能: 连接 TCP 服务器, 发送消息并打印回显
 *  预期现象: 服务器收到 "{{MESSAGE}}"; 打印服务器响应
 * ============================================================
 *  先在电脑/服务器上起一个 TCP 服务:
 *    Linux:   nc -l 8080
 *    Windows: ncat -l 8080  (或使用其他 TCP 调试工具)
 */

#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define SERVER_IP   "{{SERVER_IP}}"
#define SERVER_PORT {{SERVER_PORT}}
#define MESSAGE     "{{MESSAGE}}"

int main(void)
{
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) { perror("socket"); return 1; }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(SERVER_PORT);
    if (inet_pton(AF_INET, SERVER_IP, &addr.sin_addr) <= 0) {
        fprintf(stderr, "invalid IP: %s\n", SERVER_IP);
        close(sock);
        return 1;
    }

    printf("Connecting %s:%d ...\n", SERVER_IP, SERVER_PORT);
    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect");
        close(sock);
        return 1;
    }
    printf("Connected!\n");

    /* 发送消息 */
    if (send(sock, MESSAGE, strlen(MESSAGE), 0) < 0)
        perror("send");

    /* 等待响应 */
    char buf[1024];
    ssize_t n = recv(sock, buf, sizeof(buf) - 1, 0);
    if (n > 0) {
        buf[n] = '\0';
        printf("Server reply: %s\n", buf);
    } else {
        printf("No reply (server may not echo).\n");
    }

    close(sock);
    printf("Done!\n");
    return 0;
}
