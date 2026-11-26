import struct, sys, collections
sys.path.insert(0, ".")
from p5_common import Ctx, make_sym
ctx = Ctx(sys.argv[1] if len(sys.argv) > 1 else "home_p30/dram_fpend_cycle1.bin")
sym = make_sym()
def is_heap(v): return v is not None and 0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF
def u64(va, off):
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
def valid_thread(t):
    if not is_heap(t): return False
    raw = ctx.read_va(t, 0x500)
    if raw is None: return False
    return u64(t, 0x498) is not None and is_heap(u64(t, 0x3D8))

seed = 0xFFFFFE2839D0B010
threads = {seed}
# forward
cur = seed
for _ in range(2000):
    nxt = u64(cur, 0x3B8)
    if not valid_thread(nxt) or nxt in threads:
        print(f"forward stop at {cur:#x}: next={nxt}")
        break
    threads.add(nxt); cur = nxt
# backward
cur = seed
for _ in range(2000):
    prv = u64(cur, 0x3C0)
    if not valid_thread(prv) or prv in threads:
        print(f"backward stop at {cur:#x}: prev={prv}")
        break
    threads.add(prv); cur = prv
print(f"global thread census: {len(threads)} threads")
byproc = collections.defaultdict(list)
for t in threads:
    byproc[thread_proc(t)].append(t)
for p, ts in sorted(byproc.items(), key=lambda kv: str(comm_of(kv[0]))):
    print(f"proc {p:#x} comm={comm_of(p)!r} threads={len(ts)}")
print("\n--- user-proc threads detail ---")
for p, ts in byproc.items():
    c = comm_of(p)
    if c in ("kernel_task", None): continue
    for t in sorted(ts):
        raw = ctx.read_va(t, 0x900)
        u = lambda o: struct.unpack_from("<Q", raw, o)[0]
        upcb = u(0x100)
        upc = u64(upcb, 0x108) if is_heap(upcb) else None
        usp = u64(upcb, 0x100) if is_heap(upcb) else None
        print(f"  [{c}] thread {t:#x} id={u(0x498):#x} state={raw[0xB8]:#04x} wait_event={u(0x18):#x} userPC={upc} userSP={usp}")
print("\n--- kernel thread state histogram ---")
hist = collections.Counter()
wehist = collections.Counter()
for p, ts in byproc.items():
    if comm_of(p) != "kernel_task": continue
    for t in ts:
        raw = ctx.read_va(t, 0x900)
        hist[raw[0xB8]] += 1
        we = struct.unpack_from("<Q", raw, 0x18)[0]
        wehist[we] += 1
print("state bytes:", dict(hist))
print("top wait_events:", [(hex(w), n) for w, n in wehist.most_common(8)])
