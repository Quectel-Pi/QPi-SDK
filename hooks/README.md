# simple-h1 pre-pack hooks (打包前钩子)

在 system.img 打包流程的最后阶段, 对镜像内文件做自定义调整。
支持 chmod / cp / ln / rm 等任意操作。

## 运行时机

pack-system.sh 流程:

  1. cp 原始镜像 -> build/output/system.img
  2. mount -o loop,rw 挂载到 build/system-mnt/
  3. rsync 应用 overlay/ 增量
  4. rsync 合并新编译内核模块
  5. 执行 overlay-remove.list 删除清单
  6. ★ 执行 hooks/*.sh  (本机制, root 身份, 按文件名排序)
  7. sync + umount -> 最终 system.img

即: hooks 在 overlay 合并、删除清单之后, 卸载打包之前执行,
拥有对镜像最终内容的最后修改权。

## 用法

```bash
# 1. 复制示例模板
cp hooks/00-example.sh hooks/10-mycustom.sh

# 2. 编辑, 例如:
#    chmod 755 "${IMG_MNT}/usr/local/bin/hello-h1"
#    ln -sf /usr/local/bin/hello-h1 "${IMG_MNT}/usr/bin/hello"

# 3. 重新打包 (hooks 自动执行)
SKIP_KERNEL=1 ./scripts/build-all.sh
# 或单独: ./scripts/pack-system.sh
```

## 约定

- 目录: `hooks/` (项目根, 不会被打包进镜像)
- 文件: 任意 `*.sh`, 按文件名 lexicographic 顺序执行 (00- 最先, 99- 最后)
- 身份: root (pack-system.sh 内部用 sudo 执行)
- 失败即中止: 脚本非零退出码会中断打包 (set -e), 避免产出坏镜像
- 目录可换: `HOOKS_DIR=/path ./scripts/pack-system.sh`

## 环境变量

| 变量 | 含义 |
|------|------|
| IMG_MNT | system.img 挂载点, 操作镜像内文件必须以它为前缀 |
| OUT_IMG | 最终输出镜像路径 |
| SRC_IMG | 原始镜像路径 |
| OVERLAY_DIR | overlay 增量目录 |
| BUILD_DIR | build 目录 |
| SDK_ROOT | 项目根目录 |
| KERNEL_RELEASE | 内核版本字符串 |

## 示例: 常见操作

```bash
# 权限
chmod 755 "${IMG_MNT}/usr/local/bin/hello-h1"

# 拷贝宿主机文件进镜像
cp /path/to/file "${IMG_MNT}/etc/file"

# 软链接: 链接在镜像内, 目标写设备运行时路径 (不带 IMG_MNT!)
ln -sf /usr/local/bin/hello-h1 "${IMG_MNT}/usr/bin/hello-h1"

# 删除
rm -f "${IMG_MNT}/etc/foo"
```

## 与 overlay-remove.list 的区别

- overlay-remove.list: 只做删除, 声明式, 无逻辑
- hooks: 任意操作 (增/删/改/链接/权限), 命令式, 可编程
