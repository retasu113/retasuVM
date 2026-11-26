import struct, sys
sys.path.insert(0, ".")
from p5_common import Ctx, make_sym

DUMP = sys.argv[1] if len(sys.argv) > 1 else "home_p30/dram_fpend_cycle1.bin"
ctx = Ctx(DUMP)
sym = make_sym()
def is_heap(v): return 0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF
def comm_of(p):
    raw = ctx.read_va(p + 0x5CC, 32)
    if raw is None: return None
    end = raw.find(b"\x00")
    try: return raw[:end if end >= 0 else 32].decode("ascii", "replace")
    except Exception: return None
def u64(va, off):
    b = ctx.read_va(va + off, 8)
    return struct.unpack("<Q", b)[0] if b else None

LAUNCHD = 0xFFFFFE2DDFFC63A0
# --- allproc walk ---
procs = {}
def add_proc(p):
    if p in procs or not is_heap(p): return False
    c = comm_of(p)
    if c is None or not c.isprintable(): return False
    procs[p] = c
    return True
add_proc(LAUNCHD)
for off, name in ((0x00, "next"), (0x08, "prev")):
    cur = LAUNCHD
    for _ in range(512):
        nxt = u64(cur, off)
        if not nxt or not add_proc(nxt): break
        cur = nxt
print(f"allproc walk: {len(procs)} procs")
KNOWN_PID = {"launchd": 1, "applekeystored": 10, "dirs_cleaner": 12}
pidvotes = {}
for p, c in sorted(procs.items(), key=lambda kv: kv[1]):
    lo40 = u64(p, 0x40); lo60 = u64(p, 0x60)
    lo40 = lo40 & 0xFFFFFFFF if lo40 is not None else None
    lo60 = lo60 & 0xFFFFFFFF if lo60 is not None else None
    print(f"  proc {p:#x} comm={c!r} pid@0x40={lo40} pid@0x60={lo60}")
    if c in KNOWN_PID:
        if lo40 == KNOWN_PID[c]: pidvotes[0x40] = pidvotes.get(0x40, 0) + 1
        if lo60 == KNOWN_PID[c]: pidvotes[0x60] = pidvotes.get(0x60, 0) + 1
print("pid offset votes:", pidvotes)
