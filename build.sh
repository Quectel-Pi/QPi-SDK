#!/usr/bin/env bash
#
# Quectel PI H1 (QCS6490) simple-h1 SDK 构建入口
# 命令集与 QPi-SDK (M2/RK3576) 的 build.sh 兼容 —— 同一套命令在两个 SDK 通用
#
# 用法:
#   source build.sh
#   newapp <应用名> [模板]     # 从模板创建应用 (默认模板 hello)
#   buildapp <应用目录>        # 编译应用 (自动识别 Makefile/CMake)
#   buildenv / setenv        一键配置构建环境 (依赖安装/底包下载/sysroot/校验)
#   buildfetch               固件底包下载 (缺什么补什么; 见 buildfetch help)
#   buildkernel               # 编译内核 (Image + dtb + modules)
#   buildboot                 # 打包启动镜像 (efi.bin + dtb.bin)
#   buildoverlays             # 设备树 overlays (simple-h1: 预置 dtbo, 见说明)
#   buildrootfs               # 应用 overlay/ 打包 system.img
#   buildall                  # 完整打包 (内核 + efi.bin + dtb.bin + system.img)
#   buildmenuconfig           # 内核 menuconfig
#   builddefconfig            # 恢复基准配置
#   buildsavedefconfig        # 保存当前配置为基准
#   buildclean                # 清理构建产物
#
# 命令帮助: buildhelp
# 直接执行: ./build.sh <命令>  (与 source 后调用等价)

_qpi_build_is_sourced() {
    [ "${BASH_SOURCE[0]}" != "$0" ]
}

QPI_SDK_TOPDIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
export QPI_SDK_TOPDIR
export TOPDIR="$QPI_SDK_TOPDIR"

# ---------------------------------------------------------------------------
# simple-h1 原生环境 (工具链 PATH / CROSS_COMPILE / ARCH / 目录变量)
# ---------------------------------------------------------------------------
# shellcheck source=scripts/env.sh
source "${QPI_SDK_TOPDIR}/scripts/env.sh" >/dev/null

# ---------------------------------------------------------------------------
# 应用交叉编译环境变量 (与 M2 build.sh 导出语义一致)
#   工具链优先级 (M2 同款):
#     1. QPI_CROSS_COMPILE 显式指定
#     2. qcom-rootfs-toolchain (qemu wrapper, 跑 sysroot 内 gcc-14) ← 默认
#     3. 宿主 aarch64-linux-gnu- (兜底)
#   注意: simple-h1 的 aarch64-qcom-linux-gcc 是内核工具链 (无 libc sysroot),
#   不能链接用户态程序, 不用于 buildapp。
# ---------------------------------------------------------------------------
export ARCH="arm64"
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-qcom-linux-}"

ROOTFS_TOOLCHAIN="${QPI_SDK_TOPDIR}/toolchains/qcom-rootfs-toolchain"
if [ -n "${QPI_CROSS_COMPILE:-}" ]; then
    export TOOLCHAIN=""
    export CROSS_COMPILE="${QPI_CROSS_COMPILE}"
    export CC="${CROSS_COMPILE}gcc"
    export CXX="${CROSS_COMPILE}g++"
    export AR="${CROSS_COMPILE}ar"
    export LD="${CROSS_COMPILE}ld"
elif [ -x "${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-gcc" ] && [ -d "${QPI_SDK_TOPDIR}/prebuilds/sysroot" ]; then
    export TOOLCHAIN="${ROOTFS_TOOLCHAIN}"
    export SYSROOT="${QPI_SDK_TOPDIR}/prebuilds/sysroot"
    export CROSS_COMPILE="aarch64-linux-gnu-"
    export CC="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-gcc"
    export CXX="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-g++"
    export CPP="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-cpp"
    export AR="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-ar"
    export AS="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-as"
    export LD="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-ld"
    export NM="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-nm"
    export OBJCOPY="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-objcopy"
    export OBJDUMP="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-objdump"
    export RANLIB="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-ranlib"
    export READELF="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-readelf"
    export STRIP="${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-strip"
    export CFLAGS="--sysroot=${SYSROOT} -I${SYSROOT}/usr/include -I${SYSROOT}/usr/include/aarch64-linux-gnu"
    export CXXFLAGS="${CFLAGS}"
    export CPPFLAGS="${CFLAGS}"
    export LDFLAGS="--sysroot=${SYSROOT} -L${SYSROOT}/usr/lib/aarch64-linux-gnu -L${SYSROOT}/lib/aarch64-linux-gnu"
    export CMAKE_TOOLCHAIN_FILE="${QPI_SDK_TOPDIR}/tools/cmake/aarch64-qcom-rootfs-toolchain.cmake"
