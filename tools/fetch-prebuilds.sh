#!/usr/bin/env bash
# ============================================================================
# fetch-prebuilds.sh - H1 (QCS6490) 固件底包一键获取 (下载 + 校验 + 解压)
# ============================================================================
# 背景:
#   prebuilds/ 里的厂商固件底包 (system.img / efi.bin / dtb.bin 等) 体积达数 GB,
#   不进 git 仓库 (.gitignore 排除), 新 clone 的机器上是空的。
#   本脚本按固定官方地址下载底包压缩包, 校验后解压到 prebuilds/, 使
#   buildenv / buildrootfs / buildall / flash 可以继续。
#
# 用法:
#   ./tools/fetch-prebuilds.sh              # = fetch (已齐全则跳过)
#   ./tools/fetch-prebuilds.sh check        # 只检查: 缺失项逐行输出到 stdout (机器可读),
#                                           #   人类提示走 stderr; exit 0=齐全, 1=有缺失
#   ./tools/fetch-prebuilds.sh fetch        # 下载 + 校验 + 解压 (支持断点续传)
#   ./tools/fetch-prebuilds.sh md5          # 对照厂商 md5 文件检查本地包是否最新
#   ./tools/fetch-prebuilds.sh verify       # 校验压缩包内部 CRC (发现"下载被写坏")
#   ./tools/fetch-prebuilds.sh hash         # 打印缓存 zip 的 sha256 (核对用)
#   ./tools/fetch-prebuilds.sh pin          # 把当前缓存 zip 的 sha256 固化到校验文件
#   ./tools/fetch-prebuilds.sh clean        # 删除下载缓存与解压临时目录 (不动 prebuilds/)
#
# 环境变量:
#   QPI_PREBUILDS_URL   覆盖下载地址 (默认官方固定地址, 见 DEFAULT_URL)
#   QPI_MD5_URL         覆盖厂商 md5 文件地址 (默认由 zip 地址推导为 *_md5.txt)
#   QPI_NO_REMOTE_MD5=1 不联网取厂商 md5 (离线环境; 完整性判定会降级)
#   PREBUILDS_DIR       解压目标目录 (默认 <SDK>/prebuilds)
#   QPI_DL_DIR          下载缓存目录 (默认 <SDK>/download, 独立于 build/ 以免被 buildclean 清掉)
#   QPI_SHA256_FILE     校验值文件 (默认 <SDK>/tools/prebuilds.sha256)
#   QPI_KEEP_ZIP=0      解压成功后删除缓存 zip (默认 1=保留, 便于复用/拷给同事)
#   QPI_FETCH_FORCE=1   已齐全也强制重新下载/解压
#   QPI_MIN_FREE_GB     磁盘空间下限, 默认 30 (压缩包 + 解压后峰值)
#   QPI_ARIA2=1         存在 aria2c 时用多连接下载 (默认自动探测)
#
# 依赖: curl 或 wget (下载), unzip 或 python3 (解压), sha256sum (校验)
# ============================================================================
set -uo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="$(cd "${TOOLS_DIR}/.." && pwd)"

# ---- 官方固定下载地址 (可被 QPI_PREBUILDS_URL 覆盖) ----
# 说明: 该 URL 指向厂商"最新"底包, 内容会随厂商更新而变化 (当前实测:
#   3455375965 字节, ETag 6aa76387-cdf4da5d, 与 ..._RD2_A01001.zip 为同一文件)。
#   厂商更新后 sha256 会变, 届时用 `./tools/fetch-prebuilds.sh pin` 刷新校验值。
DEFAULT_URL="https://developer.quectel.com/doc/files/quectel_pi/Quectel_Pi_H1_WF_Debian_RD2_Latest.zip"
URL="${QPI_PREBUILDS_URL:-${DEFAULT_URL}}"
ZIP_NAME="$(basename "${URL%%\?*}")"
# 防御: URL 异常 (空 / 以 / 结尾) 时 basename 可能为空, 会让后续路径变成目录, 报错难以理解
if [ -z "${ZIP_NAME}" ] || [ "${ZIP_NAME}" = "/" ]; then
    echo "[ERROR] 无法从下载地址推断压缩包名: '${URL}'" >&2
    echo "        请检查 QPI_PREBUILDS_URL (应以 .zip 结尾)" >&2
    exit 1
