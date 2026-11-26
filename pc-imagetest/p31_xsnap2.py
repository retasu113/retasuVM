import struct, sys
sys.path.insert(0, ".")
from p5_common import Ctx
name = sys.argv[1]
ctx = Ctx(f"home_p30/{name}")
def is_heap(v): return v is not None and 0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF
def rd(va, off=0):
    if not is_heap(va): return None
    b = ctx.read_va(va + off, 8)
    return struct.unpack("<Q", b)[0] if b else None
AUEB_PROC = 0xFFFFFE2DDFF9E3A0
# verify proc
b = ctx.read_va(AUEB_PROC + 0x5CC, 16)
print(f"{name}: aueb proc p_comm = {b!r} pid = {rd(AUEB_PROC, 0x60)}")
# scan global thread list for owner == aueb proc
SEED = 0xFFFFFE2839D0B010
seen = set(); cur = SEED; found = []
while is_heap(cur) and cur not in seen:
    seen.add(cur)
    tro = rd(cur, 0x3D8); proc = rd(tro, 0x18) if is_heap(tro) else None
    if proc == AUEB_PROC: found.append(cur)
    cur = rd(cur, 0x3B8)
print(f"scanned {len(seen)} threads; aueb threads: {[hex(f) for f in found]}")
for t in found:
    upcb = rd(t, 0x100); ss = upcb + 0x08 if is_heap(upcb) else None
    print(f"  t={t:#x} wait={rd(t,0x18):#x} upcb={upcb:#x}")
    if ss:
        vals = {k: rd(ss, o) for k, o in (("pc",0x100),("sp",0xF8),("fp",0xE8),("lr",0xF0),("x0",0),("x19",0x98),("x20",0xA0))}
        print("   ", {k: (hex(v) if v is not None else None) for k, v in vals.items()})
