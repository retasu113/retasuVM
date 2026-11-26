import struct, sys
from collections import Counter
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
    if ctx.read_va(cur + 0x500, 8) is None: break
    tro = u64(cur, 0x3D8)
    if not is_heap(tro): break
    seen.add(cur); threads.append(cur)
    cur = u64(cur, 0x3B8)
print(f"{len(threads)} threads (validated walk)")
def owner(t):
    tro = u64(t, 0x3D8); proc = u64(tro, 0x18) if is_heap(tro) else None
    if not is_heap(proc): return "?"
    b = ctx.read_va(proc + 0x5CC, 16)
    return b.rstrip(b"\x00").decode("ascii", "replace") if b else "?"
dist = Counter()
for t in threads:
    raw = ctx.read_va(t, 0x1D0)
    st = struct.unpack_from("<I", raw, 0x1C8)[0]
    dist[(owner(t), st)] += 1
for (o, st), n in sorted(dist.items()):
    print(f"  {o:16s} state={st:#04x} x{n}")
aueb = 0xFFFFFE2839D0A020
raw = ctx.read_va(aueb, 0x1D0)
print(f"aueb state @+0x1C8 = {struct.unpack_from('<I', raw, 0x1C8)[0]:#x} (TH_RUN=0x04, TH_WAIT=0x01, TH_UNINT=0x08)")
for t in (0xFFFFFE2839D0B010, 0xFFFFFE2839D08040, 0xFFFFFE2839D09828):
    raw = ctx.read_va(t, 0x1D0)
    print(f"launchd {t:#x} state = {struct.unpack_from('<I', raw, 0x1C8)[0]:#x}")
