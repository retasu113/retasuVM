#!/usr/bin/env python3
"""Phase 26: identify thread 0xfffffe1df6228040 (owner of the FIRE PCB):
read its t_tro -> tro_proc -> proc -> p_comm, its task -> map -> pmap,
and its machine fields (contextData/upcb/uNeon at +0xF8/+0x100/+0x108).
Also print the thread's state-relevant fields for context.
Run on the PC. Usage: p26_threadid.py <dump>
Outputs: p26_threadid_out.txt
"""
import struct
import sys

sys.path.insert(0, ".")
from p5_common import Ctx

DUMP = sys.argv[1]
T = 0xFFFFFE1DF6228040
PCB = 0xFFFFFE18502ADEE0
P_COMM_OFF = 0x5CC
T_TRO_OFF = 0x3D8
TRO_PROC_OFF = 0x18
PROC_RO_OFF = 0x18
PR_TASK_OFF = 0x08
TASK_MAP_OFF = 0x28
VMAP_PMAP_OFF = 0x40

ctx = Ctx(DUMP)
out = open("p26_threadid_out.txt", "w")


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


raw = ctx.read_va(T, 0x1000)
log(f"thread struct @ {T:#x} (first 0x120 B):")
for off in range(0, 0x120, 8):
    v = struct.unpack_from("<Q", raw, off)[0]
    mark = ""
    if v == PCB:
        mark = " <-- PCB"
    log(f"  +{off:#04x} = {v:#018x}{mark}")

traw = raw
tro = struct.unpack_from("<Q", traw, T_TRO_OFF)[0]
log(f"\nt_tro (+0x3D8) = {tro:#x}")
tproc_raw = ctx.Qva(tro + TRO_PROC_OFF)
log(f"tro_proc raw = {tproc_raw:#x}  stripped = {pac_strip(tproc_raw):#x}")
proc = pac_strip(tproc_raw)
pblk = ctx.read_va(proc, 0x1000)
c = pblk[P_COMM_OFF:P_COMM_OFF + 17].split(b"\x00")[0]
comm = c.decode() if c and all(32 <= ch < 127 for ch in c) else "?"
log(f"proc = {proc:#x}  p_comm = {comm!r}")
pro_raw = struct.unpack_from("<Q", pblk, PROC_RO_OFF)[0]
pro = pac_strip(pro_raw)
task_raw = ctx.Qva(pro + PR_TASK_OFF)
task = pac_strip(task_raw)
log(f"proc_ro = {pro:#x}  task = {task:#x}")
map_raw = ctx.Qva(task + TASK_MAP_OFF)
vmmap = pac_strip(map_raw)
log(f"task->map = {vmmap:#x}")
pmap_raw = ctx.Qva(vmmap + VMAP_PMAP_OFF)
log(f"map->pmap = {pmap_raw:#x}")
ttbr0 = ctx.Qva(pmap_raw + 0x218)
log(f"pmap+0x218 (TTBR0) = {ttbr0:#x}  (launchd's = 0x85b70000; capture TTBR0 = 0x85b70000)")
out.close()
print("wrote p26_threadid_out.txt")