fi
case "${ZIP_NAME}" in
    */*|"") echo "[ERROR] 非法的压缩包名: '${ZIP_NAME}' (来自 '${URL}')" >&2; exit 1 ;;
esac

# ---- 厂商 md5 校验文件 (权威完整性依据) ----
# 约定: 与 zip 同目录, 名字为 "<zip 名去掉 .zip>_md5.txt", 内容就是一个 32 位 md5。
#   实测: https://developer.quectel.com/doc/files/quectel_pi/
#         Quectel_Pi_H1_WF_Debian_RD2_Latest.zip
#         Quectel_Pi_H1_WF_Debian_RD2_Latest_md5.txt  -> "d9ae78d7330c972e8008fdca359e0730"
# 作用: 判断"远端包是否已更新"(以及本地包是否与厂商一致)。这是唯一能证明
#       本地文件与厂商源一致的依据 —— 本地自算的 sha256 做不到这一点 (自我引用)。
MD5_URL="${QPI_MD5_URL:-}"
if [ -z "${MD5_URL}" ] && [ "${QPI_NO_REMOTE_MD5:-0}" != "1" ]; then
    case "${URL%%\?*}" in
        *.zip) MD5_URL="$(dirname "${URL%%\?*}")/$(basename "${URL%%\?*}" .zip)_md5.txt" ;;
    esac
fi

PREBUILDS_DIR="${PREBUILDS_DIR:-${SDK_ROOT}/prebuilds}"
DL_DIR="${QPI_DL_DIR:-${SDK_ROOT}/download}"
SHA_FILE="${QPI_SHA256_FILE:-${TOOLS_DIR}/prebuilds.sha256}"
ZIP_PATH="${DL_DIR}/${ZIP_NAME}"
PART_PATH="${ZIP_PATH}.part"
UNPACK_DIR="${DL_DIR}/unpack"
MIN_FREE_GB="${QPI_MIN_FREE_GB:-30}"

# 底包必需项 (与 buildenv/[2] 段判定一致)
REQUIRED_FILES=(system.img efi.bin dtb.bin)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info() { echo -e "${CYAN}[INFO]${NC} $1" >&2; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }

human() { # 字节 -> 人类可读
    local b="${1:-0}"
    if   [ "$b" -ge 1073741824 ]; then awk -v b="$b" 'BEGIN{printf "%.2f GiB", b/1073741824}'
    elif [ "$b" -ge 1048576 ];    then awk -v b="$b" 'BEGIN{printf "%.0f MiB", b/1048576}'
    elif [ "$b" -ge 1024 ];       then awk -v b="$b" 'BEGIN{printf "%.0f KiB", b/1024}'
    else echo "${b} B"; fi
}

# ---------------------------------------------------------------------------
# 下载进度上报 (与 M2 的 fetch-base-image.sh 同一约定, 供 VS Code 插件消费)
# ---------------------------------------------------------------------------
# 输出机器可读进度标记, 插件后端 (python/quecpi/executor.py) 解析后渲染成
# 右下角通知 + 状态栏的 "下载中 n% (已下 / 总)" 进度条。
# 注意: 插件终端里不会显示这些标记行 (被转成进度事件); 手工运行本脚本时会看到,
#       属正常现象。
emit_progress() {
    local done="${1:-0}" total="${2:-0}" pct=0
    case "${total}" in ''|*[!0-9]*) total=0 ;; esac
    case "${done}"  in ''|*[!0-9]*) done=0 ;; esac
    if [ "${total}" -gt 0 ]; then
        pct=$((done * 100 / total))
        [ "${pct}" -gt 100 ] && pct=100
    fi
    printf '[QPI-PROGRESS] total=%s done=%s pct=%s\n' "${total}" "${done}" "${pct}"
}

# 文件当前字节数 (GNU stat; 回退 BSD stat / wc)
_dl_size() {
    [ -f "$1" ] || { echo 0; return; }
    stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || wc -c < "$1" | tr -d ' '
}

# 后台执行下载 + 每秒轮询已下字节数上报进度, 返回值 = 下载进程退出码。
# 为什么必须后台 + 轮询: curl/wget 自身的进度条用 \r 原地刷新、不产生换行,
#   前台静默运行时整段下载期间没有任何输出 —— 终端看起来像卡死, 插件侧 SSE 也会
#   因长时间无数据被 bodyTimeout 掐断。轮询文件大小则每秒都有稳定的进度产出。
download_with_progress() {
    local out="$1" total="${2:-0}"; shift 2
    local rc=0 pid
    "$@" &
    pid=$!
    while kill -0 "${pid}" 2>/dev/null; do
        emit_progress "$(_dl_size "${out}")" "${total}"
        sleep 1
    done
    wait "${pid}" || rc=$?
    emit_progress "$(_dl_size "${out}")" "${total}"
    return "${rc}"
}

# ---------------------------------------------------------------------------
# 缺失项检测 (只用本机已有的文件判断, 不联网)
# ---------------------------------------------------------------------------
missing_files() {
    local f
    for f in "${REQUIRED_FILES[@]}"; do
        [ -s "${PREBUILDS_DIR}/${f}" ] || echo "$f"
    done
}

# 可选: 厂商压缩包里若带 base_rootfs / sysroot, 也提示
missing_optional() {
    local d
    for d in base_rootfs sysroot; do
        [ -d "${PREBUILDS_DIR}/${d}" ] && [ -n "$(ls -A "${PREBUILDS_DIR}/${d}" 2>/dev/null)" ] || echo "$d"
    done
}

cmd_check() {
    local miss; miss="$(missing_files)"
    if [ -z "$miss" ]; then
        log_ok "固件底包齐全 (${PREBUILDS_DIR})"
        local opt; opt="$(missing_optional)"
        [ -n "$opt" ] && log_info "可选目录尚缺: $(echo "$opt" | tr '\n' ' ') (不阻塞内核/镜像打包, 由 extract 生成)"
        return 0
    fi
    log_err "缺少固件底包 (${PREBUILDS_DIR}):"
    echo "$miss" | sed 's/^/    /' >&2
    log_info "获取: ./tools/fetch-prebuilds.sh fetch   (或 source build.sh && buildenv)"
    log_info "  地址: ${URL}"
    echo "$miss"
    return 1
}

# ---------------------------------------------------------------------------
# 下载
# ---------------------------------------------------------------------------
remote_size() {
    curl -sIL --max-time 60 "${URL}" 2>/dev/null \
        | awk 'BEGIN{IGNORECASE=1} /^content-length:/{v=$2} END{gsub(/\r/,"",v); print v}'
}

# 取厂商 md5 文件里的 32 位 md5。取不到则返回非 0 (调用方据此降级)。
remote_md5() {
    [ -n "${MD5_URL}" ] || return 1
    [ "${QPI_NO_REMOTE_MD5:-0}" = "1" ] && return 1
    local out
    out="$(curl -fsSL --max-time 60 "${MD5_URL}" 2>/dev/null)" || return 1
    printf '%s' "${out}" | grep -oiE '[0-9a-f]{32}' | head -1
}

# 本地文件的 md5 (大文件需要算一会儿)
file_md5() {
    [ -f "$1" ] || return 1
    md5sum "$1" 2>/dev/null | awk '{print $1}'
}

# 判断本地完整 zip 是否与厂商一致; 输出:
#   0 = 一致(可复用)  1 = 不一致(包已更新或本地损坏)  2 = 无法判定
local_zip_status() {
    [ -s "${ZIP_PATH}" ] || return 2
    local rmd5; rmd5="$(remote_md5)" || return 2
    local lmd5; lmd5="$(file_md5 "${ZIP_PATH}")" || return 2
    if [ "${lmd5}" = "${rmd5}" ]; then
        echo "${lmd5}"
        return 0
    fi
    echo "本地 ${lmd5} / 厂商 ${rmd5}"
    return 1
}

# 判断厂商包是否已更新 (便宜: 只对比 manifest 记录的厂商 md5 与当前远端 md5,
# 不做本地哈希计算)。返回 0=未变 1=已更新 2=无法判定
vendor_pkg_changed() {
    local mf="${PREBUILDS_DIR}/.source-manifest"
    [ -f "${mf}" ] || return 2
    local rec; rec="$(awk -F= '/^VENDOR_MD5=/{print $2; exit}' "${mf}")"
    [ -n "${rec}" ] || return 2
    case "${rec}" in *未取得*|"") return 2 ;; esac
    local cur; cur="$(remote_md5)" || return 2
    [ "${rec}" = "${cur}" ] && return 0
    echo "记录 ${rec} / 现在 ${cur}"
    return 1
}

check_space() {
    local need_gb="${1:-${MIN_FREE_GB}}"
    local avail_gb
    avail_gb="$(df -Pk "${DL_DIR}" 2>/dev/null | awk 'NR==2{printf "%d", $4/1024/1024}')"
    [ -n "${avail_gb}" ] || return 0
    if [ "${avail_gb}" -lt "${need_gb}" ]; then
        log_err "磁盘空间不足: ${DL_DIR} 所在分区可用 ${avail_gb} GiB, 需要约 ${need_gb} GiB"
        log_err "  压缩包 + 解压峰值 (system.img 约 13G) 都要占空间; 可用 QPI_DL_DIR 换位置, 或 QPI_MIN_FREE_GB 放宽"
        return 1
    fi
    log_info "磁盘余量 ${avail_gb} GiB (阈值 ${need_gb} GiB)"
    return 0
}

download_zip() {
    mkdir -p "${DL_DIR}" || return 1

    # 已下载完的完整包: 先用厂商 md5 判断是否仍是最新, 再决定复用还是重下
    if [ -s "${ZIP_PATH}" ] && [ -z "${QPI_FETCH_FORCE:-}" ]; then
        local status st
        status="$(local_zip_status)"; st=$?
        if [ "${st}" = "0" ]; then
            log_ok "本地压缩包与厂商 md5 一致, 复用: ${ZIP_PATH}"
            log_info "  md5 = ${status}"
            return 0
        elif [ "${st}" = "1" ]; then
            # 包已更新(或本地损坏): 必须重新下载, 否则后面解压/打包都基于过期数据
            log_warn "本地压缩包与厂商 md5 不一致 -> 厂商包已更新或本地文件损坏"
            log_warn "  ${status}"
            log_warn "  重新下载最新包 (旧文件移到 .stale 保留备查)"
            mv -f "${ZIP_PATH}" "${ZIP_PATH}.stale" 2>/dev/null || rm -f "${ZIP_PATH}"
            rm -f "${PART_PATH}"
        else
            # 拿不到厂商 md5 (离线/该文件不存在): 退回"按大小"判断
            local rsz; rsz="$(remote_size)"
            local lsz; lsz="$(stat -c%s "${ZIP_PATH}")"
            if [ -z "${rsz}" ] || [ "${lsz}" = "${rsz}" ]; then
                log_ok "复用已下载的压缩包: ${ZIP_PATH} ($(human "${lsz}"))"
                log_warn "  (未能获取厂商 md5, 未做权威完整性校验)"
                return 0
            fi
            log_warn "本地压缩包大小与远端不一致 (本地 $(human "${lsz}") vs 远端 $(human "${rsz}")), 按残缺处理"
            mv -f "${ZIP_PATH}" "${PART_PATH}"
        fi
    fi

    local rsz; rsz="$(remote_size)"
    [ -n "${rsz}" ] && log_info "远端大小: $(human "${rsz}")"
    local rmd5; rmd5="$(remote_md5)" || true
    if [ -n "${rmd5}" ]; then
        log_info "厂商 md5: ${rmd5}  (下载完成后据此校验)"
    else
        log_warn "未能获取厂商 md5 文件 (${MD5_URL:-未配置}), 将仅按大小判断完整性"
    fi
    check_space || return 1

    if [ -s "${PART_PATH}" ]; then
        local psz
        psz="$(stat -c%s "${PART_PATH}")"
        # 厂商 "Latest" 包更新后, 本地 .part 可能大于远端 (旧版包更大):
        # 此时续传偏移已超过文件长度, 服务器必然回 416, 必须作废旧文件重新下载
        if [ -n "${rsz}" ] && [ "${psz}" -ge "${rsz}" ]; then
            log_warn "未完成文件 $(human "${psz}") 已不小于远端大小 $(human "${rsz}") (旧版底包残留)"
            log_warn "  续传不可行 (HTTP 416), 将旧文件移到 .stale 后重新下载"
            mv -f "${PART_PATH}" "${PART_PATH}.stale" 2>/dev/null || rm -f "${PART_PATH}"
        else
            log_info "检测到未完成文件 $(human "${psz}"), 断点续传..."
        fi
    fi

    # 优先 aria2c (多连接, 有则明显更快), 其次 curl -C -, 最后 wget -c
    if [ -n "${QPI_ARIA2:-}" ] && command -v aria2c >/dev/null 2>&1; then
        log_info "使用 aria2c (多连接): ${URL}"
        download_with_progress "${PART_PATH}" "${rsz}" \
            aria2c -c -x 8 -s 8 -k 1M --file-allocation=none \
                   --console-log-level=error --summary-interval=0 \
                   -d "${DL_DIR}" -o "$(basename "${PART_PATH}")" "${URL}" || {
            log_err "aria2c 下载失败"; return 1; }
    elif command -v curl >/dev/null 2>&1; then
        log_info "使用 curl 下载 (支持断点续传): ${URL}"
        log_info "  预计耗时较长 (约 3.2 GiB), 中断后重跑本命令会自动续传"
        # 关键: 不要用 curl 的 --retry 处理大文件续传。
        #   -C - 只在【进程启动时】计算一次偏移; curl 内部重试会丢弃已收数据从头再来
        #   (实测遇到: "curl: (56) OpenSSL SSL_read ... unexpected eof" 后
        #    "Throwing away 2484043776 bytes", 2.26GB 进度全丢)。
        # 正确做法: 外层 bash 循环, 每次失败都【重新启动 curl】, 让它重新读取
        #   .part 当前大小并从该偏移续传。只有连接层错误才重试。
        local attempt=0 max_attempts="${QPI_DL_ATTEMPTS:-40}"
        local prev_size cur_size stall=0
        while :; do
            attempt=$((attempt+1))
            prev_size="$(stat -c%s "${PART_PATH}" 2>/dev/null || echo 0)"

            # -sS: 静默掉 curl 原生进度条 (改由 [QPI-PROGRESS] 上报) 但保留错误信息
            download_with_progress "${PART_PATH}" "${rsz}" \
                curl -L -C - --fail --connect-timeout 30 --max-time 0 \
                     --retry 0 --speed-limit 1024 --speed-time 30 \
                     -sS -o "${PART_PATH}" "${URL}" && break

            local rc=$?
            cur_size="$(stat -c%s "${PART_PATH}" 2>/dev/null || echo 0)"
            # 文件已不小于远端 -> 服务器会一直回 416, 重试无意义, 立即放弃并给出处理办法
            if [ -n "${rsz}" ] && [ "${cur_size}" -ge "${rsz}" ]; then
                log_err "本地文件 $(human "${cur_size}") 已不小于远端 $(human "${rsz}"), 无法续传 (服务端 416)"
                log_err "  处理: rm -f ${PART_PATH} && $0 fetch   (删除旧缓存后重新下载)"
                return 1
            fi
            if [ "${cur_size}" -gt "${prev_size}" ]; then
                stall=0
                log_warn "  下载中断 (curl rc=${rc}), 已续传到 $(human "${cur_size}"), 重试 ${attempt}/${max_attempts}..."
            else
                stall=$((stall+1))
                log_warn "  下载中断且无进展 (curl rc=${rc}, 仍为 $(human "${cur_size}")), 重试 ${attempt}/${max_attempts}..."
            fi

            if [ "${attempt}" -ge "${max_attempts}" ]; then
                log_err "连续 ${max_attempts} 次失败, 放弃 (已下 $(human "${cur_size}"))"
                log_err "  稍后重跑本命令可继续: $0 fetch"
                return 1
            fi
            # 连续 5 次毫无进展 -> 大概率服务端不可用, 尽早退出而不是空转
            if [ "${stall}" -ge 5 ]; then
                log_err "连续 5 次重试都没有任何进展, 判定服务端异常, 放弃"
                log_err "  已保留 $(human "${cur_size}"): ${PART_PATH}"
                return 1
            fi
            sleep $(( attempt * 3 > 30 ? 30 : attempt * 3 ))
        done
    elif command -v wget >/dev/null 2>&1; then
        log_info "使用 wget 下载 (支持断点续传): ${URL}"
        download_with_progress "${PART_PATH}" "${rsz}" \
            wget -c -q -O "${PART_PATH}" "${URL}" || { log_err "wget 下载失败"; return 1; }
    else
        log_err "未找到 curl / wget / aria2c, 无法下载"
        log_err "  安装: ./tools/setup-deps.sh install"
        return 1
    fi

    local lsz; lsz="$(stat -c%s "${PART_PATH}")"
    # 远端大小未知 (HEAD 失败/网络抖动) 时不能断定完整性: 保留 .part 不升级为 .zip,
    # 否则被截断的 3GB 级固件会被当成"完整包"进入解压, 后续报错难以定位。
    if [ -z "${rsz}" ]; then
        log_err "无法获知远端大小, 不能确认下载完整"
        log_err "  已保留 ${PART_PATH} ($(human "${lsz}")) 供续传; 重跑本命令即可: $0 fetch"
        return 1
    fi
    if [ "${lsz}" != "${rsz}" ]; then
        log_err "下载不完整: 本地 $(human "${lsz}") / 远端 $(human "${rsz}")"
        log_err "  重跑本命令继续续传 (文件保留在 ${PART_PATH})"
        return 1
    fi

    # 大小对了还不够: 必须与厂商 md5 一致才算拿到权威确认的包。
    # (仅大小相符无法发现"内容被写坏"; 这正是此前 system.img 解压失败的场景。)
    if [ -n "${rmd5}" ]; then
        log_info "校验厂商 md5 (3.2 GiB 需要一两分钟)..."
        local lmd5; lmd5="$(file_md5 "${PART_PATH}")"
        if [ "${lmd5}" != "${rmd5}" ]; then
            log_err "md5 校验失败: 下载内容与厂商不一致"
            log_err "  本地 md5: ${lmd5}"
            log_err "  厂商 md5: ${rmd5}"
            log_err "  该文件已作废, 删除后重新下载:"
            log_err "    rm -f ${PART_PATH} && $0 fetch"
            log_err "  (若是厂商刚更新了包, 上面日志会显示 '厂商包已更新')"
            return 1
        fi
        log_ok "md5 校验通过: ${lmd5}"
    else
        log_warn "未能获取厂商 md5, 已按大小确认完整 (建议随后跑: $0 verify 做 CRC 校验)"
    fi

    mv -f "${PART_PATH}" "${ZIP_PATH}"
    log_ok "下载完成: $(human "$(stat -c%s "${ZIP_PATH}")")"
    return 0
}

# ---------------------------------------------------------------------------
# refresh: 打包 system.img 之前的"底包新鲜度"检查 (由 buildrootfs/buildall 调用)
# ---------------------------------------------------------------------------
# 行为 (按需求):
#   联网失败            -> 使用本地底包继续打包 (不阻塞构建)
#   联网成功且 md5 一致  -> 本地已是最新, 继续打包
#   联网成功且 md5 变了  -> 下载最新包 -> 校验 -> 替换本地 -> 重新解压 -> 继续打包
# 返回: 0 = 可以继续打包; 1 = 必须中止 (厂商包已更新但获取失败)
# 开关: QPI_NO_REFRESH=1   跳过本检查 (完全离线/不想联网时)
#       QPI_ALLOW_STALE=1  厂商包已更新但下载失败时, 仍用旧底包继续打包 (默认中止)
cmd_refresh() {
    if [ "${QPI_NO_REFRESH:-0}" = "1" ]; then
        log_info "QPI_NO_REFRESH=1, 跳过底包新鲜度检查 (使用本地底包)"
        return 0
    fi

    log_info "底包新鲜度检查 (打包前)..."

    # --- 1) 取厂商 md5; 失败即退回本地, 不阻塞构建 ---
    local rmd5; rmd5="$(remote_md5)" || rmd5=""
    if [ -z "${rmd5}" ]; then
        log_warn "联网失败或取不到厂商 md5 -> 使用本地底包继续打包"
        return 0
    fi
    log_info "  厂商 md5: ${rmd5}"

    # --- 2) 与本地比对 ---
    local changed=0 how=""
    if [ -s "${ZIP_PATH}" ]; then
        log_info "  计算本地包 md5 (3.2 GiB 需要一两分钟)..."
        local lmd5; lmd5="$(file_md5 "${ZIP_PATH}")"
        if [ "${lmd5}" = "${rmd5}" ]; then
            log_ok "  本地底包已是最新 (md5 一致), 继续打包"
            return 0
        fi
        changed=1; how="本地包 md5=${lmd5}"
    else
        # 没有缓存 zip: 看 manifest 里记录的厂商 md5
        local rec; rec="$(awk -F= '/^VENDOR_MD5=/{print $2; exit}' "${PREBUILDS_DIR}/.source-manifest" 2>/dev/null)"
        if [ -z "${rec}" ] || [ "${rec}" = "(未取得)" ]; then
            log_warn "  本地无缓存包且无厂商 md5 记录, 无法判定是否最新"
            log_warn "  -> 使用现有 prebuilds/ 继续打包 (确认用: $0 md5)"
            return 0
        fi
        if [ "${rec}" = "${rmd5}" ]; then
            log_ok "  本地底包与厂商 md5 记录一致, 继续打包"
            return 0
        fi
        changed=1; how="记录 md5=${rec}"
    fi

    # --- 3) 厂商包已更新: 下载并替换 ---
    log_warn "  厂商底包已更新 (${how} / 现在 ${rmd5})"
    log_info "  下载最新包并替换本地..."

    if ! download_zip; then
        log_err "  获取最新底包失败"
        if [ "${QPI_ALLOW_STALE:-0}" = "1" ]; then
            log_warn "  QPI_ALLOW_STALE=1, 仍使用旧底包继续打包 (产物可能与厂商最新不一致)"
            return 0
        fi
        log_err "  已中止打包, 避免产出与厂商最新不一致的镜像"
        log_err "  处理: 重跑 $0 fetch (可续传); 或用 QPI_ALLOW_STALE=1 强行用旧底包"
        return 1
    fi
    if ! verify_sha256; then
        log_err "  新包校验未通过, 中止打包"
        log_err "  处理: rm -f ${ZIP_PATH} && $0 fetch"
        return 1
    fi

    # 替换前保留旧的原始 system.img (重新下载代价高, 便于回退)
    local old_src="${PREBUILDS_DIR}/system.img"
    if [ -s "${old_src}" ]; then
        log_info "  备份旧原始镜像 -> $(basename "${old_src}").prev"
        mv -f "${old_src}" "${old_src}.prev" 2>/dev/null || true
    fi

    if ! extract_zip; then
        log_err "  解压最新包失败, 中止打包"
        return 1
    fi
    validate_prebuilds || { log_err "  替换后校验失败, 中止打包"; return 1; }
    write_manifest

    # base_rootfs / sysroot 是从旧镜像派生的, 镜像换了必须重新生成
    local d
    for d in base_rootfs sysroot; do
        if [ -d "${PREBUILDS_DIR}/${d}" ]; then
            log_warn "  底包已更新, 派生的 prebuilds/${d} 需重新生成 (旧的已移到 ${d}.prev)"
            mv -f "${PREBUILDS_DIR}/${d}" "${PREBUILDS_DIR}/${d}.prev" 2>/dev/null || true
        fi
    done

    log_ok "  已替换为厂商最新底包, 继续打包"
    log_info "  注意: base_rootfs/sysroot 已作废, 打包前会按需重建"
    return 0
}

# ---------------------------------------------------------------------------
# 校验 (sha256)
# ---------------------------------------------------------------------------
verify_sha256() {
    [ -f "${ZIP_PATH}" ] || { log_err "压缩包不存在: ${ZIP_PATH}"; return 1; }
    [ -s "${ZIP_PATH}" ] || { log_err "压缩包为空: ${ZIP_PATH} (删除后重跑 fetch)"; return 1; }

    local expect=""
    if [ -s "${SHA_FILE}" ]; then
        # 支持 sha256sum 标准格式 (hash  filename), 允许注释与多余空白
        expect="$(grep -v '^[[:space:]]*#' "${SHA_FILE}" 2>/dev/null \
                  | awk -v n="${ZIP_NAME}" '$2==n || $2=="*"n {print $1; exit}')"
        [ -n "${expect}" ] || expect="$(grep -v '^[[:space:]]*#' "${SHA_FILE}" 2>/dev/null \
                  | awk 'NF>=1 && $1 ~ /^[0-9a-fA-F]{64}$/ {print $1; exit}')"
    fi

    log_info "计算 sha256 (3.2 GiB 需要一两分钟)..."
    local actual; actual="$(sha256sum "${ZIP_PATH}" | awk '{print $1}')"

    if [ -z "${expect}" ]; then
        log_warn "未配置校验值 (${SHA_FILE} 缺失或为空), 跳过完整性校验"
        log_info "  本次 sha256: ${actual}"
        log_info "  固化: ./tools/fetch-prebuilds.sh pin   (把该值写入 ${SHA_FILE}, 提交后同事都能校验)"
        return 0
    fi

    if [ "${actual}" = "${expect}" ]; then
        log_ok "sha256 校验通过: ${actual}"
        return 0
    fi

    # 与本地固化值不符。这时不要直接判死 —— 厂商 md5 才是权威依据:
    #   若厂商 md5 与本文件一致, 说明文件本身是对的(只是本地 sha256 记录过期,
    #   例如之前基于损坏文件 pin 过), 则以厂商为准并刷新本地记录。
    local rmd5 lmd5
    rmd5="$(remote_md5)" || rmd5=""
    if [ -n "${rmd5}" ]; then
        lmd5="$(file_md5 "${ZIP_PATH}")"
        if [ "${lmd5}" = "${rmd5}" ]; then
            log_warn "本地固化 sha256 与当前文件不符, 但厂商 md5 一致 -> 以厂商为准"
            log_warn "  旧记录 sha256: ${expect}"
            log_warn "  实际   sha256: ${actual}"
            log_warn "  厂商   md5:    ${rmd5}"
            cmd_pin >/dev/null 2>&1 || true
            log_ok "已刷新本地校验记录: ${SHA_FILE}"
            return 0
        fi
    fi

    log_err "sha256 校验失败!"
    log_err "  期望: ${expect}"
    log_err "  实际: ${actual}"
    log_err "  压缩包可能损坏或厂商已更新版本。"
    log_err "  重新下载: rm -f ${ZIP_PATH} && ./tools/fetch-prebuilds.sh fetch"
    log_err "  若确认厂商更新, 用 ./tools/fetch-prebuilds.sh pin 固化新值并同步仓库。"
    return 1
}

# ---------------------------------------------------------------------------
# 解压
# ---------------------------------------------------------------------------
extract_zip() {
    [ -s "${ZIP_PATH}" ] || { log_err "压缩包不存在: ${ZIP_PATH}"; return 1; }
    rm -rf "${UNPACK_DIR}"; mkdir -p "${UNPACK_DIR}"

    log_info "解压到临时目录 (可能需要几分钟)..."
    local unzip_log="${DL_DIR}/unzip.log"
    if command -v unzip >/dev/null 2>&1; then
        # 注意: 不要把输出丢进 /dev/null —— 解压失败时 unzip 的报错是唯一的诊断线索
        # (例如 "invalid compressed data to inflate" = 压缩包损坏)
        unzip -o "${ZIP_PATH}" -d "${UNPACK_DIR}" \
            -x '__MACOSX/*' '*/.DS_Store' >"${unzip_log}" 2>&1 || {
            log_err "unzip 解压失败"
            log_err "  unzip 报错 (尾部):"
            grep -iE 'error|warning|invalid|cannot|corrupt' "${unzip_log}" 2>/dev/null \
                | tail -5 | sed 's/^/    /' >&2
            log_err "  完整日志: ${unzip_log}"
            log_err "  若出现 'invalid compressed data' / 'bad CRC', 说明压缩包已损坏:"
            log_err "    rm -f ${ZIP_PATH} && $0 fetch      # 删除后重新下载"
            log_err "  注意: sha256 只能证明文件未变化, 无法证明内容完整; 损坏包的 sha256 同样'通过'"
            return 1; }
        rm -f "${unzip_log}"
    elif command -v python3 >/dev/null 2>&1; then
        log_info "未找到 unzip, 回退 python3 zipfile"
        python3 - "${ZIP_PATH}" "${UNPACK_DIR}" <<'PYEOF' || { log_err "python3 解压失败 (压缩包可能损坏; 删除后重跑 fetch)"; return 1; }
