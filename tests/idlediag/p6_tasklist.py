"""Phase 6, step 1: enumerate ALL threads of kernel_task by walking the
task's own thread queue (task->threads), independent of the phase-4/5
record census. Derive the thread-side chain offset empirically from the
known (record-census) threads, locate the queue head inside the
kernel_task struct, then walk the whole list.

Usage: python3 p6_tasklist.py <dump> [census.json out]
"""
import json
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, census_threads, thread_info  # noqa: E402

dump = sys.argv[1]
ctx = Ctx(dump)
print(f'TTBR root = {ctx.root:#x}  kernel_task = {ctx.task_va:#x}')

threads = census_threads(ctx)
known = set(threads)
print(f'record census: {len(known)} threads')

task_raw = ctx.read_va(ctx.task_va, 0x2000)
if task_raw is None:
    raise SystemExit('kernel_task unreadable')
tq = lambda b, o: struct.unpack_from('<Q', b, o)[0]  # noqa: E731

raws = {}
for t in known:
    r = ctx.read_va(t, 0x900)
    if r:
        raws[t] = r

# --- derive the chain offset: for offset o, *(T+o) should be (T'+o) for
# another thread T', or (task_va + h) for the queue head. Score by how
# many known threads satisfy: *(T+o)-o in known, or *(T+o) in task. ---
print('\n--- chain-offset candidates (offset: hits/known) ---')
scores = []
for o in range(0, 0x900, 8):
    hits = 0
    for t, r in raws.items():
        v = tq(r, o)
        if not v:
            continue
        if (v - o) in known:
            hits += 1
        elif ctx.task_va <= v < ctx.task_va + 0x2000:
            hits += 1
    if hits >= 8:
        scores.append((hits, o))
for hits, o in sorted(scores, reverse=True)[:10]:
    print(f'  +{o:#05x}: {hits}/{len(raws)}')

if not scores:
    raise SystemExit('no chain offset found')
best_o = sorted(scores, reverse=True)[0][1]
print(f'using chain offset +{best_o:#x}')

# --- locate the queue head inside kernel_task: head.next = first+o,
# head.prev = last+o ---
head = None
for h in range(0, 0x2000 - 8, 8):
    v = tq(task_raw, h)
    if (v - best_o) in known:
        v2 = tq(task_raw, h + 8)
        if (v2 - best_o) in known or v2 == ctx.task_va + h:
            head = h
            print(f'queue head at task+{h:#x}: next={v:#x} prev={v2:#x}')
            break
if head is None:
    raise SystemExit('queue head not found in kernel_task')

head_addr = ctx.task_va + head

# --- walk the list ---
walked = []
cur = tq(task_raw, head)
seen = set()
while cur and cur != head_addr and cur not in seen:
    seen.add(cur)
    tva = cur - best_o
    walked.append(tva)
    nxt = ctx.Qva(tva + best_o)
    if nxt is None:
        print(f'  walk broke at {tva:#x}: next unreadable')
        break
    cur = nxt
print(f'\ntask-list walk: {len(walked)} threads '
      f'(record census had {len(known)})')

infos = {}
for tva in walked:
    ti = thread_info(ctx, tva)
    if ti:
        infos[tva] = ti

print('\n--- full roster (task list) ---')
for tva in walked:
    ti = infos.get(tva)
    if ti is None:
        print(f'  thread={tva:#x}  <thread_info failed>')
        continue
    mark = '' if tva in known else '  <== NOT in record census'
    print(f"  id={ti['id']:#06x} state=0x{ti['state_byte']:02x} "
          f"wait={ti['wait_event']:#018x} thread={tva:#x} "
          f"name={ti['name']!r}{mark}")

print('\n--- threads NOT in record census: detail ---')
for tva in walked:
    if tva in known:
        continue
    ti = infos.get(tva)
    bp = ctx.Qva(tva + 0x3D8)
    bpv = ctx.Qva(bp) if bp else None
    print(f"  thread={tva:#x} id={ti['id'] if ti else None} "
          f"name={ti['name'] if ti else None}")
    print(f'    +0x3D8 (back-ptr field) = {bp:#x}; '
          f'*(that) = {bpv if bpv is None else hex(bpv)} '
          f'(record census needs *(that)==thread VA)')

if len(sys.argv) > 2:
    out = {f'{t:#x}': {k: v for k, v in (infos.get(t) or {}).items()
                       if k != 'raw'}
           for t in walked}
    json.dump(out, open(sys.argv[2], 'w'), indent=1)
    print(f'\nwrote {sys.argv[2]}')
