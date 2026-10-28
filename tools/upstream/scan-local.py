#!/usr/bin/env python3
"""扫描基准文件及 SDK 新增源码，生成“本地定制”快照。

用法: scan-local.py <上游仓库> <子目录> <基准提交> <SDK内核目录> <输出目录>

- 内容不同的文件 → 复制到输出目录（保持相对路径）
- 符号链接按链接目标比较，权限位按可执行位比较
- 已跟踪文件的删除、类型/权限变化或链接定制必须人工处理，扫描失败不更新快照
"""
import hashlib
import os
import subprocess
import sys
import shutil
import stat
import tempfile

src, subdir, base, kernel, outdir = sys.argv[1:6]
prefix = subdir.rstrip("/") + "/"


def git(*args, **kw):
    return subprocess.run(["git", "-C", src] + list(args), capture_output=True, check=True, **kw)


raw = git("ls-tree", "-r", "-z", base, "--", subdir).stdout.decode()
if not raw:
    raise RuntimeError(f"上游提交中没有 {subdir} 源码树")
entries = {}
for rec in raw.split("\0"):
    if not rec:
        continue
    meta, path = rec.split("\t", 1)
    mode, _typ, sha = meta.split()
    entries[path[len(prefix):]] = (mode, sha)

# 基准之外的 SDK 新文件同样需要保护；忽略规则过滤构建产物。
sdk = os.path.dirname(os.path.abspath(kernel))
kernel_prefix = os.path.basename(os.path.abspath(kernel)) + "/"
def sdk_files(*args):
    result = subprocess.run(["git", "-C", sdk, "ls-files", "-z", *args, "--", kernel_prefix],
                            capture_output=True, check=True)
    return {p.decode()[len(kernel_prefix):] for p in result.stdout.split(b"\0") if p}

tracked = sdk_files("--cached")
extra = (tracked | sdk_files("--others", "--exclude-standard")) - entries.keys()
if extra:
    paths = b"".join((kernel_prefix + p).encode() + b"\0" for p in sorted(extra))
    ignored = subprocess.run(["git", "-C", sdk, "check-ignore", "--no-index", "-z", "--stdin"],
                             input=paths, capture_output=True)
    if ignored.returncode not in (0, 1):
        raise RuntimeError(ignored.stderr.decode())
    extra -= {p.decode()[len(kernel_prefix):] for p in ignored.stdout.split(b"\0") if p}
for rel in extra:
    entries[rel] = (None, None)

changed, missing, unsupported = [], [], []
for rel, (mode, sha) in sorted(entries.items()):
    full = os.path.join(kernel, rel)
    if not os.path.lexists(full):
        if rel in tracked and mode is not None:
            unsupported.append(f"本地删除: {rel}（请先恢复或明确处理删除）")
        if mode is not None:
            missing.append(rel)
        continue
    is_link = os.path.islink(full)
    if mode is not None and is_link != (mode == "120000"):
        unsupported.append(f"类型不同: {rel}")
        continue
    if is_link:
        data = os.readlink(full).encode()
    else:
        with open(full, "rb") as f:
            data = f.read()
    h = hashlib.sha1(b"blob %d\0" % len(data))
    h.update(data)
    if h.hexdigest() != sha:
        if is_link:
            unsupported.append(f"符号链接新增/修改: {rel}（不支持文本三方合并）")
        else:
            changed.append((rel, is_link))
    if not is_link and mode is not None:
        exe = bool(os.stat(full).st_mode & stat.S_IXUSR)
        if exe != (mode == "100755"):
            unsupported.append(f"可执行权限变化: {rel}")

if unsupported:
    for problem in unsupported:
        print(f"[ERROR] {problem}", file=sys.stderr)
    sys.exit(1)

# 扫描成功后才替换旧快照，扫描异常不会破坏已有定制。
outdir = os.path.abspath(outdir)
os.makedirs(os.path.dirname(outdir), exist_ok=True)
stage = tempfile.mkdtemp(prefix=".snapshot-", dir=os.path.dirname(outdir))
for rel, is_link in changed:
    dst = os.path.join(stage, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    s = os.path.join(kernel, rel)
    if is_link:
        os.symlink(os.readlink(s), dst)
    else:
        shutil.copy2(s, dst)
if os.path.isdir(outdir):
    shutil.rmtree(outdir)
os.replace(stage, outdir)

print(f"本地定制文件: {len(changed)}")
for rel, _ in changed:
    print(f"  M {rel}")
if missing:
    print(f"历史提取时遗漏的上游文件: {len(missing)}（同步将补齐）")
    for rel in missing:
        print(f"  D {rel}")