import sys, zipfile, os
z, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(z) as f:
    for m in f.namelist():
        if m.startswith('__MACOSX/') or os.path.basename(m) == '.DS_Store':
            continue
        f.extract(m, out)
PYEOF
    else
        log_err "未找到 unzip / python3, 无法解压"
        log_err "  安装: ./tools/setup-deps.sh install"
        return 1
    fi

    # 定位厂商包里的固件目录 (含 efi.bin/dtb.bin/system.img 的那一层)
    local src_dir=""
    local hit
    hit="$(find "${UNPACK_DIR}" -type f \( -name 'system.img' -o -name 'efi.bin' -o -name 'dtb.bin' \) \
           -printf '%h\n' 2>/dev/null | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')"
    if [ -n "${hit}" ]; then
        src_dir="${hit}"
        log_info "固件目录: ${src_dir#${UNPACK_DIR}/}"
    else
        # 退路: 唯一顶层目录
        local tops; tops="$(find "${UNPACK_DIR}" -mindepth 1 -maxdepth 1 -type d | wc -l)"
        if [ "${tops}" = "1" ]; then
            src_dir="$(find "${UNPACK_DIR}" -mindepth 1 -maxdepth 1 -type d)"
            log_warn "包内未直接找到 system.img/efi.bin/dtb.bin, 使用唯一顶层目录"
        fi
    fi
    if [ -z "${src_dir}" ]; then
        log_err "在压缩包内找不到固件文件 (system.img/efi.bin/dtb.bin)"
        log_err "  包内顶层内容:"; ls -la "${UNPACK_DIR}" | sed 's/^/    /' >&2
        return 1
    fi

    mkdir -p "${PREBUILDS_DIR}" || return 1
    log_info "复制到 ${PREBUILDS_DIR} ..."
    # 用 cp -a 保留目录结构 (分区表 xml / rawprogram / uefi / xbl 等烧录要用)
    if ! cp -a "${src_dir}/." "${PREBUILDS_DIR}/" 2>/dev/null; then
        log_warn "cp -a 失败, 回退 tar 管道复制"
        ( cd "${src_dir}" && tar cf - . ) | ( cd "${PREBUILDS_DIR}" && tar xf - ) || {
            log_err "复制失败"; return 1; }
    fi

    # base_rootfs / sysroot 若包内自带也一并就位 (厂商包可能不含, 缺失由 extract 生成)
    local d
    for d in base_rootfs sysroot; do
        if [ -d "${src_dir}/${d}" ] && [ ! -d "${PREBUILDS_DIR}/${d}" ]; then
            cp -a "${src_dir}/${d}" "${PREBUILDS_DIR}/" 2>/dev/null \
                && log_info "附带复制 ${d}/"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# 解压后校验 (尺寸 + 文件系统魔数)
