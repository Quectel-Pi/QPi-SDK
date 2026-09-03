#!/bin/bash
# ============================================================
# simple-h1 pre-pack hook 示例模板
#
# 运行时机: system.img 挂载并应用 overlay / 删除清单之后,
#           卸载打包之前 (即"打包前"对镜像内容的最后调整)
# 运行身份: root (sudo 执行)
#
# 用法:
#   1. 复制本文件为 hooks/10-mycustom.sh
#   2. 编辑其中的操作 (chmod / cp / ln / rm 等)
#   3. 重新打包 system.img 时自动按文件名顺序执行
#      (00- 最先, 99- 最后; 也可用 HOOKS_DIR 环境变量换目录)
#
# 环境变量 (由 pack-system.sh 注入):
#   IMG_MNT          system.img 挂载点 (操作镜像内文件必须以它为前缀!)
#   OUT_IMG          最终输出镜像路径
#   SRC_IMG          原始镜像路径 (prebuilds/system.img)
#   OVERLAY_DIR      overlay 增量目录
#   BUILD_DIR        build 目录
#   SDK_ROOT         项目根目录
#   KERNEL_RELEASE   内核版本字符串 (如 6.6.116-qli-1.7-ver.1.1)
#
# 注意:
#   - 镜像内所有路径都要以 ${IMG_MNT} 为前缀, 例如:
#       chmod 755 "${IMG_MNT}/usr/local/bin/hello-h1"
#   - 创建软链接时, 链接本身放在 ${IMG_MNT}/... 下,
#     而链接目标写设备内的运行时路径 (不带 ${IMG_MNT}):
#       ln -sf /usr/local/bin/hello-h1 "${IMG_MNT}/usr/bin/hello"
#   - 脚本非零退出码会中止整个打包流程 (set -e), 便于尽早发现问题
#   - 本示例脚本无副作用, 可直接保留
# ============================================================
set -e

# ---------- 示例 1: 修改权限 ----------
# chmod 755 "${IMG_MNT}/usr/local/bin/hello-h1"
# chmod 600 "${IMG_MNT}/etc/some-secret.conf"

# ---------- 示例 2: 拷贝宿主机文件进镜像 ----------
# cp /home/igni/Downloads/debian/simple-h1/extra/myfile "${IMG_MNT}/etc/myfile"

# ---------- 示例 3: 创建软链接 (目标为设备运行时路径) ----------
# ln -sf /usr/local/bin/hello-h1 "${IMG_MNT}/usr/bin/hello-h1"

echo "[hook] 00-example.sh 执行完毕 (未做任何修改, 复制后编辑使用)"
