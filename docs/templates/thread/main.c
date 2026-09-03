/*
 * ============================================================
 *  Quectel M2 (RK3576) 多线程示例 (pthread)
 * ------------------------------------------------------------
 *  功能: 创建多个工作线程并发运行, 主线程等待回收
 *  预期现象: 各线程交替打印, 最后主线程输出回收结果
 * ============================================================
 *  编译链接: pthread 库 (Makefile 已加 -lpthread)
 */

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define THREADS {{THREADS}}
#define LOOPS   {{LOOPS}}

struct arg_t {
    int id;
};

static void *worker(void *p)
{
    struct arg_t *a = (struct arg_t *)p;
    for (int i = 0; i < LOOPS; i++) {
        printf("[thread %d] loop %d (tid=%lu)\n", a->id, i,
               (unsigned long)pthread_self());
        usleep((a->id + 1) * 100 * 1000);  /* 交错打印 */
    }
    printf("[thread %d] finished\n", a->id);
    return NULL;
}

int main(void)
{
    pthread_t tids[THREADS];
    struct arg_t args[THREADS];

    printf("Creating %d threads, each loops %d times...\n", THREADS, LOOPS);

    for (int i = 0; i < THREADS; i++) {
        args[i].id = i;
        if (pthread_create(&tids[i], NULL, worker, &args[i]) != 0) {
            perror("pthread_create");
            return 1;
        }
    }

    for (int i = 0; i < THREADS; i++)
        pthread_join(tids[i], NULL);

    printf("All threads joined. Done!\n");
    return 0;
}