# ---------------------------------------------------------------------------
validate_prebuilds() {
    local miss; miss="$(missing_files)"
    if [ -n "${miss}" ]; then
        log_err "解压后仍缺少: $(echo "$miss" | tr '\n' ' ')"
        log_err "  厂商包结构可能已变化; 请检查包内目录:"
        find "${UNPACK_DIR}" -maxdepth 3 -type d 2>/dev/null | head -10 | sed 's/^/    /' >&2
        return 1
    fi

    local f sz
    for f in "${REQUIRED_FILES[@]}"; do
        sz="$(stat -c%s "${PREBUILDS_DIR}/${f}")"
        printf '    %-14s %s\n' "$f" "$(human "${sz}")" >&2
    done

    # system.img 应为 BTRFS (超级块魔数 '_BHRfS_M' 位于 0x10040)
    if ! dd if="${PREBUILDS_DIR}/system.img" bs=1 skip=65600 count=8 2>/dev/null | grep -q '_BHRfS_M'; then
        log_warn "system.img 未检出 BTRFS 魔数 (可能与预期格式不同, 请确认厂商包)"
    else
        log_ok "system.img: BTRFS 校验通过"
    fi

    # efi.bin / dtb.bin 应为 FAT (FAT16 / FAT12)
    local fs16 fs12
    fs16="$(dd if="${PREBUILDS_DIR}/efi.bin" bs=1 skip=54 count=8 2>/dev/null | tr -d '\0')"
    fs12="$(dd if="${PREBUILDS_DIR}/dtb.bin" bs=1 skip=54 count=8 2>/dev/null | tr -d '\0')"
    case "${fs16}" in *FAT16*) log_ok "efi.bin: FAT16 校验通过";; *) log_warn "efi.bin 未检出 FAT16 标记 (实际: ${fs16:-空})";; esac
    case "${fs12}" in *FAT12*) log_ok "dtb.bin: FAT12 校验通过";; *) log_warn "dtb.bin 未检出 FAT12 标记 (实际: ${fs12:-空})";; esac

    return 0
}

