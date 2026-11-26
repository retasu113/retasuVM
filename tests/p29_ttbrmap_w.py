#!/usr/bin/env python3
"""Phase 29: generalize p28_ttbrmap — given the p29 fpend dump and a list
of TTBR0 roots (from wqtrace_cycle1.txt INSTALL lines), identify each
root's process by scanning the user stack VA range for exec-frame
strings, and check whether specific stack VAs are mapped.
Usage: p29_ttbrmap.py <dump> <root_hex> [<root_hex> ...] [--va <va_hex> ...]
Run on the PC.
"""
import struct
import sys

DRAM_BASE = 0x70000000
PAGE = 0x4000

args = sys.argv[1:]
dump_path = args[0]
roots = []
vas = []
mode = 'root'
for a in args[1:]:
    if a == '--va':
        mode = 'va'
        continue
    (roots if mode == 'root' else vas).append(int(a, 0))

data = open(dump_path, 'rb').read()
N = len(data)
print(f"dump {N} B, roots={[hex(r) for r in roots]}, vas={[hex(v) for v in vas]}")


def walk(root_pa, va, root_level=1):
    table_pa = root_pa
    for level in range(root_level, 4):
        shift = 14 + (3 - level) * 11
        idx = (va >> shift) & 0x7FF
        off = table_pa - DRAM_BASE + idx * 8
        if off < 0 or off + 8 > N:
            return None
        entry = struct.unpack_from('<Q', data, off)[0]
        if entry & 0x1 == 0:
            return None
        typ = entry & 0x3
        if level == 3:
            if typ != 0x3:
                return None
            return (entry & 0x0000FFFFFFFFC000) + (va & 0x3FFF)
        if typ == 0x3:
            table_pa = entry & 0x0000FFFFFFFFC000
        elif typ == 0x1:
            return (entry & 0x0000FFFFC0000000 if level == 1 else entry & 0x0000FFFFFFC000) + (va & ((1 << shift) - 1))
        else:
            return None
    return None


for root in roots:
    for va in vas:
        pa = walk(root, va)
        print(f"  root {root:#x} VA {va:#x} -> {'PA %#x' % pa if pa else 'UNMAPPED'}")

NEEDLES = [b'executable_path=', b'/sbin/launchd', b'/sbin/fsck', b'main_stack=']
for root in roots:
    print(f"== scan root {root:#x} VA [0x16c000000, 0x170000000) ==")
    hits = {}
    va = 0x16C000000
    while va < 0x170000000:
        pa = walk(root, va)
        if pa is not None:
            off = pa - DRAM_BASE
            page = data[off:off + PAGE]
            for nd in NEEDLES:
                i = page.find(nd)
                if i != -1:
                    ctx = page[max(0, i - 16):i + 96]
                    hits.setdefault(nd, []).append((va + i, ctx))
        va += PAGE
    for nd, lst in hits.items():
        print(f"  {nd}: {len(lst)} hits")
        for va_h, ctx in lst[:3]:
            print(f"    @{va_h:#x}: {ctx!r}")
    if not hits:
        print("  (no needle hits in this VA range)")
