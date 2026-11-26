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
    if not is_heap(p): return None
    raw = ctx.read_va(p + 0x5CC, 32)
    if raw is None: return None
    e = raw.find(b"\x00")
    return raw[:e if e >= 0 else 32].decode("ascii", "replace")
def thread_proc(t):
    tro = u64(t, 0x3D8)
    return u64(tro, 0x18) if is_heap(tro) else None

seed = 0xFFFFFE2839D0B010
# walk next direction, structural checks only
order = [seed]
cur = seed
for _ in range(300):
    nxt = u64(cur, 0x3B8)
    if not is_heap(nxt): print(f"next from {cur:#x}: {nxt} (end/head)"); break
    back = u64(nxt, 0x3C0)
    p = thread_proc(nxt)
    print(f"next: {nxt:#x} prev-back={back:#x} {'OK' if back == cur else 'MISMATCH'} proc={p:#x} comm={comm_of(p)!r} id={u64(nxt, 0x498):#x}")
    if nxt in order: print("  (ring closed)"); break
    order.append(nxt); cur = nxt
print(f"forward walk: {len(order)} threads")
# backward from seed
cur = seed; back_order = []
for _ in range(300):
    prv = u64(cur, 0x3C0)
    if not is_heap(prv): print(f"prev from {cur:#x}: {prv} (end/head)"); break
    fwd = u64(prv, 0x3B8)
    p = thread_proc(prv)
    print(f"prev: {prv:#x} next-fwd={fwd:#x} {'OK' if fwd == cur else 'MISMATCH'} proc={p:#x} comm={comm_of(p)!r} id={u64(prv, 0x498):#x}")
    if prv in order or prv in back_order: print("  (ring closed)"); break
    back_order.append(prv); cur = prv
print(f"backward walk: {len(back_order)} more threads")
