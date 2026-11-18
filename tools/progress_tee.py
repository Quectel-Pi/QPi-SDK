#!/usr/bin/env python3
"""
progress_tee.py —— 既是 tee，又在「静默太久」时打进度心跳。

为什么需要：
  内核构建（尤其 modules_install 阶段）会连续好几分钟一行输出都没有。
  日志文件不动时，光看终端无法区分「正在编译」和「真卡住」——
  2026-09-14 就踩过一次假死（docker CLI 在 pty 上自旋，容器内全卡在写 pty），
  当时盯着日志等了 20 分钟才发现。

为什么是 Python 单进程过滤器，而不是后台 bash 看护线程：
  后台子进程要处理 set -e / 缓冲 / 信号 / 被 kill 丢输出 一堆坑，
  实测一个「静默时打印心跳」的 bash 子进程在隔离环境里正常，
  放进真实构建却一行都不出（根因未查明）。
  换成单进程过滤器后没有子 shell、没有信号问题，读写都是显式的，
  行为可预期、可单测。

用法（在管道里当 tee 用）：
    cmd 2>&1 | ./progress_tee.py <日志文件>

环境变量：
    HEARTBEAT_QUIET   静默多少秒后开始报心跳（默认 30）
    HEARTBEAT_EVERY   之后每隔多少秒报一次（默认 15）
    ROOT              仓库根目录，用于统计「近 1 分钟改动的文件数」、
                      统计已收集的内核模块 .ko

行为：
  * stdin 的内容原样写到【日志文件】和【stdout】—— 日志文件保持干净，
    不含心跳（心跳走 stderr，所以 `> 文件 2>&1` 重定向时也能看到心跳）。
  * stdin 静默超过 QUIET 秒 → 往 stderr 打一行【带上下文的进度心跳】，
    尽量把当前进度说清（这是默认就有的，不需要额外开关）：
        ⏳ 已静默 92s（累计 4m08s）
           │ 阶段 1/5 编译内核 (Image + 自带模块)
           │ 已收集 199 个 .ko
           │ 容器内 87 个进程，近 1 分钟改动 7491 个文件
  * stdin 关闭（上游命令结束）→ 正常退出，退出码 0。
"""
import os
import re
import select
import subprocess
import sys
import time

SECTOR = 65536
# 阶段 banner 形如：
#   build_all.sh :  "# 1/5 编译内核 (Image + 自带模块)"
#   one_key      :  "=== 1/5 前置检查 ==="
STAGE_RE = re.compile(r'(\d+)\s*/\s*(\d+)\s+(.+?)\s*(?:===)?$')
ANSI_RE = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')


def env_float(name, default):
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return default


def run(args, timeout):
    """跑个外部命令，失败/超时/找不到都返回空串（心跳不能反过来拖累构建）。"""
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.stdout if p.returncode == 0 else ''
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return ''


def human(sec):
    """把秒数写成 12s / 4m08s / 1h02m。"""
    sec = int(sec)
    if sec < 60:
        return f'{sec}s'
    if sec < 3600:
        return f'{sec // 60}m{sec % 60:02d}s'
    return f'{sec // 3600}h{(sec % 3600) // 60:02d}m'


class Ring:
    """只留最近若干完整行，用来识别阶段 banner。"""

    def __init__(self, keep=80):
        self.buf = ''
        self.lines = []
        self.keep = keep
        self._stage = ''        # 最近一次见到的阶段，持久保留

    def feed(self, text):
        self.buf += text
        while '\n' in self.buf:
            line, self.buf = self.buf.split('\n', 1)
            self.lines.append(line)
            s = ANSI_RE.sub('', line).strip().lstrip('#').strip()
            m = STAGE_RE.search(s)
            if m:
                self._stage = f'{m.group(1)}/{m.group(2)} {m.group(3)}'.strip()
        # 超长行（进度条、clang 命令行）不该无限膨胀
        if len(self.buf) > 8192:
            self.buf = self.buf[-8192:]
        if len(self.lines) > self.keep:
            del self.lines[:len(self.lines) - self.keep]

    def stage(self):
        """返回最近一次出现过的阶段描述，如 '1/5 编译内核 (Image + 自带模块)'。

        刻意【不】只在最近 keep 行里找：进入长阶段（如 vmlinux 链接）后，
        早先的 banner 会被挤出窗口，心跳就丢了阶段信息（实测踩过）。
        """
        return self._stage


def ko_count(root):
    """已收集到多少 .ko（out-modules/kernel 下的产物）—— 内核侧最直观的进度。"""
    n = 0
    for _base, _dirs, files in os.walk(os.path.join(root, 'out-modules', 'kernel')):
        for f in files:
            if f.endswith('.ko'):
                n += 1
    return n


