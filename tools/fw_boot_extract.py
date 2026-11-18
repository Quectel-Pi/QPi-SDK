#!/usr/bin/env python3
"""
从 Android boot.img 里抽出 kernel / ramdisk / dtb。

用途：dt 的构建基线（`prebuilds/qti-ramdisk-*.cpio.lz4`、`prebuilds/Image.<平台>`）本来
来自 Yocto 出包目录，其实 fw 包里的 `boot.img` 就装着同一份东西，所以可以不随
交付包预置，构建时从 fw 现取。

━━ Android boot image v2 布局 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    0        'ANDROID!'                                   magic
    8        kernel_size  kernel_addr                     (8 个 u32)
    16       ramdisk_size ramdisk_addr
    24       second_size  second_addr
    32       tags_addr    page_size
    40       os_version, name[16], cmdline[512], id[32], extra_cmdline[1024]
    1632     <补齐到 page_size>
    align(1632,pg)              kernel      (kernel_size 字节)
    + align(kernel_size,pg)     ramdisk     (ramdisk_size 字节)
    + align(ramdisk_size,pg)    second      (second_size 字节)
    + align(second_size,pg)     dtb         (v2 才有)

注意 v0/v1 没有 dtb 段，page_size 若非法（不在 512..65536）按 4096 处理。

━━ 用法 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  fw_boot_extract.py <boot.img> --info
  fw_boot_extract.py <boot.img> --kernel <输出> [--ramdisk <输出>] [--dtb <输出>]
  fw_boot_extract.py <boot.img> --cmdline          # 打印内核命令行
"""
import os
import struct
import sys

HDR_V2 = 1632


def align(x, p):
    return (x + p - 1) // p * p


def parse(path):
    with open(path, 'rb') as f:
        d = f.read(HDR_V2)
    if len(d) < 48 or d[:8] != b'ANDROID!':
        raise SystemExit(f'{path}: 不是 Android boot image（magic 不是 ANDROID!）')
    (ks, ka, rs, ra, ss, sa, ta, pg) = struct.unpack_from('<8I', d, 8)
    if not (512 <= pg <= 65536) or pg & (pg - 1):
        pg = 4096
    cmdline = d[64:64 + 512].split(b'\x00')[0].decode('utf-8', 'replace')
    extra = d[608:608 + 1024].split(b'\x00')[0].decode('utf-8', 'replace')
    return dict(ks=ks, rs=rs, ss=ss, pg=pg,
                cmdline=(cmdline + ' ' + extra).strip(),
                koff=align(HDR_V2, pg),
                roff=align(HDR_V2, pg) + align(ks, pg),
                soff=align(HDR_V2, pg) + align(ks, pg) + align(rs, pg))


def extract(src, off, size, dst):
    if size == 0:
        return 0
    with open(src, 'rb') as f:
        f.seek(off)
        data = f.read(size)
    if len(data) != size:
        raise SystemExit(f'{src}: 在偏移 {off} 只读到 {len(data)}/{size} 字节（文件被截断？）')
    with open(dst, 'wb') as g:
        g.write(data)
    return size


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        raise SystemExit(1)
    src = sys.argv[1]
    if not os.path.isfile(src):
        raise SystemExit(f'找不到 {src}')

    h = parse(src)
    size = os.path.getsize(src)

    if '--info' in sys.argv:
        print(f'  文件           = {src}  ({size} 字节)')
        print(f'  page_size      = {h["pg"]}')
        print(f'  kernel_size    = {h["ks"]}  ({h["ks"] / 1048576:.2f} MiB)  偏移 {h["koff"]}')
        print(f'  ramdisk_size   = {h["rs"]}  ({h["rs"] / 1048576:.2f} MiB)  偏移 {h["roff"]}')
        print(f'  second_size    = {h["ss"]}  偏移 {h["soff"]}')
        dtb_off = h['soff'] + align(h['ss'], h['pg'])
        print(f'  dtb 偏移       = {dtb_off}  (剩余 {size - dtb_off} 字节)')
        print(f'  cmdline        = {h["cmdline"]}')
        if '--cmdline' not in sys.argv:
            return

    if '--cmdline' in sys.argv:
        print(h['cmdline'])
        if len(sys.argv) <= 3:
            return

    def outflag(name):
        return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else None

    did = False
    for flag, off, sz, label in (
        ('--kernel', h['koff'], h['ks'], '内核'),
        ('--ramdisk', h['roff'], h['rs'], 'ramdisk'),
        ('--dtb', h['soff'] + align(h['ss'], h['pg']), size - h['soff'] - align(h['ss'], h['pg']), 'dtb'),
    ):
        dst = outflag(flag)
        if not dst:
            continue
        n = extract(src, off, sz, dst)
        print(f'  {label:<8} -> {dst}  ({n} 字节, 偏移 {off})')
        did = True

    if not did and '--info' not in sys.argv:
        print(__doc__)
        raise SystemExit(1)


if __name__ == '__main__':
    main()
