#!/usr/bin/env python3
"""
从 fw 固件包里还原出 system 分区镜像（raw 8GiB，或进一步转 sparse）。

━━ 为什么能还原（已对照源码确认）━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

fw 包里的 system_N.img 是 **裸数据块，不是 sparse 镜像**。
它们由 Qualcomm 的 checksparse.py 从 deploy 的 system.img（sparse ext4）
切出来，算法是（checksparse.py:genfile()）：

    chunk_number = 1
    for chunk in sparse_image:
        if RAW (0xCAC1):
            if 输出文件未打开:
                新建 "<name>_<chunk_number>.img"          # 新文件
                results.append({filename, nsec, start_sector})
            else:
                results[-1]['num_partition_sectors'] += n  # 连续 RAW 合并进同一文件
            current_start_sector += n                      # 位置推进
        elif DONT_CARE (0xCAC3):
            if 文件已打开:
                if chunk_sz <= 2 且 chunk_hdr_sz <= 4096:  # 小空洞(≤8KB)
                    results[-1]['num_partition_sectors'] += n
                    zeroout_raw_chunk()                    # 就地补零，合并进文件
                else:
                    输出文件.close()                        # 大空洞：关文件
            current_start_sector += n                      # 位置【照样推进】⇒ 留出间隙

要点：
  * 连续 RAW 会**合并**进同一文件 ⇒ 文件很大（实测最大 266 MiB）
  * **大空洞（>8KB）会关文件** ⇒ 下一个 RAW 起新文件，扇区空间留下**间隙**
  * 末尾若还有大空洞，就是分区尾部的零区
  * 小空洞（≤8KB）被**就地补零**，所以文件字节数略多于纯 RAW 数据
    （实测差 12288 字节 = 3 个 ≤2 块的 dont-care）

所以【逆向】就是：建一个「分区大小」的全零文件，把每个分片按
`(start_sector - 分区起始 LBA) * 512` 写进去，间隙与尾部自然保持为零。

已实测验证（本板 fw）：
    还原出的 raw  ==  simg2img(dt 的 prebuilds/system.<平台>.img)  【逐字节完全相同】

━━ 用法 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  fw_system_img.py <fw目录> <system_a|system_b> <输出raw> [--sparse <输出sparse>]

例：
  ./fw_system_img.py ./fw/QSM200U..._V01 system_a /mnt/hdd8000g/system.raw
  ./fw_system_img.py ./fw/QSM200U..._V01 system_a out-system/system.raw \
                     --sparse out-system/system.img
"""
import os
import re
import struct
import subprocess
import sys

SECTOR = 512


def parse_gpt(gpt_bin, label):
    """从 fw 的 gpt_main0.bin（LBA 0..33）取分区 (first_lba, last_lba)。
    GPT 头在 LBA1（LBA0 是保护性 MBR）。"""
    if not os.path.isfile(gpt_bin):
        return None
    with open(gpt_bin, 'rb') as f:
        d = f.read()
    if len(d) < 1024 or d[512:520] != b'EFI PART':
        return None
    ent_lba, num, esz = struct.unpack_from('<QII', d, 512 + 72)
    off = SECTOR * ent_lba
    for i in range(num):
        e = d[off + i * esz:off + (i + 1) * esz]
        if len(e) < esz or e[:16] == b'\x00' * 16:
            continue
        name = e[56:128].decode('utf-16-le').rstrip('\x00')
        if name == label:
            first, last = struct.unpack('<QQ', e[32:48])
            return first, last
    return None


def parse_partition_size_kb(xml, label):
    """从 partition.xml 取 size_in_kb（GPT 不可用时的备用来源）。"""
    if not os.path.isfile(xml):
        return None
    x = open(xml, encoding='utf-8', errors='replace').read()
    for m in re.finditer(r'<partition\b[^>]*?/?>', x):
        p = m.group(0)
        lb = re.search(r'label="([^"]*)"', p)
        if not lb or lb.group(1) != label:
            continue
        sz = re.search(r'size_in_kb="(\d+)"', p)
        if sz:
            return int(sz.group(1))
    return None


