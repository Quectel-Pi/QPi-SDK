/*
 * ============================================================
 *  Quectel M2 (RK3576) 摄像头抓帧示例 (V4L2)
 * ------------------------------------------------------------
 *  功能: 打开摄像头设备, 请求格式, 抓取一帧并保存为 PPM 文件
 *  预期现象: 生成 frame0.ppm, adb pull 后可查看
 * ============================================================
 *  注意:
 *  - M2 摄像头链路: sensor → rkcif → rkisp → /dev/video*
 *  - IMX477 当前模式 1920x1080, 输出 RAW10 (SRGGB10)
 *  - 需 root 权限访问 /dev/video0
 *  - 抓帧输出为 RAW Bayer, PPM 打开是黑白网格属正常
 */

#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define VIDEO_DEV "{{VIDEO_DEV}}"
#define WIDTH     {{WIDTH}}
#define HEIGHT    {{HEIGHT}}
#define FRAMES    {{FRAMES}}

struct buffer {
    void *start;
    size_t length;
};

static int xioctl(int fd, unsigned long req, void *arg)
{
    int r;
    do { r = ioctl(fd, req, arg); } while (r == -1 && errno == EINTR);
    return r;
}

static void save_ppm(const char *name, void *data, size_t len)
{
    FILE *fp = fopen(name, "wb");
    if (!fp) { perror(name); return; }
    /* 头部: P5 灰度 + 宽度 高度 + 255 */
    fprintf(fp, "P5\n%d %d\n255\n", WIDTH, HEIGHT);
    /* 数据若大于图像尺寸则截断 (RAW10 打包 8bit 时可能多字节) */
    fwrite(data, 1, len < (size_t)(WIDTH * HEIGHT) ? len : (size_t)(WIDTH * HEIGHT), fp);
    fclose(fp);
    printf("saved: %s\n", name);
}

int main(void)
{
    int fd = open(VIDEO_DEV, O_RDWR);
    if (fd < 0) { perror("open " VIDEO_DEV); return 1; }

    /* 1. 查询能力 */
    struct v4l2_capability cap;
    if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
        perror("VIDIOC_QUERYCAP"); close(fd); return 1;
    }
    printf("driver: %s card: %s\n", cap.driver, cap.card);

    /* 2. 设置格式 */
    struct v4l2_format fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = WIDTH;
    fmt.fmt.pix.height = HEIGHT;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_SRGGB10;  /* IMX477 RAW10 */
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        perror("VIDIOC_S_FMT"); close(fd); return 1;
    }
    printf("format: %ux%u fourcc=%c%c%c%c\n",
           fmt.fmt.pix.width, fmt.fmt.pix.height,
           (fmt.fmt.pix.pixelformat >> 0) & 0xff,
           (fmt.fmt.pix.pixelformat >> 8) & 0xff,
           (fmt.fmt.pix.pixelformat >> 16) & 0xff,
           (fmt.fmt.pix.pixelformat >> 24) & 0xff);

    /* 3. 请求缓冲区 */
    struct v4l2_requestbuffers req;
    memset(&req, 0, sizeof(req));
    req.count = 4;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0) {
        perror("VIDIOC_REQBUFS"); close(fd); return 1;
    }

    struct buffer bufs[4];
    memset(bufs, 0, sizeof(bufs));
    for (unsigned i = 0; i < req.count; i++) {
        struct v4l2_buffer buf;
        memset(&buf, 0, sizeof(buf));
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        if (xioctl(fd, VIDIOC_QUERYBUF, &buf) < 0) {
            perror("VIDIOC_QUERYBUF"); close(fd); return 1;
        }
        bufs[i].length = buf.length;
        bufs[i].start = mmap(NULL, buf.length, PROT_READ | PROT_WRITE,
                             MAP_SHARED, fd, buf.m.offset);
        if (bufs[i].start == MAP_FAILED) {
            perror("mmap"); close(fd); return 1;
        }
        if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
            perror("VIDIOC_QBUF"); close(fd); return 1;
        }
    }

    /* 4. 开始采集 */
    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
        perror("VIDIOC_STREAMON"); close(fd); return 1;
    }

    /* 5. 抓帧 */
    for (int f = 0; f < FRAMES; f++) {
        struct v4l2_buffer buf;
        memset(&buf, 0, sizeof(buf));
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        if (xioctl(fd, VIDIOC_DQBUF, &buf) < 0) {
            perror("VIDIOC_DQBUF"); break;
        }
        char name[64];
        snprintf(name, sizeof(name), "frame%d.ppm", f);
        save_ppm(name, bufs[buf.index].start, buf.bytesused);
        if (xioctl(fd, VIDIOC_QBUF, &buf) < 0)
            perror("VIDIOC_QBUF");
    }

    /* 6. 停止并清理 */
    xioctl(fd, VIDIOC_STREAMOFF, &type);
    for (unsigned i = 0; i < req.count; i++)
        if (bufs[i].start)
            munmap(bufs[i].start, bufs[i].length);
    close(fd);
    printf("Done!\n");
    return 0;
}
