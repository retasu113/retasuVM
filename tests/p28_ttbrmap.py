#!/usr/bin/env python3
"""Phase 28: identify the processes owning two TTBR0 roots in the p28
fpend dump by walking each root's user VA space and searching the mapped
pages for exec-frame strings (executable path / argv).
  root A (P27TRACE installs) = 0x80848000
  root B (SFV spinner)       = 0x85c08000
Also verify: root B maps the spinner's stack VA 0x16f6aaa38; root A maps
the installed stacks 0x16f5b7000 / 0x16f75b000.
Run on the PC. Usage: p28_ttbrmap.py <dump>
"""
import struct
import sys

DRAM_BASE = 0x70000000
PAGE = 0x4000

data = open(sys.argv[1], 'rb').read()
N = len(data)
print(f"dump {N} B")


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
            # block entry
            return (entry & 0x0000FFFFC0000000 if level == 1 else entry & 0x0000FFFFFFC000) + (va & ((1 << shift) - 1))
        else:
            return None
    return None


def check(root, va):
    pa = walk(root, va)
    print(f"  root {root:#x} VA {va:#x} -> {'PA %#x' % pa if pa else 'UNMAPPED'}")
    return pa


ROOTS = {'A_installs': 0x80848000, 'B_spinner': 0x85C08000}
print("== specific VAs ==")
check(ROOTS['B_spinner'], 0x16F6AAA38)
check(ROOTS['A_installs'], 0x16F6AAA38)
check(ROOTS['A_installs'], 0x16F5B7000 - 0x10)
check(ROOTS['A_installs'], 0x16F75B000 - 0x10)
check(ROOTS['B_spinner'], 0x16F5B7000 - 0x10)

NEEDLES = [b'/sbin/launchd', b'main_stack=', b'fsck', b'executable_path=']
for name, root in ROOTS.items():
    print(f"== scan {name} root {root:#x} VA [0x16e000000, 0x170000000) ==")
    hits = {}
    va = 0x16E000000
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