def parse_rawprogram(xml, label):
    """返回 [(start_sector, num_sectors, filename), ...]，按 start_sector 排序。"""
    x = open(xml, encoding='utf-8', errors='replace').read()
    items = []
    for m in re.finditer(r'<program\b[^>]*?/?>', x):
        p = m.group(0)
        lb = re.search(r'label="([^"]*)"', p)
        if not lb or lb.group(1) != label:
            continue
        fn = re.search(r'filename="([^"]*)"', p).group(1)
        st = int(re.search(r'start_sector="(\d+)"', p).group(1))
        ns = int(re.search(r'num_partition_sectors="(\d+)"', p).group(1))
        items.append((st, ns, fn))
    return sorted(items)


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        raise SystemExit(1)

    fw = sys.argv[1].rstrip('/')
    label = sys.argv[2]
    out_raw = sys.argv[3]
    out_sparse = None
    if '--sparse' in sys.argv:
        out_sparse = sys.argv[sys.argv.index('--sparse') + 1]

    xml = os.path.join(fw, 'rawprogram_unsparse0.xml')
    if not os.path.isfile(xml):
        raise SystemExit(f'找不到 {xml}')

    items = parse_rawprogram(xml, label)
    if not items:
        raise SystemExit(f'rawprogram 里没有 label={label} 的条目')

    # ---- 分区起始 LBA 与扇区数 ----
    # 优先用 fw 自带的 gpt_main0.bin（与设备上的分区表完全一致）；
    # 退化到 partition.xml 的 size_in_kb + 分片最小 start_sector。
    gpt = parse_gpt(os.path.join(fw, 'gpt_main0.bin'), label)
    if gpt:
        part_start, part_last = gpt
        nsec = part_last - part_start + 1
        src = 'gpt_main0.bin'
    else:
        kb = parse_partition_size_kb(os.path.join(fw, 'partition.xml'), label)
        if kb is None:
            raise SystemExit('既解析不出 gpt_main0.bin，也找不到 partition.xml 的 '
                             'size_in_kb；fw 包不完整？')
        part_start = min(st for st, _, _ in items)
        nsec = kb * 1024 // SECTOR
        src = 'partition.xml（起始位置按分片最小 start_sector 推断）'

    total = nsec * SECTOR
    print(f'  label          = {label}')
    print(f'  参数来源       = {src}')
    print(f'  分区起始 LBA   = {part_start}')
    print(f'  分区扇区数     = {nsec}  ({total} 字节 = {total / 1024**3:.4f} GiB)')
    print(f'  分片数         = {len(items)}')

    fst = items[0][0]
    if fst != part_start:
        print(f'  ⚠️  首个分片 start_sector={fst} != 分区起点 {part_start} '
              f'（差 {fst - part_start} 扇区）—— 该前缀是 zero 区')

    for st, ns, fn in items:
        if st < part_start or st + ns > part_start + nsec:
            raise SystemExit(f'{fn} 超出分区范围: [{st}, {st + ns}) 不在 '
                             f'[{part_start}, {part_start + nsec})')

    # ---- 还原 ----
    print(f'  输出 raw       = {out_raw}')
    with open(out_raw, 'wb') as f:
        f.truncate(total)

    written = 0
    with open(out_raw, 'r+b') as f:
        for st, ns, fn in items:
            src_f = os.path.join(fw, fn)
            if not os.path.isfile(src_f):
                raise SystemExit(f'缺少分片: {src_f}')
            sz = os.path.getsize(src_f)
            cap = ns * SECTOR
            if sz != cap:
                raise SystemExit(f'{fn}: 实际 {sz} 字节 != 声明 {ns} 扇区 ({cap} 字节)')
            f.seek((st - part_start) * SECTOR)
            with open(src_f, 'rb') as g:
                while True:
                    b = g.read(1 << 20)
                    if not b:
                        break
                    f.write(b)
            written += sz

    print(f'  已写入数据     = {written} 字节 ({written / 1024**3:.4f} GiB)')
    print(f'  零区合计       = {total - written} 字节 '
          f'({(total - written) / 1024**3:.4f} GiB)   间隙 + 尾部（来自大空洞）')

    if out_sparse:
        print(f'  -> sparse      = {out_sparse}')
        r = subprocess.run(['img2simg', out_raw, out_sparse, '4096'],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit(f'img2simg 失败: {r.stderr}')
        print(f'     sparse 大小  = {os.path.getsize(out_sparse)} 字节')


if __name__ == '__main__':
    main()
