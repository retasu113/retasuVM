"""Phase 6: AppleParavirtGPU instance fields; follow any tag-0x8E
(device-shared) pointers to ring/state pages and dump their heads.
Usage: python3 p6_gfx4.py <dump>
"""
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, load_syms, SLIDE  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva
syms = {a: n for a, n in load_syms()['syms']}


def class_of(obj):
    vt = Q(obj)
    if vt is None:
        return '?'
    return syms.get(vt - 0x10 - SLIDE, '')


GPU = 0xFFFFFE1CEDE73F00
print(f'===== AppleParavirtGPU {GPU:#x} fields =====')
ptrs8e = []
for off in range(0, 0x300, 8):
    v = Q(GPU + off)
    if v and v > 0xFFFFFE0000000000:
        print(f'  +{off:#05x}: {v:#x} {class_of(v)}')
        if (v >> 24) == 0xFFFFFE8EBA or (v & 0xFFFFFFFF00000000) == 0xFFFFFE8E00000000:
            ptrs8e.append((off, v))
for off, v in ptrs8e:
    print(f'\n--- tag-0x8E target of GPU+{off:#x}: {v:#x} ---')
    raw = ctx.read_va(v, 0x100)
    if raw:
        for i in range(0, 0x100, 8):
            w = int.from_bytes(raw[i:i + 8], 'little')
            if w:
                print(f'   +{i:#05x}: {w:#x}')
