"""Phase 6: follow the OSDictionary entries pointer (+0x20) and decode
key/value pairs; also dump the 'type' symbol of [fa]'s notifier."""
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
    return syms.get(vt - 0x10 - SLIDE, f'vt@{vt - 0x10 - SLIDE:#x}')


def osstr(obj):
    for off in (0x10, 0x18, 0x08, 0x20, 0x14):
        s = ctx.read_cstr(obj + off, 80)
        if s and len(s) >= 2 and all(32 <= ord(c) < 127 for c in s):
            return s
    return None


print('== notifier type symbol (+0x20 = 0xFFFFFE1DF00F0A20) ==')
t = 0xFFFFFE1DF00F0A20
print(f'  class={class_of(t)} str={osstr(t)!r}')

print('== entries array at dict+0x20 = 0xFFFFFE184A3A2EA0 ==')
E = 0xFFFFFE184A3A2EA0
for i in range(6):
    k = Q(E + i * 16)
    v = Q(E + i * 16 + 8)
    print(f'  [{i}] key {k:#x} {class_of(k) if k else ""} {osstr(k)!r}'
          f'  val {v:#x} {class_of(v) if v else ""} {osstr(v)!r}')
