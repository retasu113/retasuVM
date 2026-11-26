import struct, sys
sys.path.insert(0, ".")
from p5_common import Ctx, make_sym
ctx = Ctx("home_p30/dram_fpend_cycle1.bin")
sym = make_sym()
def is_heap(v): return v is not None and 0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF
def u64(va, off):
    b = ctx.read_va(va + off, 8)
    return struct.unpack("<Q", b)[0] if b else None
def comm_of(p):
    raw = ctx.read_va(p + 0x5CC, 32)
    if raw is None: return None
    e = raw.find(b"\x00")
    return raw[:e if e >= 0 else 32].decode("ascii", "replace")
def pid_of(p):
    v = u64(p, 0x60)
    return v & 0xFFFFFFFF if v is not None else None

LAUNCHD = 0xFFFFFE2DDFFC63A0
AUEB = 0xFFFFFE2DFF9E3A0
KT = ctx.task_va

def thread_proc(t):
    tro = u64(t, 0x3D8)
    return u64(tro, 0x18) if tro else None

def walk_task_threads(seed_thread, owner_proc, limit=64):
    """Walk task thread ring via +0x3B8(next)/+0x3C0(prev) from a seed thread.
    Returns (threads, head_addr or None)."""
    seen = []
    # forward
    cur = seed_thread
    head = None
    for _ in range(limit):
        if cur not in seen: seen.append(cur)
        nxt = u64(cur, 0x3B8)
        if not is_heap(nxt): head = nxt; break
        if thread_proc(nxt) != owner_proc: head = nxt; break
        if nxt in seen: break
        cur = nxt
    # backward
    cur = seed_thread
    for _ in range(limit):
        prv = u64(cur, 0x3C0)
        if not is_heap(prv): head = prv if head is None else head; break
        if thread_proc(prv) != owner_proc: head = prv if head is None else head; break
        if prv in seen: break
        seen.append(prv); cur = prv
    return seen, head

def show_thread(t, sym):
    raw = ctx.read_va(t, 0x900)
    if raw is None: print(f"    thread {t:#x}: UNREADABLE"); return
    u = lambda o: struct.unpack_from("<Q", raw, o)[0]
    tid = u(0x498); state = raw[0xB8]; we = u(0x18)
    namep = u(0x7D8)
    name = None
    if is_heap(namep):
        r = ctx.read_va(namep, 32)
        if r: 
            e = r.find(b"\x00"); name = r[:e if e>=0 else 32].decode("ascii","replace")
    upcb = u(0x100)
    upc = usp = None
    if is_heap(upcb):
        usp = u64(upcb, 0x100); upc = u64(upcb, 0x108)
    cd = u(0xF8)
    kpc = None
    if is_heap(cd) and cd != upcb:
        kpc = u64(cd, 0x100)
    wes = sym(we) if is_heap(we) and we >= 0xFFFFFE0000000000 and (we >> 40) == 0xFFFFFE else None
    print(f"    thread {t:#x} id={tid:#x} state={state:#04x} wait_event={we:#x} name={name!r}")
    print(f"        userPC={upc:#x} userSP={usp:#x} kernCtxPC={kpc if kpc is None else hex(kpc)} ({sym(kpc) if kpc else '-'})")
    if wes: print(f"        wait_event sym: {wes}")

# launchd threads from wqtrace seed
seed = 0xFFFFFE2839D0B010
threads, head = walk_task_threads(seed, LAUNCHD)
print(f"launchd (pid {pid_of(LAUNCHD)}): {len(threads)} threads, chain head candidate = {head:#x}" if head else f"launchd: {len(threads)} threads")
for t in threads: show_thread(t, sym)
# launchd task VA: head points into task struct (threads queue head); also scan proc for task ptr
if head:
    for delta in range(0, 0x400, 8):
        cand_task = head - delta
        # task's threads head field would be at cand_task+delta == head; check bsd_info: scan task for LAUNCHD
        hit = None
        for off in range(0, 0x600, 8):
            if u64(cand_task, off) == LAUNCHD: hit = off; break
        if hit is not None:
            print(f"  launchd task = {cand_task:#x} (threads-head offset {delta:#x}, bsd_info offset {hit:#x})")
            globals()['LTASK'] = cand_task; globals()['TH_OFF'] = delta; globals()['BSD_OFF'] = hit
            break
# auearlyboot via proc->task: scan auearlyboot proc for a task-like ptr using launchd calibration if found
if 'LTASK' in globals():
    # find proc->task offset: scan launchd proc for LTASK
    poff = None
    for off in range(0, 0x800, 8):
        if u64(LAUNCHD, off) == globals()['LTASK']: poff = off; break
    print(f"  proc->task offset = {poff:#x}" if poff is not None else "  proc->task offset NOT found")
    if poff is not None:
        atask = u64(AUEB, poff)
        print(f"auearlyboot (pid {pid_of(AUEB)}): task = {atask:#x}")
        if is_heap(atask):
            first = u64(atask, globals()['TH_OFF'])
            print(f"  threads head first = {first:#x} comm-check proc={thread_proc(first) if is_heap(first) else None:#x}")
            if is_heap(first) and thread_proc(first) == AUEB:
                ts, _ = walk_task_threads(first, AUEB)
                print(f"auearlyboot: {len(ts)} threads")
                for t in ts: show_thread(t, sym)
