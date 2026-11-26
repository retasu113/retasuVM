"""Phase 6: raw hex study of the shared waitq W and the shared event E
regions in the terminal dump. Usage: python3 p6_raw.py <dump>"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, thread_info  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva

W = 0xFFFFFE1DF00CD2A0
E = 0xFFFFFE3511F3B6D8

print(f'===== waitq W = {W:#x} : -0x40 .. +0xA0 =====')
for off in range(-0x40, 0xA0, 8):
    v = Q(W + off)
    print(f'  W{off:+#06x}: {v if v is None else hex(v)}')

print(f'\n===== event E = {E:#x} : page dump (16B rows, qword pairs) =====')
page = E & ~0x3FFF
raw = ctx.read_va(page, 0x4000)
# summarise runs: print only rows whose pair != the idle pattern
IDLE = (0x0000010F22000000, 0)
n_idle = 0
for off in range(0, 0x4000, 16):
    a, b = struct.unpack_from('<QQ', raw, off)
    if (a, b) == IDLE:
        n_idle += 1
        continue
    if n_idle:
        print(f'  ... {n_idle} idle-pattern rows ...')
        n_idle = 0
    mark = ' <== E' if page + off == E - 8 else ''
    print(f'  pg+{off:#06x}: {a:#018x} {b:#018x}{mark}')
if n_idle:
    print(f'  ... {n_idle} idle-pattern rows ...')

print('\n===== strings in E page =====')
cur = b''
start = 0
for i, c in enumerate(raw):
    if 32 <= c < 127:
        if not cur:
            start = i
        cur += bytes([c])
    else:
        if len(cur) >= 4:
            print(f'  pg+{start:#06x}: {cur.decode()!r}')
        cur = b''

print('\n===== waiters link fields (+0x00..+0x38) =====')
for name, t in [('7c', 0xFFFFFE184A0D3010), ('f9', 0xFFFFFE184A48B808),
                ('102', 0xFFFFFE184A47C838), ('fa', 0xFFFFFE184A48F010)]:
    vals = [Q(t + o) for o in range(0, 0x40, 8)]
    print(f'  [{name}] {t:#x}: ' +
          ' '.join(f'+{o:#x}={v if v is None else hex(v)}'
                   for o, v in zip(range(0, 0x40, 8), vals)))
