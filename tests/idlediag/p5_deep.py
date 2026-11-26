"""Phase 5 deep dive on one dump:
- supplementary config-thread census via name-pool pointers (catches
  threads the record census misses),
- wait_event grouping across ALL validated threads,
- for every IOConfigThread and every thread on the top shared config
  event: FP-walk + full stack scan symbolication,
- shared-event forensics: object hexdump, dump-wide holder scan,
  common-pointer-field scan across waiters.

Usage: python3 p5_deep.py <dump> [census.json]
"""
import collections
import json
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, census_threads, thread_info, make_sym, DRAM  # noqa: E402

dump = sys.argv[1]
ctx = Ctx(dump)
sym = make_sym()
print(f'TTBR root = {ctx.root:#x} task = {ctx.task_va:#x}')

threads = census_threads(ctx)
infos = {}
for tva in threads:
    ti = thread_info(ctx, tva)
    if ti:
        infos[tva] = ti
print(f'record census: {len(infos)} threads')

# --- supplementary: threads named via +0x7D8 pointing at IOConfigThread_'
# strings. Single regex pass over mapped non-block segments only. ---
import re as _re
data = open(dump, 'rb').read()
name_vas = set()
i = data.find(b"IOConfigThread_'")
while i != -1:
    pa = i + DRAM
    if not (0x76A20000 <= pa < 0x76A80000):  # exclude msgbuf ring copies
        for va in ctx.va_cands(pa):
            name_vas.add(va)
    i = data.find(b"IOConfigThread_'", i + 1)
print(f'{len(name_vas)} config name-string VAs (all aliases)', flush=True)
# the +0x7D8 name pointers use VA tag 0x2F (kalloc string pool,
# e.g. 0xFFFFFE2FEA001300) -- keep only those aliases
name_vas = {v for v in name_vas if (v >> 40) & 0xFF == 0x2F}
print(f'{len(name_vas)} config name-string VAs (tag 0x2F)', flush=True)
extra = 0
if name_vas:
    pat = _re.compile(b'|'.join(_re.escape(struct.pack('<Q', v))
                                 for v in name_vas))
    for sva, spa, ln in ctx.segs:
        if ln > (1 << 28):
            continue
        chunk = data[spa - DRAM: spa - DRAM + ln]
        for m in pat.finditer(chunk):
            hva = sva + m.start()
            tva = hva - 0x7D8
            if tva in infos:
                continue
            bp = ctx.Qva(tva + 0x3D8)
            if bp is not None and ctx.Qva(bp) == tva:
                ti = thread_info(ctx, tva)
                if ti and ti['name'] and 'IOConfigThread' in ti['name']:
                    infos[tva] = ti
                    extra += 1
print(f'supplementary census added {extra} threads; total {len(infos)}',
      flush=True)

cfgs = {t: ti for t, ti in infos.items()
        if ti['name'] and 'IOConfigThread' in ti['name']}
print(f'\n--- {len(cfgs)} IOConfigThreads ---')
for tva, ti in sorted(cfgs.items(), key=lambda kv: kv[1]['id'] or 0):
    print(f"  id={ti['id']:#06x} wait={ti['wait_event']:#018x} "
          f"state=0x{ti['state_byte']:02x} thread={tva:#x} {ti['name']}")

by_wait = collections.Counter(ti['wait_event'] for ti in infos.values())
print('\n--- top wait_events ---')
for ev, n in by_wait.most_common(8):
    who = [ti['name'] for ti in infos.values() if ti['wait_event'] == ev]
    print(f'  {n} x {ev:#x}: {who}')

# --- stack analysis ---
TEXT_LO, TEXT_HI = 0xFFFFFE001E000000, 0xFFFFFE0023400000


def stack_report(tva, ti):
    print(f"\n===== thread {tva:#x} id={ti['id']:#x} {ti['name']!r} "
          f"wait={ti['wait_event']:#x} =====")
    stack_va = ti['stack_va']
    ctxp = ti['saved_ctx']
    if not stack_va:
        print('  no stack VA')
        return
    sraw = ctx.read_va(stack_va, 0x4000)
    if sraw is None:
        print('  stack unreadable')
        return
    if ctxp and stack_va <= ctxp < stack_va + 0x4000:
        off = ctxp - stack_va
        print(f'  FP-walk from saved ctx (stack+{off:#x}):')
        seen = set()
        for depth in range(24):
            if off in seen or not (0 <= off < 0x4000 - 16):
                break
            seen.add(off)
            fp = struct.unpack_from('<Q', sraw, off)[0]
            lr = struct.unpack_from('<Q', sraw, off + 8)[0]
            print(f'    [{depth}] lr={lr:#x} -> {sym(lr)}')
            if not (stack_va <= fp < stack_va + 0x4000):
                break
            off = fp - stack_va
    # full scan: every text-range qword in the top 0x1000 of the stack
    print('  stack text-qwords (top 0x1000, high->low):')
    base = 0x3000
    hits = []
    for off in range(base, 0x4000 - 8, 8):
        v = struct.unpack_from('<Q', sraw, off)[0]
        if TEXT_LO <= v < TEXT_HI:
            hits.append((off, v))
    for off, v in hits:
        print(f'    stack+{off:#05x}: {v:#x} -> {sym(v)}')


for tva, ti in sorted(cfgs.items(), key=lambda kv: kv[1]['id'] or 0):
    stack_report(tva, ti)

# --- shared config event forensics ---
cfg_waits = collections.Counter(ti['wait_event'] for ti in cfgs.values())
shared = [ev for ev, n in cfg_waits.most_common() if n >= 2 and ev != 0]
for ev in shared:
    waiters = [t for t, ti in cfgs.items() if ti['wait_event'] == ev]
    print(f'\n##### shared config wait_event {ev:#x} '
          f'({len(waiters)} config waiters) #####')
    epa = ctx.pa_of(ev)
    if epa:
        raw = ctx.d.read_pa(epa - 0x40, 0x140)
        for off in range(0, len(raw), 8):
            v = struct.unpack_from('<Q', raw, off)[0]
            mark = ' <== event' if epa - 0x40 + off == epa else ''
            txt = ''
            chunk = raw[off:off + 8]
            if all(32 <= c < 127 or c == 0 for c in chunk):
                txt = ' ' + repr(chunk)
            print(f'  ev{off - 0x40:+#06x}: {v:#018x}{mark}{txt}')
    # holders: dump-wide qwords == ev
    pat = struct.pack('<Q', ev)
    holders = []
    j = data.find(pat)
    while j != -1:
        if j % 8 == 0:
            holders.append(j + DRAM)
        j = data.find(pat, j + 1)
    print(f'  {len(holders)} qword holders of the event address:')
    for hpa in holders[:40]:
        vas = ctx.va_cands(hpa)
        print(f'    PA {hpa:#x} VAs {["%#x" % v for v in vas]}')
    # common pointer fields across waiters
    raws = {t: infos[t]['raw'] for t in waiters}
    print('  fields identical across all waiters (offset: value):')
    for off in range(0, 0x900, 8):
        vals = {struct.unpack_from('<Q', r, off)[0] for r in raws.values()}
        if len(vals) == 1:
            v = vals.pop()
            if v and v != ev:
                print(f'    +{off:#05x}: {v:#018x}')

if len(sys.argv) > 2:
    out = {f'{t:#x}': {k: v for k, v in ti.items() if k != 'raw'}
           for t, ti in infos.items()}
    json.dump(out, open(sys.argv[2], 'w'), indent=1)
    print(f'\nwrote {sys.argv[2]}')