def find_container(root):
    """找到正在跑【本仓库】构建的容器。

    ⚠️ 不能只取 `sudo docker ps -q` 的第一个：存在多个并行构建任务时，取错目标
    会把其他构建活动误判为当前任务，心跳内容全是误导。所以按「挂载了 $ROOT」
    来认。
    """
    ids = run(['sudo', 'docker', 'ps', '-q'], 10).split()
    if not ids:
        return None
    if root:
        for cid in ids:
            mounts = run(['sudo', 'docker', 'inspect', cid, '--format',
                          '{{range .Mounts}}{{.Source}} {{end}}'], 10)
            if root in mounts.split():
                return cid
    return ids[0]


def docker_activity(root):
    """容器内「进程数 + 最忙进程 + 近 1 分钟文件改动数」。

    为什么必须有「最忙进程」：内核 `LTO vmlinux.o` / `vmlinux` 链接是**单线程
    长任务**，期间既不输出、也不改文件（实测 5 分钟以上）。只看「文件改动 0」
    会误判成卡死 —— 实测踩过。带上 CPU 占用就能一眼分清：

        最忙 ld.lld 99% CPU  -> 在啃硬骨头，正常
        最忙 0% CPU          -> 真卡住了（会额外提示「疑似卡住」）
    """
    changed = None
    if root and os.path.isdir(root):
        out = run(['find', root + '/out-kernel', root + '/out-modules', root + '/stage',
                   '-newermt', '-1 minute', '-type', 'f'], 15)
        if out:
            changed = len(out.splitlines())
        elif os.path.isdir(root + '/out-kernel'):
            changed = 0

    cid = find_container(root)
    if not cid:
        s = '无 docker 容器（可能已结束或异常）'
    else:
        top = run(['sudo', 'docker', 'top', cid], 10)
        rows = top.splitlines()[1:] if top else []
        s = f'容器内 {len(rows)} 个进程'
        best = None
        for ln in rows:
            # docker top 的列是右对齐+空格填充，CMD 自身还含空格，
            # 所以只切前 7 列、剩下的整段当 CMD（实测切错会得到 "-EL" 这种参数）
            f = ln.split(None, 7)       # UID PID PPID C STIME TTY TIME | CMD...
            if len(f) < 8:
                continue
            try:
                cpu = float(f[3])
            except ValueError:
                continue
            if best is None or cpu > best[0]:
                cmd = f[7].split()
                best = (cpu, f[6], os.path.basename(cmd[0]) if cmd else '?')
        if best:
            cpu, tacc, cmd = best
            s += f'，最忙 {cmd} {cpu:.0f}% CPU（累计 {tacc}）'
            if cpu <= 0 and changed == 0:
                s += '  ← 既无 CPU 也无文件改动，疑似卡住'
    if changed is not None:
        s += f'；近 1 分钟改动 {changed} 个文件'
    return s


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        raise SystemExit(1)
    logpath = sys.argv[1]
    quiet = env_float('HEARTBEAT_QUIET', 30)
    every = env_float('HEARTBEAT_EVERY', 15)
    root = os.environ.get('ROOT', '')

    try:
        # 日志目录可能是 .tmp/（在 .gitignore 里，`git clean -fdx` 会删掉）。
        # 自己建一下，免得因为「目录不存在」这种无关原因让整个构建失败。
        d = os.path.dirname(os.path.abspath(logpath))
        if d:
            os.makedirs(d, exist_ok=True)
        out = open(logpath, 'wb', buffering=0)
    except OSError as e:
        print(f'progress_tee: 打不开日志 {logpath}: {e}', file=sys.stderr)
        raise SystemExit(1)

    fin = sys.stdin.fileno()
    fout = sys.stdout.buffer
    ring = Ring()
    size = 0
    t0 = time.time()
    last = t0                   # 最后一次收到数据的时间
    next_hb = last + quiet

    def write(data):
        nonlocal size
        out.write(data)
        fout.write(data)
        fout.flush()
        size += len(data)
        ring.feed(data.decode('utf-8', 'replace'))

    while True:
        try:
            ready, _, _ = select.select([fin], [], [], 1.0)
        except InterruptedError:
            continue
        if ready:
            try:
                data = os.read(fin, SECTOR)
            except OSError:
                break
            if not data:
                break
            write(data)
            last = time.time()
            next_hb = last + quiet
            continue

        # 没有新数据：到点了就打心跳（走 stderr，不污染日志文件）
        now = time.time()
        if now >= next_hb:
            parts = [f'⏳ 已静默 {int(now - last)}s'
                     f'（累计 {human(now - t0)}，日志 {size} 字节）']
            st = ring.stage()
            if st:
                parts.append(f'阶段 {st}')
            if root:
                n = ko_count(root)
                if n:
                    parts.append(f'已收集 {n} 个 .ko')
            parts.append(docker_activity(root))
            for i, p in enumerate(parts):
                pref = '  ' if i == 0 else '     │ '
                print(f'{pref}{p}', file=sys.stderr, flush=True)
            next_hb = now + every

    out.close()


if __name__ == '__main__':
    main()