elif command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    export TOOLCHAIN=""
    export CROSS_COMPILE="aarch64-linux-gnu-"
    export CC="${CROSS_COMPILE}gcc"
    export CXX="${CROSS_COMPILE}g++"
    export AR="${CROSS_COMPILE}ar"
    export LD="${CROSS_COMPILE}ld"
    export QPI_SYSROOT_MISSING=1
    # 这条回退是"能编过但产物可能不对"的静默陷阱: 宿主 glibc 与设备目标 glibc
    # 不一致, 而且 gcc 对不存在的 --sysroot 不报错, 所以必须显式警告。
    {
        echo "[build.sh] 警告: 未启用 SDK 应用工具链, 回退到宿主 aarch64-linux-gnu-gcc"
        if [ -x "${ROOTFS_TOOLCHAIN}/bin/aarch64-linux-gnu-gcc" ] && [ ! -d "${QPI_SDK_TOPDIR}/prebuilds/sysroot" ]; then
            echo "[build.sh]   原因: 缺少 prebuilds/sysroot"
            echo "[build.sh]   后果: 产物链接宿主 glibc ($(ldd --version 2>/dev/null | head -1 | awk '{print $NF}')), 可能无法在设备上运行"
            echo "[build.sh]   修复: ./tools/fetch-prebuilds.sh fetch && ./tools/extract-sysroot.sh"
        fi
    } >&2
else
    echo "[build.sh] 警告: 未找到可用的 aarch64 应用交叉编译器" >&2
    echo "[build.sh]   获取底包并提取 sysroot 可启用 SDK 工具链:" >&2
    echo "[build.sh]     ./tools/fetch-prebuilds.sh fetch && ./tools/extract-sysroot.sh" >&2
    export QPI_SYSROOT_MISSING=1
    export TOOLCHAIN=""
    export CROSS_COMPILE="aarch64-qcom-linux-"
fi
export QPI_TOOLCHAIN="${TOOLCHAIN}"

if [ -n "${TOOLCHAIN}" ] && [ -d "${TOOLCHAIN}/bin" ]; then
    case ":${PATH}:" in
        *":${TOOLCHAIN}/bin:"*) ;;
        *) export PATH="${TOOLCHAIN}/bin:${PATH}" ;;
    esac
fi

QPI_TEMPLATES_DIR="${QPI_SDK_TOPDIR}/docs/templates"
QPI_APPS_DIR="${QPI_APPS_DIR:-${QPI_SDK_TOPDIR}/projects}"

_qpi_available_templates() {
    find "${QPI_TEMPLATES_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null
}

# ---------------------------------------------------------------------------
# 应用开发 (与扩展「新建工程」及 M2 语义一致; 应用创建到 projects/ 目录)
# ---------------------------------------------------------------------------

