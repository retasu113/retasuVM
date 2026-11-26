"""Phase 6: wide dump around [fa]'s matching dictionary and the sibling
object on its stack; classify every pointer-looking qword."""
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, load_syms, SLIDE  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva
syms = {a: n for a, n in load_syms()['syms']}


def class_of(obj):
    vt = Q(obj)
    if vt is None:
        return ''
    c = syms.get(vt - 0x10 - SLIDE)
    return f' class={c}' if c else ''


def osstr(obj):
    for off in (0x10, 0x18, 0x08, 0x20):
        s = ctx.read_cstr(obj + off, 64)
        if s and len(s) >= 2 and all(32 <= ord(c) < 127 for c in s):
            return s
    return None


for base, label in ((0xFFFFFE2839DC2840, 'matching dict?'),
                    (0xFFFFFE2839DC24A8, 'stack +0x3B40 object')):
    print(f'===== {label} {base:#x} =====')
    for off in range(-0x20, 0x100, 8):
        v = Q(base + off)
        if v is None:
            continue
        extra = class_of(v)
        s = osstr(v) if v > 0xFFFFFE0000000000 else None
        print(f'  {off:+#06x}: {v:#018x}{extra}'
              f'{" str=" + repr(s) if s else ""}')
