"""Phase 6: raw hex of OSSymbol objects to find the string offset, then
decode [fa]'s matching dictionary for real."""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, load_syms, SLIDE  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva
syms = {a: n for a, n in load_syms()['syms']}

for obj, label in ((0xFFFFFE1DF00F0A20, 'notifier type'),
                   (0xFFFFFE1DF00F2FC0, 'some key')):
    raw = ctx.read_va(obj, 0x60)
    print(f'== {label} {obj:#x} ==')
    for off in range(0, 0x60, 16):
        chunk = raw[off:off + 16]
        hexs = ' '.join(f'{b:02x}' for b in chunk)
        asc = ''.join(chr(b) if 32 <= b < 127 else '.' for b in chunk)
        print(f'  +{off:02x}: {hexs}  {asc}')
