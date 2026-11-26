"""Phase 6 probe: inspect candidate chain fields (+0x0, +0x7D0..+0x830)
of known threads; find global all-threads list head symbol; locate
queue heads anywhere in kernel data that reference known threads at a
consistent offset."""
import json
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, census_threads, load_syms  # noqa: E402

dump = sys.argv[1]
ctx = Ctx(dump)
threads = census_threads(ctx)
known = set(threads)
print(f'{len(known)} known threads; kernel_task={ctx.task_va:#x}')

syms = load_syms()['syms']
for a, n in syms:
    if 'all_thread' in n or n.endswith('_threads') or 'thread_list' in n:
        print(f'  sym {a:#x} {n}')

sample = sorted(known)[:6]
for t in sample:
    print(f'--- thread {t:#x} ---')
    for o in list(range(0x00, 0x40, 8)) + list(range(0x7D0, 0x838, 8)):
        v = ctx.Qva(t + o)
        note = ''
        if v:
            for oo in (0x0, 0x7F0, 0x7F8, 0x800, 0x810):
                if (v - oo) in known:
                    note = f'  == known_thread + {oo:#x}'
        print(f'  +{o:#05x}: {v if v is None else hex(v)}{note}')

# For every offset o in [0,0x900): count threads whose +o and +o+8 BOTH
# look like chain entries (v-o in known or v == a data VA whose own
# first qword points back consistently). Report offsets where next AND
# prev both resolve into known+o for >=40 threads.
print('\n--- full chain candidates (next&prev both resolve) ---')
raws = {t: ctx.read_va(t, 0xA00) for t in known}
for o in range(0, 0x900, 8):
    hits = 0
    for t, r in raws.items():
        if r is None:
            continue
        vn = struct.unpack_from('<Q', r, o)[0]
        vp = struct.unpack_from('<Q', r, o + 8)[0]
        ok_n = vn and ((vn - o) in known or
                       (0xFFFFFE0020000000 <= vn < 0xFFFFFE0024000000))
        ok_p = vp and ((vp - o) in known or
                       (0xFFFFFE0020000000 <= vp < 0xFFFFFE0024000000))
        if ok_n and ok_p:
            hits += 1
    if hits >= 30:
        print(f'  +{o:#05x}: {hits}/{len(known)}')
