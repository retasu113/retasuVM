import struct, sys
sys.path.insert(0, ".")
from p5_common import Ctx, make_sym
ctx = Ctx("home_p30/dram_fpend_cycle1.bin")
def is_heap(v): return v is not None and 0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF
def u64(va, off=0):
    b = ctx.read_va(va + off, 8) if is_heap(va) else None
    return struct.unpack("<Q", b)[0] if b else None
def comm_of(p):
    if not is_heap(p): return None
    raw = ctx.read_va(p + 0x5CC, 32)
    if raw is None: return None
    e = raw.find(b"\x00")
    return raw[:e if e >= 0 else 32].decode("ascii", "replace")
def thread_proc(t):
    tro = u64(t, 0x3D8)
    return u64(tro, 0x18) if is_heap(tro) else None

LAUNCHD = 0xFFFFFE2DDFFC63A0
AUEB = 0xFFFFFE2DFF9E3A0
KT = ctx.task_va

def walk_chain(seed, noff, poff, owner=None, limit=300):
    """Walk a queue_chain; returns (nodes, end_value)."""
    nodes = [seed]; cur = seed
    for _ in range(limit):
        nxt = u64(cur, noff)
        if not is_heap(nxt): return nodes, nxt
        if nxt in nodes: return nodes, nxt
        # structural: candidate thread must have prev link back to cur (or be head)
        if u64(nxt, poff) != cur:
            return nodes, nxt
        nodes.append(nxt); cur = nxt
    return nodes, None

# Which chain is task_threads? Try +0x3C8/+0x3D0 from launchd seed
seed = 0xFFFFFE2839D0B010
fwd, endf = walk_chain(seed, 0x3C8, 0x3D0)
bwd, endb = walk_chain(seed, 0x3D0, 0x3C8)
allset = list(dict.fromkeys(fwd + bwd))
owners = {t: comm_of(thread_proc(t)) for t in allset}
print(f"+0x3C8 chain from launchd seed: {len(allset)} nodes, owners={set(owners.values())}, ends: fwd={endf} bwd={endb}")
for t in allset: print(f"    {t:#x} owner={owners[t]!r} id={u64(t,0x498):#x}")
# The end value that is NOT a thread = &task->task_threads head. task = end - offsetof.
# Calibrate offsetof on kernel_task: pick a kernel thread from census via global list neighbor d08838 (kernel)
kseed = 0xFFFFFE2839D08838
kfwd, kendf = walk_chain(kseed, 0x3C8, 0x3D0)
kbwd, kendb = walk_chain(kseed, 0x3D0, 0x3C8)
kall = list(dict.fromkeys(kfwd + kbwd))
print(f"+0x3C8 chain from kernel seed: {len(kall)} nodes, ends fwd={kendf} bwd={kendb}")
for cand_end in (kendf, kendb, endf, endb):
    if is_heap(cand_end):
        print(f"  end {cand_end:#x}: minus kernel_task = {cand_end - KT:#x} (if positive small => offsetof)")
