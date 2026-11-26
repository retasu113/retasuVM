#!/usr/bin/env python3
"""Phase 28: proc census on the home_p28 fpend dump.
Walk _allproc; for each proc print pid, p_comm, and the pmap root (ttep,
pmap+0x08) reached via proc_ro -> task -> map -> pmap. Match against:
  spinner TTBR0 (SFV capture)  ttbr0el1=0x4000085c08000 -> root 0x85c08000
  installs TTBR0 (P27TRACE)    ttbr0el1=0x3000080848000 -> root masked below
Run on the PC in ~/retasuvm/inst/imagetest (p5_common lives there).
Usage: p28_census.py <dump>
"""
import struct
import sys

sys.path.insert(0, ".")
from p5_common import Ctx, link_of, SLIDE

DUMP = sys.argv[1]
OA = 0x0000FFFFFFFFC000
P_COMM_OFF = 0x5CC
PROC_RO_OFF = 0x18
PR_TASK_OFF = 0x08
TASK_MAP_OFF = 0x28
VMAP_PMAP_OFF = 0x40

ctx = Ctx(DUMP)


def pac_strip(q):
    v = q & 0x0000FFFFFFFFFFFF
    if v & (1 << 47):
        v |= 0xFFFF000000000000
    return v


def is_kva(v):
    return 0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF


SPIN_ROOT = 0x4000085C08000 & OA
INST_ROOT = 0x3000080848000 & OA
print(f"spinner root PA = {SPIN_ROOT:#x}; installs root PA = {INST_ROOT:#x}")

allproc_link = link_of('_allproc')
print(f"_allproc link = {allproc_link:#x} rt = {allproc_link + SLIDE:#x}")
head = ctx.d.u64_phys(allproc_link + SLIDE)
print(f"allproc head (first proc VA) = {head:#x}")

proc = head
seen = 0
while is_kva(proc) and seen < 300:
    seen += 1
    try:
        blk = ctx.read_va(proc, 0x1000)
    except Exception as e:
        print(f"proc {proc:#x}: read fail {e}")
        break
    le_next = struct.unpack_from("<Q", blk, 0x00)[0]
    pid10 = struct.unpack_from("<i", blk, 0x10)[0]
    pid60 = struct.unpack_from("<i", blk, 0x60)[0]
    c = blk[P_COMM_OFF:P_COMM_OFF + 17].split(b"\x00")[0]
    comm = c.decode() if c and all(32 <= ch < 127 for ch in c) else "?"
    # chain to pmap
    ttep = None
    pmap = None
    try:
        pro = pac_strip(struct.unpack_from("<Q", blk, PROC_RO_OFF)[0])
        task = pac_strip(ctx.Qva(pro + PR_TASK_OFF))
        vmmap = pac_strip(ctx.Qva(task + TASK_MAP_OFF))
        pmap = pac_strip(ctx.Qva(vmmap + VMAP_PMAP_OFF))
        ttep = ctx.Qva(pmap + 0x08) & 0x0000FFFFFFFFFFFF
    except Exception as e:
        ttep = f"chain fail: {e}"
    mark = ""
    if ttep == SPIN_ROOT:
        mark = " <== SPINNER (SFV capture TTBR0)"
    if ttep == INST_ROOT:
        mark = " <== INSTALLS (P27TRACE TTBR0)"
    print(f"proc {proc:#x} pid@0x10={pid10} pid@0x60={pid60} comm={comm!r} pmap={pmap if pmap is None else hex(pmap)} ttep={ttep if isinstance(ttep, str) else hex(ttep)}{mark}")
    nxt = pac_strip(le_next)
    if nxt == proc:
        break
    proc = nxt
print(f"census done: {seen} procs")
