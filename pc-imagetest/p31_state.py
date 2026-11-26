import struct, sys
sys.path.insert(0, ".")
from p5_common import Ctx
ctx = Ctx("home_p30/dram_fpend_cycle1.bin")
def is_heap(v): return v is not None and 0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF
def u64(va, off=0):
    b = ctx.read_va(va + off, 8) if is_heap(va) else None
    return struct.unpack("<Q", b)[0] if b else None
SEED = 0xFFFFFE2839D0B010
threads = []; seen = set(); cur = SEED
while is_heap(cur) and cur not in seen:
    seen.add(cur); threads.append(cur); cur = u64(cur, 0x3B8)
print(f"{len(threads)} threads")
AUEB = 0xFFFFFE2839D0A020
IDLE_CAND = None
raws = {}
for t in threads:
    raws[t] = ctx.read_va(t, 0x3B8)
for off in range(0x1C0, 0x3B0, 4):
    vals = {}
    ok = True
    for t in threads:
        v = struct.unpack_from("<I", raws[t], off)[0]
        if v > 0xFF: ok = False; break
        vals[t] = v
    if not ok: continue
    distinct = set(vals.values())
    if len(distinct) < 2: continue
    from collections import Counter
    c = Counter(vals.values())
    print(f"off {off:#x}: dist {dict(c)}  aueb={vals.get(AUEB):#x}")