# 从模板创建新应用: newapp <名称> [模板名] [KEY=VALUE ...]
#   模板变量取自 docs/templates/<模板>/template.json, 与扩展「新建工程」语义一致:
#     - {{KEY}}        替换为变量值 (缺省用 template.json 的 default)
#     - {{KEY_SELECT}} choice 类型额外注入, 值为选项下标 (0 起)
#     - SYSROOT ?= 行 改写为从工程目录到 prebuilds/sysroot 的相对路径
#   可用 KEY=VALUE 覆盖模板默认值, 例: newapp myapp hello LOG_LEVEL=debug
newapp() {
    local name="${1:-}"
    local template="${2:-hello}"
    shift 2 2>/dev/null || shift $#

    if [ -z "$name" ]; then
        echo "用法: newapp <应用名> [模板名] [KEY=VALUE ...]"
        echo "可用模板: $(_qpi_available_templates)"
        return 1
    fi
    case "$name" in
        *[!a-zA-Z0-9_]*) echo "ERROR: 应用名仅限字母/数字/下划线"; return 1 ;;
    esac

    local tpl_dir="${QPI_TEMPLATES_DIR}/${template}"
    local dst_dir="${QPI_APPS_DIR}/${name}"
    if [ ! -d "${tpl_dir}" ]; then
        echo "ERROR: 模板不存在: ${template}"
        echo "可用模板: $(_qpi_available_templates)"
        return 1
    fi
    if [ -e "${dst_dir}" ]; then
        echo "ERROR: 已存在: ${dst_dir}"
        return 1
    fi

    mkdir -p "${dst_dir}"

    # 复制模板文件 (template.json 为元数据, 不复制)
    local f
    for f in "${tpl_dir}"/*; do
        [ -f "$f" ] || continue
        [ "$(basename "$f")" = "template.json" ] && continue
        cp "$f" "${dst_dir}/"
    done

    # 变量替换 + SYSROOT 改写 (与扩展 create_project 同语义)
    python3 - "${tpl_dir}" "${dst_dir}" "${QPI_SDK_TOPDIR}" "$name" "$@" <<'PYEOF'
import json, os, re, sys

tpl_dir, dst_dir, sdk_root, app_name = sys.argv[1:5]
overrides = {}
for a in sys.argv[5:]:
    if "=" in a:
        k, v = a.split("=", 1)
        overrides[k] = v

meta = {}
tj = os.path.join(tpl_dir, "template.json")
if os.path.isfile(tj):
    try:
        meta = json.load(open(tj, encoding="utf-8"))
    except Exception as e:
        print(f"  [WARN] template.json 解析失败: {e}")

repl = {}
for key, spec in (meta.get("variables") or {}).items():
    val = overrides.get(key, spec.get("default", ""))
    repl[key] = str(val)
    if spec.get("type") == "choice" and spec.get("choices"):
        idx = next((i for i, c in enumerate(spec["choices"])
                    if c.get("value") == str(val)), 0)
        repl[key + "_SELECT"] = str(idx)

# 未在 template.json 中声明但常见的内建变量
repl.setdefault("PROJECT_NAME", app_name)   # 兼容旧模板
repl.setdefault("APP_NAME", app_name)

# SYSROOT 相对路径: 从工程目录到 <SDK>/prebuilds/sysroot
sysroot_rel = os.path.relpath(os.path.join(sdk_root, "prebuilds", "sysroot"),
                              dst_dir).replace("\\", "/")

RX = r"^SYSROOT\s*\?=.*$"
changed = 0
for fn in sorted(os.listdir(dst_dir)):
    fp = os.path.join(dst_dir, fn)
    if not os.path.isfile(fp):
        continue
    try:
        content = open(fp, encoding="utf-8").read()
    except Exception:
        continue
    for k, v in repl.items():
        content = content.replace("{{" + k + "}}", v)
    if fn == "Makefile":
        content, n = re.subn(RX, f"SYSROOT ?= {sysroot_rel}", content, flags=re.M)
        changed += n
    open(fp, "w", encoding="utf-8").write(content)

left = []
for fn in sorted(os.listdir(dst_dir)):
    fp = os.path.join(dst_dir, fn)
    if os.path.isfile(fp):
        try:
            left += re.findall(r"\{\{[A-Z_]+\}\}", open(fp, encoding="utf-8").read())
        except Exception:
            pass

print(f"  模板变量: {', '.join(f'{k}={v}' for k, v in repl.items())}")
print(f"  SYSROOT : {sysroot_rel}  (改写 {changed} 行)")
if left:
    print(f"  [WARN] 未替换占位符: {', '.join(sorted(set(left)))}")
PYEOF

    echo "已创建应用: ${dst_dir}"
    echo "编译: buildapp ${dst_dir}"
    echo "安装到 overlay: ./scripts/install-app.sh projects/${name}  (然后 buildrootfs 打包)"
}


# 编译应用: buildapp <目录> (自动识别 Makefile/CMake, 与 M2 一致)
buildapp() {
    local dir="${1:-}"
    local app_dir

    # 解析目标目录: 给了参数就用参数, 没给就用当前目录 (支持 cd <app> && buildapp)
    if [ -z "${dir}" ]; then
        app_dir="$(pwd)"
    else
        app_dir="$(cd "$dir" 2>/dev/null && pwd)" || { echo "ERROR: 目录不存在: $dir"; return 1; }
    fi

    # 拦住"在 SDK 根目录执行": 顶层 Makefile 的默认目标是 newapp,
    # 会让 make 凭空建出一个工程 (且名字取自环境变量 NAME), 必须明确报错。
    if [ "${app_dir}" = "${QPI_SDK_TOPDIR}" ]; then
        echo "ERROR: 不能在 SDK 根目录执行 buildapp"
        echo "       顶层 Makefile 的默认目标是 newapp, 会凭空创建工程"
        echo "用法:  buildapp <应用目录>      例: buildapp projects/myapp"
        echo "       (进入工程目录后可省略参数: cd projects/myapp && buildapp)"
        return 1
    fi

    if [ -f "${app_dir}/CMakeLists.txt" ]; then
        (cd "${app_dir}" && cmake -S . -B build && cmake --build build) || return 1
    elif [ -f "${app_dir}/Makefile" ]; then
        (cd "${app_dir}" && make) || return 1
    else
        echo "ERROR: 未找到 CMakeLists.txt 或 Makefile: ${app_dir}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 内核 / 固件 (映射到 scripts/ 原生实现)
# ---------------------------------------------------------------------------

# 一键配置构建环境 (与 M2 buildenv/setenv 语义一致):
#   [1/4] 系统构建依赖检查/安装 (setup-deps.sh, 缺失自动 apt 安装, sudo 密码从 stdin 读)
#   [2/4] 固件底包检查 (prebuilds/efi.bin dtb.bin system.img; 缺失时按官方地址自动下载)
#   [3/4] sysroot 检查 (缺失时从 system.img btrfs restore 提取, 免 root)
#   [4/4] 环境校验 (build-kernel check + build-rootfs check)
#
# 底包下载行为 (避免意外触发数 GB 下载):
#   交互终端      -> 询问确认后下载 (回车 = 下载, n = 跳过)
#   非交互 (扩展/CI/管道) -> 默认不下载, 只报错并给出下一步命令;
#                            需要自动下载时设 QPI_AUTO_FETCH=1
#   QPI_NO_FETCH=1        -> 任何情况下都禁用自动下载 (只检查)
#   其他: QPI_PREBUILDS_URL 覆盖下载地址; QPI_DL_DIR 指定缓存目录
buildenv() {
    echo " == [1/4] 检查 / 安装系统构建依赖 (sudo 密码从 stdin 读取) =="
    "${QPI_SDK_TOPDIR}/tools/setup-deps.sh" install || { echo "[buildenv] [1/4] 失败"; return 1; }

    echo " == [2/4] 检查固件底包 prebuilds =="
    local missing
    missing="$("${QPI_SDK_TOPDIR}/tools/fetch-prebuilds.sh" check 2>/dev/null)"
    if [ -n "${missing}" ]; then
        echo "[INFO] 缺少固件底包: $(echo "${missing}" | tr '\n' ' ')"
        if [ "${QPI_NO_FETCH:-0}" = "1" ]; then
            echo "[ERROR] QPI_NO_FETCH=1, 已禁用自动下载"
            echo "[ERROR] 请手动放置到底包目录, 或先执行: buildfetch fetch"
            echo "[buildenv] [2/4] 失败: 固件底包不完整"
            return 1
        fi
        # 决定是否下载: 交互终端询问; 非交互仅当 QPI_AUTO_FETCH=1 才下载
        # (扩展 / CI 走非交互路径: 数 GB 下载不能无提示地挂在这里)
        local do_fetch=0
        if [ -t 0 ]; then
            echo "[INFO] 官方底包约 3.2 GiB, 首次下载耗时较长 (已下载过的会断点续传/复用缓存)"
            printf "[?] 立即下载官方底包? [Y/n] "
            local ans=""
            read -r ans || true
            case "${ans}" in [Nn]*) do_fetch=0 ;; *) do_fetch=1 ;; esac
        elif [ "${QPI_AUTO_FETCH:-0}" = "1" ]; then
            echo "[INFO] QPI_AUTO_FETCH=1 (非交互), 自动下载固件底包"
            do_fetch=1
        fi
        if [ "${do_fetch}" = "1" ]; then
            echo "[INFO] 下载固件底包 (buildfetch)..."
            "${QPI_SDK_TOPDIR}/tools/fetch-prebuilds.sh" fetch \
                || { echo "[buildenv] [2/4] 失败: 固件底包获取失败"; return 1; }
        else
            echo "[ERROR] 固件底包不完整, 且当前为无提示环境 (未自动下载)"
            echo "[ERROR] 请执行以下任一命令获取 (可断点续传):"
            echo "[ERROR]     ./tools/fetch-prebuilds.sh fetch      # 直接下载"
            echo "[ERROR]     source build.sh && buildfetch fetch  # 命令层等价写法"
            echo "[ERROR]   若希望非交互环境自动下载: QPI_AUTO_FETCH=1 buildenv"
            echo "[buildenv] [2/4] 失败: 固件底包不完整"
            return 1
        fi
    else
        echo "[OK] 固件底包齐全 (efi.bin / dtb.bin / system.img)"
    fi

    echo " == [3/4] 检查应用编译 sysroot =="
    if [ ! -d "${QPI_SDK_TOPDIR}/prebuilds/sysroot" ] || [ -z "$(ls -A "${QPI_SDK_TOPDIR}/prebuilds/sysroot" 2>/dev/null)" ]; then
        echo "[INFO] sysroot 缺失, 从 system.img 提取 (btrfs restore, 免 root)..."
        "${QPI_SDK_TOPDIR}/tools/extract-sysroot.sh" || { echo "[buildenv] [3/4] 失败"; return 1; }
    else
        echo "[OK] sysroot 已存在, 跳过提取"
    fi

    echo " == [4/4] 环境校验 =="
    "${QPI_SDK_TOPDIR}/tools/build-kernel.sh" check || { echo "[buildenv] [4/4] 失败"; return 1; }
    "${QPI_SDK_TOPDIR}/tools/build-rootfs.sh" check || { echo "[buildenv] [4/4] 失败"; return 1; }
    echo "[buildenv] 构建环境配置完成"
}

# 固件底包: buildfetch [check|fetch|hash|pin|clean]
#   buildfetch            缺什么补什么 (已齐全则跳过)
#   buildfetch check      只检查缺失
#   buildfetch fetch      下载 + sha256 校验 + 解压到 prebuilds/
#   buildfetch hash/pin   查看 / 固化压缩包 sha256
#   buildfetch clean      清理下载缓存 (不动 prebuilds/)
buildfetch() {
    "${QPI_SDK_TOPDIR}/tools/fetch-prebuilds.sh" "${@:-fetch}"
}

# 兼容别名: 早期文档 / 外部脚本里的 buildcheck 就是现在的 buildenv
#   (buildenv 相较旧 buildcheck 增加了依赖安装与底包下载, 语义更宽)
buildcheck() {
    buildenv "$@"
}

buildkernel() {
    "${QPI_SDK_TOPDIR}/scripts/build-kernel.sh" "$@"
}

buildboot() {
    "${QPI_SDK_TOPDIR}/scripts/pack-efi.sh" && \
    "${QPI_SDK_TOPDIR}/scripts/pack-dtb.sh"
}

buildoverlays() {
    "${QPI_SDK_TOPDIR}/tools/build-kernel.sh" overlays
}

buildrootfs() {
    # 目录级可复现打包: base + overlay → staging → mkfs 全新生成 system.img
    # (免挂载修改, 免 root; 见 tools/build-rootfs.sh 头部说明)
    #
    # 打包前先做底包新鲜度检查 (联网失败则用本地继续; 厂商已更新则先换新再打包):
    _qpi_prebuilds_refresh || return 1
    "${QPI_SDK_TOPDIR}/tools/build-rootfs.sh" build
}

# 打包 system.img 前的底包新鲜度检查 (薄封装, 便于统一开关)
#   QPI_NO_REFRESH=1   跳过检查
#   QPI_ALLOW_STALE=1  厂商包已更新但下载失败时, 仍用旧底包继续
_qpi_prebuilds_refresh() {
    [ "${QPI_NO_REFRESH:-0}" = "1" ] && { echo "[build.sh] QPI_NO_REFRESH=1, 跳过底包新鲜度检查"; return 0; }
    "${QPI_SDK_TOPDIR}/tools/fetch-prebuilds.sh" refresh
}

buildall() {
    # 全量: 内核(可跳过) + efi.bin/dtb.bin + system.img (目录级可复现打包)
    # 应用层改动: SKIP_KERNEL=1 buildall
    if [ "${SKIP_KERNEL:-0}" != "1" ]; then
        "${QPI_SDK_TOPDIR}/scripts/build-kernel.sh" || return 1
    else
        echo "[build.sh] SKIP_KERNEL=1, 跳过内核编译"
    fi
    "${QPI_SDK_TOPDIR}/scripts/pack-efi.sh" || return 1
    "${QPI_SDK_TOPDIR}/scripts/pack-dtb.sh" || return 1
    # system.img 打包前做底包新鲜度检查 (同上)
    _qpi_prebuilds_refresh || return 1
    "${QPI_SDK_TOPDIR}/tools/build-rootfs.sh" build || return 1
    echo "[build.sh] buildall 完成: ${OUT_DIR:-build/result}/{efi.bin, dtb.bin, system.img}"
}

# ---------------------------------------------------------------------------
# 内核配置
# ---------------------------------------------------------------------------

buildmenuconfig() {
    # 用子 shell 执行, 避免 source 后把用户的 cwd 留在内核源码目录
    mkdir -p "${KERNEL_OUT}"
    (cd "${KERNEL_SRC}" && make O="${KERNEL_OUT}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" menuconfig) || return 1
    # 注意: menuconfig 退出码不区分"保存"与"未保存", 所以不能断言已保存
    echo "menuconfig 已退出 (配置仅在选择 < Save > 时写入)"
    echo "当前 ${KERNEL_OUT}/.config 会被下次 buildkernel/buildall 沿用 (增量编译)"
}

builddefconfig() {
    # 恢复基准配置 (scripts/kernel-config, 与官方 6.6.116-qli-1.7-ver.1.1 一致)
    echo "恢复基准配置: scripts/kernel-config -> ${KERNEL_OUT}/.config"
    cp "${QPI_SDK_TOPDIR}/scripts/kernel-config" "${KERNEL_OUT}/.config"
    (cd "${KERNEL_SRC}" && make O="${KERNEL_OUT}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig)
    echo "基准配置已恢复"
}

buildsavedefconfig() {
    # 将当前 .config 精简保存为基准
    #   顺序很重要: 必须"先备份旧基准, 再写入新配置"。
    #   反过来的话 .bak 里存的是刚写进去的新配置, 旧基准就永久丢了。
    (cd "${KERNEL_SRC}" && make O="${KERNEL_OUT}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" savedefconfig) || return 1
    local cfg="${QPI_SDK_TOPDIR}/scripts/kernel-config"
    if [ -f "${cfg}" ]; then
        cp "${cfg}" "${cfg}.bak" && echo "旧基准已备份: scripts/kernel-config.bak"
    fi
    cp "${KERNEL_OUT}/defconfig" "${cfg}" && echo "已保存基准配置: scripts/kernel-config"
}

# ---------------------------------------------------------------------------
# 其他
# ---------------------------------------------------------------------------

buildclean() {
    echo "清理构建产物 (build/)..."
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"
    echo "清理完成 (下次 buildall 会重新生成)"
}

buildhelp() {
    echo ""
    echo "============================================================"
    echo "  Quectel PI H1 (QCS6490) simple-h1 SDK Build System"
    echo "  命令集与 QPi-SDK (M2) 兼容"
    echo "============================================================"
    echo "  用法: source build.sh 后直接输入以下命令"
    echo ""
    echo "  ── 应用开发 (App) ──"
    echo "    newapp <名称> [模板]   从模板创建应用 (默认模板 hello)"
    echo "    buildapp <目录>        编译应用 (自动识别 Makefile/CMake)"
    echo ""
    echo "  ── 内核 / 固件 ──"
    echo "    buildenv / setenv     配置构建环境 (依赖安装/底包下载/sysroot/校验)"
    echo "                          (buildcheck 为兼容别名)"
    echo "    buildfetch            固件底包下载 (check|fetch|hash|pin|clean)"
    echo "    buildkernel            编译内核 (Image + dtb + modules)"
    echo "    buildboot              打包启动镜像 (efi.bin + dtb.bin)"
    echo "    buildoverlays          设备树 overlays (预置 dtbo 说明)"
    echo "    buildrootfs            应用 overlay/ 打包 system.img"
    echo "    buildall               完整打包 (内核+efi.bin+dtb.bin+system.img)"
    echo "                           (仅应用层改动: SKIP_KERNEL=1 buildall)"
    echo ""
    echo "  ── 内核配置 ──"
    echo "    buildmenuconfig        内核 menuconfig"
    echo "    builddefconfig         恢复基准配置"
    echo "    buildsavedefconfig     保存当前配置为基准 (kernel-config)"
    echo ""
    echo "  ── 其他 ──"
    echo "    buildclean             清理构建产物 (build/)"
    echo "============================================================"
    echo ""
}

# ---------------------------------------------------------------------------
# 入口: source 时打印帮助; 直接执行时按参数分发
# ---------------------------------------------------------------------------
if _qpi_build_is_sourced; then
    # source 时仅注册命令并打印帮助。
    # 注意: 迁移等有副作用的操作一律放在下面的 else 分支,
    #       因为扩展会 `source ./build.sh` 复用编译环境 (见 sdk_ops.py:613 build_chain)。
    buildhelp
else
    # 一次性迁移: apps/ -> projects/ (T5, 与扩展默认值及 M2 对齐)
    #   仅在直接执行时触发, source 不触发 (避免用户看到"凭空改名")
    if [ -d "${QPI_SDK_TOPDIR}/apps" ] && [ ! -e "${QPI_SDK_TOPDIR}/projects" ]; then
        echo "[build.sh] 检测到旧目录 apps/, 迁移为 projects/ (与扩展默认值对齐)"
        if mv "${QPI_SDK_TOPDIR}/apps" "${QPI_SDK_TOPDIR}/projects" 2>/dev/null; then
            echo "[build.sh] 迁移完成: apps/ -> projects/"
        else
            echo "[build.sh] [WARN] 迁移失败, 请手动执行: mv apps projects"
        fi
    fi

    cmd="${1:-help}"
    shift || true
    case "$cmd" in
        newapp|new) newapp "$@" ;;
        app|buildapp) buildapp "$@" ;;
        check|buildcheck|setenv|buildenv|env) buildenv "$@";;
        prebuilds|buildprebuilds|fetch|buildfetch|download) buildfetch "$@";;
        kernel|buildkernel) buildkernel "$@" ;;
        boot|buildboot) buildboot "$@" ;;
        overlays|buildoverlays) buildoverlays "$@" ;;
        rootfs|buildrootfs) buildrootfs "$@" ;;
        all|buildall) buildall "$@" ;;
        menuconfig|buildmenuconfig) buildmenuconfig "$@" ;;
        defconfig|builddefconfig) builddefconfig "$@" ;;
        savedefconfig|buildsavedefconfig) buildsavedefconfig "$@" ;;
        clean|buildclean) buildclean "$@" ;;
        help|--help|-h) buildhelp ;;
        *) echo "ERROR: unknown command: $cmd"; buildhelp; exit 1 ;;
    esac
fi
