"""Phase 8: authoritative holder hunt.

1. Enumerate ALL kernel_task threads via the task thread-list walk
   (p6_tasklist method), not the record census.
2. Scan every walked thread's kernel stack for APFS module-resources
   markers (external/internal fn rets, container/scheme start rets,
   APFS statics page, mutex object ptr).
3. Dump-wide regex scan for qwords in the APFS function ranges, as a
   cross-check for stacks of any thread both enumerations missed.
Usage: python3 p8_scan2.py <dump>
"""
import re
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, census_threads, thread_info, make_sym, SLIDE  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva
bracket = make_sym()

PAGE = 0xFFFFFE000A999000 + SLIDE
MUTEX_PTR = Q(PAGE + 0xB88)
EXT_FN = (0xFFFFFE0009FD19FC + SLIDE, 0xFFFFFE0009FD1B08 + SLIDE)
INT_FN = (0xFFFFFE0009FD27B8 + SLIDE, 0xFFFFFE0009FD2C54 + SLIDE)
CONT_START = (0xFFFFFE0009FD18DC + SLIDE, 0xFFFFFE0009FD19FC + SLIDE)
SCHEME_START = (0xFFFFFE0009FFD3C0 + SLIDE, 0xFFFFFE0009FFD610 + SLIDE)
WAIT_RET = 0xFFFFFE0009FD1A4C + SLIDE
INT_LOCK_RET = 0xFFFFFE0009FD27E8 + SLIDE
EXT_LOCK_RET = 0xFFFFFE0009FD1A20 + SLIDE


def in_rng(v, r):
    return r[0] <= v < r[1]


# ---- task-list walk (p6 method) ----
known = set(census_threads(ctx))
task_raw = ctx.read_va(ctx.task_va, 0x2000)
tq = lambda b, o: struct.unpack_from('<Q', b, o)[0]  # noqa: E731
raws = {}
for t in known:
    r = ctx.read_va(t, 0x900)
    if r:
        raws[t] = r
best_o, best_hits = None, 0
for o in range(0, 0x900, 8):
    hits = 0
    for t, r in raws.items():
        v = tq(r, o)
        if v and ((v - o) in known or ctx.task_va <= v < ctx.task_va + 0x2000):
            hits += 1
    if hits > best_hits:
        best_hits, best_o = hits, o
head = None
for h in range(0, 0x2000 - 8, 8):
    v = tq(task_raw, h)
    if (v - best_o) in known:
        v2 = tq(task_raw, h + 8)
        if (v2 - best_o) in known or v2 == ctx.task_va + h:
            head = h
            break
walked, seen = [], set()
cur = tq(task_raw, head)
head_addr = ctx.task_va + head
while cur and cur != head_addr and cur not in seen:
    seen.add(cur)
    tva = cur - best_o
    walked.append(tva)
    nxt = Q(tva + best_o)
    if nxt is None:
        break
    cur = nxt
print(f'task-list walk: {len(walked)} threads (record census {len(known)}), '
      f'chain off +{best_o:#x}')

stack_ranges = {}
print('\n--- per-thread marker scan (task-list roster) ---')
for tva in walked:
    ti = thread_info(ctx, tva)
    if ti is None or not ti['stack_va']:
        print(f'  thread {tva:#x}: no info/stack')
        continue
    stack_ranges[tva] = (ti['stack_va'], ti['stack_va'] + 0x4000)
    raw = ctx.read_va(ti['stack_va'], 0x4000)
    hits = []
    for off in range(0, 0x4000, 8):
        v = struct.unpack_from('<Q', raw, off)[0]
        if v == WAIT_RET:
            hits.append(f'*** WAIT_RET (in waitForMatchingService) @+{off:#x}')
        elif v == EXT_LOCK_RET:
            hits.append(f'EXT lock-ret (waiter in external fn) @+{off:#x}')
        elif v == INT_LOCK_RET:
            hits.append(f'INT lock-ret (waiter in internal fn) @+{off:#x}')
        elif in_rng(v, EXT_FN):
            hits.append(f'EXT_FN {bracket(v)} @+{off:#x}')
        elif in_rng(v, INT_FN):
            hits.append(f'INT_FN {bracket(v)} @+{off:#x}')
        elif in_rng(v, CONT_START):
            hits.append(f'CONT_START {bracket(v)} @+{off:#x}')
        elif in_rng(v, SCHEME_START):
            hits.append(f'SCHEME_START {bracket(v)} @+{off:#x}')
        elif v == PAGE:
            hits.append(f'APFS_PAGE @+{off:#x}')
        elif MUTEX_PTR and v == MUTEX_PTR:
            hits.append(f'MUTEX_OBJ @+{off:#x}')
    if hits:
        print(f'\nthread {tva:#x} id={ti["id"]:#x} name={ti["name"]!r} '
              f'wait={ti["wait_event"]:#x} waitq={Q(tva + 0x28):#x}')
        for h in hits:
            print(f'    {h}')

# ---- dump-wide cross-check for the decisive WAIT_RET value ----
print('\n--- dump-wide scan for WAIT_RET / EXT_FN-range values ---')
pat = re.compile(rb'(?=(.[\x58-\x5c]\x28\x22\x00\xfe\xff\xff))')
data = open(sys.argv[1], 'rb').read()
found = {}
for m in pat.finditer(data):
    pos = m.start()
    if pos % 8:
        continue
    v = struct.unpack('<Q', m.group(1))[0]
    if in_rng(v, EXT_FN) or in_rng(v, CONT_START):
        pa = pos + 0x70000000
        vas = ctx.va_cands(pa)
        owner = None
        for tva, (lo, hi) in stack_ranges.items():
            if vas and any(lo <= va < hi for va in vas):
                owner = tva
                break
        found.setdefault(v, []).append((pa, vas, owner))
for v, lst in sorted(found.items()):
    print(f'  {v:#x} ({bracket(v)}): {len(lst)} hit(s)')
    for pa, vas, owner in lst[:6]:
        print(f'      PA {pa:#x} VAs {[hex(x) for x in (vas or [])]} '
              f'stack_of={owner and hex(owner)}')
