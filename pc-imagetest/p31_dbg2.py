import struct, sys
sys.path.insert(0, ".")
from p5_common import Ctx
ctx = Ctx("home_p30/dram_fpend_cycle1.bin")
def u64(va, off):
    b = ctx.read_va(va + off, 8)
    return struct.unpack("<Q", b)[0] if b else None
def comm_of(p):
    raw = ctx.read_va(p + 0x5CC, 32)
    if raw is None: return None
    end = raw.find(b"\x00")
    try: return raw[:end if end >= 0 else 32].decode("ascii", "replace")
    except Exception: return None
L = 0xFFFFFE2DDFFC63A0
for label, start in (("launchd", L),):
    print(f"{label} {start:#x} comm={comm_of(start)!r}")
    for off in (0x00, 0x08, 0x10, 0x80, 0x88):
        print(f"   +{off:#x} = {u64(start, off):#x}")
# walk next with raw prints
cur = L
print("--- chain via +0x00 ---")
for i in range(10):
    nxt = u64(cur, 0x00)
    print(f"  {cur:#x} -> {nxt:#x} comm={comm_of(nxt) if nxt else None!r} pa={'ok' if nxt and ctx.pa_of(nxt) else 'UNMAPPED'}")
    if not nxt or nxt == cur: break
    cur = nxt
cur = L
print("--- chain via +0x08 ---")
for i in range(10):
    nxt = u64(cur, 0x08)
    print(f"  {cur:#x} -> {nxt:#x} comm={comm_of(nxt) if nxt else None!r} pa={'ok' if nxt and ctx.pa_of(nxt) else 'UNMAPPED'}")
    if not nxt or nxt == cur: break
    cur = nxt