write_manifest() {
    local mf="${PREBUILDS_DIR}/.source-manifest"
    {
        echo "# 由 tools/fetch-prebuilds.sh 生成: 底包来源记录"
        echo "URL=${URL}"
        echo "ZIP=${ZIP_NAME}"
        echo "SHA256=$(sha256sum "${ZIP_PATH}" 2>/dev/null | awk '{print $1}')"
        echo "MD5=$(file_md5 "${ZIP_PATH}")"
        echo "VENDOR_MD5=$(remote_md5 2>/dev/null || echo '(未取得)')"
        echo "VENDOR_MD5_URL=${MD5_URL:-（未配置）}"
        echo "FETCHED=$(date -Iseconds)"
        echo "HOST=$(hostname)"
    } > "${mf}" 2>/dev/null && log_info "来源记录: ${mf}"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
cmd_fetch() {
    if [ -z "${QPI_FETCH_FORCE:-}" ]; then
        local miss; miss="$(missing_files)"
        if [ -z "${miss}" ]; then
            log_ok "固件底包已齐全, 无需下载 (${PREBUILDS_DIR})"
            missing_optional | sed 's/^/    (可选未生成) /' >&2
            # 顺带告诉你厂商是否已发布新版 (只发一个 HTTP GET, 不算哈希)
            local chg st
            chg="$(vendor_pkg_changed)"; st=$?
            if [ "${st}" = "1" ]; then
                log_warn "厂商底包已更新 (${chg})"
                log_info "  要换成最新包: rm -rf ${PREBUILDS_DIR} ${ZIP_PATH} && QPI_FETCH_FORCE=1 $0 fetch"
            elif [ "${st}" = "0" ]; then
                log_info "厂商包未变化 (md5 与记录一致)"
            fi
            return 0
        fi
        log_info "缺失: $(echo "$miss" | tr '\n' ' ')"
    fi

    download_zip   || return 1
    verify_sha256  || return 1
    extract_zip    || return 1
    validate_prebuilds || return 1
    write_manifest

    log_ok "固件底包就绪: ${PREBUILDS_DIR}"
    log_info "下一步: source build.sh && buildenv   (或 ./tools/build-rootfs.sh extract 生成 base_rootfs/sysroot)"

    if [ "${QPI_KEEP_ZIP:-1}" = "0" ]; then
        log_info "QPI_KEEP_ZIP=0, 删除缓存压缩包 ($(human "$(stat -c%s "${ZIP_PATH}")"))"
        rm -f "${ZIP_PATH}"
    else
        log_info "缓存压缩包保留: ${ZIP_PATH} (拷给同事可省一次下载; QPI_KEEP_ZIP=0 可删除)"
    fi
    rm -rf "${UNPACK_DIR}"
    return 0
}

cmd_clean() {
    local freed=0
    [ -s "${ZIP_PATH}" ] && freed=$((freed + $(stat -c%s "${ZIP_PATH}")))
    [ -s "${PART_PATH}" ] && freed=$((freed + $(stat -c%s "${PART_PATH}")))
    rm -f "${ZIP_PATH}" "${PART_PATH}"
    rm -rf "${UNPACK_DIR}"
    log_ok "已清理下载缓存 (释放 $(human "${freed}")), prebuilds/ 未改动"
}

cmd_hash() {
    [ -s "${ZIP_PATH}" ] || { log_err "压缩包不存在: ${ZIP_PATH}"; return 1; }
    sha256sum "${ZIP_PATH}"
}

# 对照厂商 md5 文件检查本地包是否最新 (不下载, 只判断)
cmd_md5() {
    if [ "${QPI_NO_REMOTE_MD5:-0}" = "1" ]; then
        log_warn "厂商 md5 查询已被 QPI_NO_REMOTE_MD5=1 禁用 (去掉该变量后重试)"
        return 1
    fi
    echo "厂商 md5 文件: ${MD5_URL:-<未配置>}" >&2
    local rmd5; rmd5="$(remote_md5)" || {
        log_err "无法获取厂商 md5 (检查网络或 QPI_MD5_URL)"
        return 1
    }
    log_info "厂商 md5: ${rmd5}"
    if [ -s "${ZIP_PATH}" ]; then
        log_info "计算本地包 md5 (3.2 GiB 需要一两分钟)..."
        local lmd5; lmd5="$(file_md5 "${ZIP_PATH}")"
        if [ "${lmd5}" = "${rmd5}" ]; then
            log_ok "本地包与厂商一致 (无需重新下载)"
            return 0
        fi
        log_err "本地包与厂商不一致 -> 厂商已更新或本地文件损坏"
        log_err "  本地: ${lmd5}"
        log_err "  厂商: ${rmd5}"
        log_err "  重新下载: $0 fetch"
        return 1
    elif [ -s "${PART_PATH}" ]; then
        log_warn "本地只有未完成的 .part ($(human "$(stat -c%s "${PART_PATH}")")), 无法比对 md5"
        log_info "续传并校验: $0 fetch"
        return 2
    else
        log_warn "本地无下载缓存"
        log_info "下载: $0 fetch"
        return 2
    fi
}

cmd_verify() {
    [ -s "${ZIP_PATH}" ] || { log_err "压缩包不存在: ${ZIP_PATH} (先跑 fetch)"; return 1; }

    local ok=1
    # 1) 厂商 md5 (权威: 证明与厂商源一致)
    local rmd5; rmd5="$(remote_md5)" || true
    if [ -n "${rmd5}" ]; then
        log_info "校验厂商 md5 (3.2 GiB 需要一两分钟)..."
        local lmd5; lmd5="$(file_md5 "${ZIP_PATH}")"
        if [ "${lmd5}" = "${rmd5}" ]; then
            log_ok "厂商 md5 一致: ${lmd5}"
        else
            log_err "厂商 md5 不一致!"
            log_err "  本地: ${lmd5}"
            log_err "  厂商: ${rmd5}"
            ok=0
        fi
    else
        log_warn "未取得厂商 md5, 跳过权威比对"
    fi

    # 2) 压缩包内部 CRC (抓"下载过程被写坏")
    if ! command -v unzip >/dev/null 2>&1; then
        log_warn "未找到 unzip, 无法做 CRC 校验 (安装: ./tools/setup-deps.sh install)"
        [ "${ok}" = "1" ] && return 0 || return 1
    fi
    log_info "测试压缩包内部 CRC (3.2 GiB, 需要几分钟)..."
    local out; out="$(unzip -t "${ZIP_PATH}" 2>&1)"
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        log_ok "压缩包 CRC 校验通过 (所有成员正常)"
    else
        log_err "压缩包内部损坏 (CRC 校验失败)"
        echo "$out" | grep -iE 'error|invalid|bad CRC' | tail -8 | sed 's/^/    /' >&2
        log_err "  修复: rm -f ${ZIP_PATH} && $0 fetch   (重新下载)"
        ok=0
    fi

    [ "${ok}" = "1" ] && log_ok "完整性校验全部通过" || log_err "完整性校验未通过"
    [ "${ok}" = "1" ]
}

cmd_pin() {
    [ -s "${ZIP_PATH}" ] || { log_err "压缩包不存在: ${ZIP_PATH} (先跑 fetch)"; return 1; }
    local h; h="$(sha256sum "${ZIP_PATH}" | awk '{print $1}')"
    {
        echo "# H1 固件底包压缩包校验值 (由 tools/fetch-prebuilds.sh pin 生成)"
        echo "# 格式: sha256sum 标准, 供 ./tools/fetch-prebuilds.sh fetch 校验"
        echo "${h}  ${ZIP_NAME}"
    } > "${SHA_FILE}"
    log_ok "已固化: ${SHA_FILE}"
    log_info "  ${h}  ${ZIP_NAME}"
    log_info "请提交该文件, 使同事下载后自动校验 (厂商更新版本时用本命令更新)"
}

usage() {
    sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-fetch}" in
    check)          cmd_check ;;
    fetch|download|"") cmd_fetch ;;
    refresh)        cmd_refresh ;;
    md5)            cmd_md5 ;;
    verify|test)    cmd_verify ;;
    hash)           cmd_hash ;;
    pin)            cmd_pin ;;
    clean)          cmd_clean ;;
    -h|--help|help) usage ;;
    *) echo "用法: $0 {check|fetch|refresh|md5|verify|hash|pin|clean}" >&2; exit 1 ;;
esac
