#!/usr/bin/env python3
"""Phase 26: find the launchd worker thread's stack mapping in the p25
dump — walk launchd's vm_map entry list and locate the entry containing
the PCB's saved SP 0x16f1f3cf8. Determines the stack [start, end) and the
offset C = end - SP (how far below the stack top the initial SP sits),
which discriminates "stack itself misaligned" from "subtraction constant".

Chain (phase 24 calibrations): census thread -> t_tro (+0x3D8) ->
tro_proc (+0x18, PAC-stripped) -> proc -> p_proc_ro (+0x18) -> proc_ro ->
pr_task (+0x08) -> task -> task->map (+0x28) -> vm_map. vm_map->pmap
+0x40; hdr.links at map+0x10 (lock is 0x10 B; verified by pattern below).
Entry: links at +0x00 (prev +0x00, next +0x08, start +0x10, end +0x18).

Run on the PC. Usage: p26_stackmap.py <dump>
Outputs: p26_stackmap_out.txt
"""
import struct
import sys

sys.path.insert(0, ".")
from p5_common import Ctx, census_threads  # noqa: E402

DUMP = sys.argv[1]
SP = 0x16F1F3CF8
P_COMM_OFF = 0x5CC
T_TRO_OFF = 0x3D8
TRO_PROC_OFF = 0x18
PROC_RO_OFF = 0x18
PR_TASK_OFF = 0x08
TASK_MAP_OFF = 0x28
VMAP_PMAP_OFF = 0x40

ctx = Ctx(DUMP)
out = open("p26_stackmap_out.txt", "w")


def log(s=""):
    print(s)
    out.write(s + "\n")


def pac_strip(q):
    v = q & 0x0000FFFFFFFFFFFF
    if v & (1 << 47):
        v |= 0xFFFF000000000000
    return v


def is_kva(v):
    return 0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF


# ---- find a launchd thread, walk to its task + map ----
launchd_task = None
launchd_pmap = None
for tva in census_threads(ctx):
    try:
        traw = ctx.read_va(tva, 0x900)
        if traw is None:
            continue
        tro = struct.unpack_from("<Q", traw, T_TRO_OFF)[0]
        if not is_kva(tro):
            continue
        tproc_raw = ctx.Qva(tro + TRO_PROC_OFF)
        if tproc_raw is None:
            continue
        proc = pac_strip(tproc_raw)
        if not is_kva(proc):
            continue
        pblk = ctx.read_va(proc, 0x1000)
        if pblk is None:
            continue
        c = pblk[P_COMM_OFF:P_COMM_OFF + 17].split(b"\x00")[0]
        comm = c.decode() if c and all(32 <= ch < 127 for ch in c) else "?"
        if comm != "launchd":
            continue
        pro_raw = struct.unpack_from("<Q", pblk, PROC_RO_OFF)[0]
        pro = pac_strip(pro_raw)
        if not is_kva(pro):
            continue
        task_raw = ctx.Qva(pro + PR_TASK_OFF)
        if task_raw is None:
            continue
        task = pac_strip(task_raw)
        if not is_kva(task):
            continue
        map_raw = ctx.Qva(task + TASK_MAP_OFF)
        if map_raw is None:
            continue
        vmmap = pac_strip(map_raw)
        if not is_kva(vmmap):
            continue
        launchd_task = task
        log(f"launchd thread={tva:#x} proc={proc:#x} task={task:#x} map={vmmap:#x}")
        # verify pmap at +0x40
        pmap_raw = ctx.Qva(vmmap + VMAP_PMAP_OFF)
        log(f"  map+0x40 (pmap) = {pmap_raw:#x} (expect 0xfffffe2299fe1090 raw or PAC-signed)")
        break
    except Exception as e:
        log(f"  thread {tva:#x}: error {e}")

if launchd_task is None:
    log("FAIL: no launchd thread found")
    sys.exit(1)

vmmap = pac_strip(ctx.Qva(launchd_task + TASK_MAP_OFF))
log(f"\n--- vm_map @ {vmmap:#x}: first 0x80 B ---")
hdr = ctx.read_va(vmmap, 0x80)
for off in range(0, 0x80, 8):
    v = struct.unpack_from("<Q", hdr, off)[0]
    log(f"  map+{off:#04x} = {v:#018x}")

# hdr.links: find offset where links live: links.next should be an entry
# whose start/end are user VAs; links.start = min_offset (0), end = max.
# Try hdr at map+0x10 (lock = 0x10 B).
for hdr_off in (0x10, 0x08, 0x00, 0x18, 0x20):
    base = vmmap + hdr_off
    raw = ctx.read_va(base, 0x20)
    if raw is None:
        continue
    prev, nxt, start, end = struct.unpack_from("<QQQQ", raw, 0)
    log(f"\nhdr candidate map+{hdr_off:#x}: prev={prev:#x} next={nxt:#x} start={start:#x} end={end:#x}")
    if is_kva(nxt) and start <= SP < end:
        log(f"  ^^ plausible hdr (start<=SP<end) at map+{hdr_off:#x}")
        HDR_OFF = hdr_off
        break
else:
    log("FAIL: no plausible hdr found")
    sys.exit(1)

# ---- walk the entry list from hdr.links.next ----
log(f"\n--- walking entries from hdr.links.next (map+{HDR_OFF:#x}) ---")
first = ctx.Qva(vmmap + HDR_OFF + 8)
log(f"first entry VA = {first:#x}")
count = 0
hits = []
cur = first
seen = set()
while cur and is_kva(cur) and cur not in seen and count < 5000:
    seen.add(cur)
    raw = ctx.read_va(cur, 0x20)
    if raw is None:
        log(f"  entry {cur:#x}: unreadable")
        break
    prev, nxt, start, end = struct.unpack_from("<QQQQ", raw, 0)
    size = end - start
    if start <= SP < end:
        hits.append((cur, start, end))
        log(f"  *** STACK? entry={cur:#x} [{start:#x}, {end:#x}) size={size:#x} "
            f"SP-start={SP - start:#x} end-SP={end - SP:#x}")
    count += 1
    if nxt == vmmap + HDR_OFF or nxt == 0:
        break
    cur = nxt
log(f"walked {count} entries; {len(hits)} contain SP")
if not hits:
    log("FAIL: no entry contains SP 0x16f1f3cf8")

# also list entries near the SP (within 0x1000000) for context
log("\n--- entries within 0x200000 of SP ---")
cur = first
count = 0
seen = set()
while cur and is_kva(cur) and cur not in seen and count < 5000:
    seen.add(cur)
    raw = ctx.read_va(cur, 0x20)
    if raw is None:
        break
    prev, nxt, start, end = struct.unpack_from("<QQQQ", raw, 0)
    if abs(start - SP) < 0x200000 or abs(end - SP) < 0x200000:
        log(f"  entry={cur:#x} [{start:#x}, {end:#x}) size={end - start:#x}")
    count += 1
    if nxt == vmmap + HDR_OFF or nxt == 0:
        break
    cur = nxt

out.close()
print("wrote p26_stackmap_out.txt")
