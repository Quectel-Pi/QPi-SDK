#!/bin/bash
# ============================================================
# simple-h1 应用安装脚本
# 功能: 将 apps/ 下的开源项目源码, 通过 make install 机制
#       安装到 overlay 目录 (最终打包进 system.img)
#
# 用法: ./scripts/install-app.sh <app目录> [make参数...]
#   例: ./scripts/install-app.sh apps/hello
#        ./scripts/install-app.sh apps/mymod DESTDIR=/opt/myapp
#
# 约定:
#   - apps/<app>/ 必须包含 Makefile (支持 install 目标)
#   - 默认安装到 overlay 的 /usr/local (DESTDIR=overlay)
#   - 交叉编译应用: 在 apps/<app>/ 提供 build.sh 或使用
#     CROSS_COMPILE=aarch64-qcom-linux- 环境变量
# ============================================================
set -e
cd "$(dirname "$0")/.."
source scripts/env.sh

APP="${1:?用法: ./scripts/install-app.sh <app目录> [make参数...]}"
shift

APP_DIR="${SDK_ROOT}/${APP}"
[ -d "${APP_DIR}" ] || { echo "[ERROR] 应用目录不存在: ${APP_DIR}"; exit 1; }
[ -f "${APP_DIR}/Makefile" ] || { echo "[ERROR] 缺少 Makefile: ${APP_DIR}"; exit 1; }

# 默认安装到 overlay (DESTDIR=overlay, PREFIX=/usr/local → 最终路径 overlay/usr/local)
DESTDIR="${DESTDIR:-${OVERLAY_DIR}}"
PREFIX="${PREFIX:-/usr/local}"

echo "=========================================="
echo "[simple-h1] 安装应用: ${APP}"
echo "  源码:     ${APP_DIR}"
echo "  DESTDIR:  ${DESTDIR}"
echo "  PREFIX:   ${PREFIX}"
echo "=========================================="

cd "${APP_DIR}"

# 如果应用有交叉编译配置脚本, 先执行
if [ -f "./build.sh" ]; then
    echo "[simple-h1] 执行应用构建脚本 ./build.sh"
    bash ./build.sh
fi

# 执行 make install (支持 make 参数)
echo "[simple-h1] make install DESTDIR=${DESTDIR} PREFIX=${PREFIX} $*"
make install DESTDIR="${DESTDIR}" PREFIX="${PREFIX}" "$@"

echo ""
echo "[simple-h1] 应用安装完成 ✓"
echo "  已安装到: ${DESTDIR}"
echo "  运行 ./scripts/pack-system.sh 重新打包 system.img 生效"
