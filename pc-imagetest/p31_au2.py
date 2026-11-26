import struct, sys
sys.path.insert(0, ".")
from p5_common import Ctx
from p27_dump import Dump as RawDump, walk as uwalk
ctx = Ctx("home_p30/dram_fpend_cycle1.bin")
def is_heap(v): return v is not None and 0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF
def u64(va, off=0):
    b = ctx.read_va(va + off, 8) if is_heap(va) else None
    return struct.unpack("<Q", b)[0] if b else None

T = 0xFFFFFE2839D0A020  # auearlyboot's only thread
# task via task_threads chain ends
ends = set()
cur = T
for _ in range(50):
    nxt = u64(cur, 0x3C8)
    if not is_heap(nxt) or nxt == T: ends.add(nxt); break
    cur = nxt
cur = T
for _ in range(50):
    prv = u64(cur, 0x3D0)
    if not is_heap(prv) or prv == T: ends.add(prv); break
    cur = prv
print("chain ends:", [hex(e) for e in ends if e])
ATASK = None
for e in ends:
    if is_heap(e): ATASK = e - 0x50
print(f"auearlyboot task = {ATASK:#x}")
amap = u64(ATASK, 0x28); apmap = u64(amap, 0x40) if is_heap(amap) else None
aroot = u64(apmap, 0x08) if is_heap(apmap) else None
print(f"map={amap:#x} pmap={apmap:#x} ttbr0_root={aroot:#x}" if aroot else "pmap chain FAILED")
upcb = u64(T, 0x100); ss = upcb + 0x08
fp, lr, sp, pc = u64(ss, 0xE8), u64(ss, 0xF0), u64(ss, 0xF8), u64(ss, 0x100)
print(f"upcb={upcb:#x} pc={pc:#x} sp={sp:#x} fp={fp:#x} lr={lr:#x}")
print(f"wait_event={u64(T, 0x18):#x}")
d = RawDump("home_p30/dram_fpend_cycle1.bin")
rootpa = aroot & 0x0000FFFFFFFFFFFF
def uread(va, n):
    out = b""
    while n > 0:
        chunk = min(n, 0x4000 - (va & 0x3FFF))
        pa = uwalk(d, rootpa, va)
        if pa is None: return None
        b = d.pa(pa, chunk)
        if b is None: return None
        out += b; va += chunk; n -= chunk
    return out
SLIDE = 0xA520000
print(f"[pc] {pc:#x} link={pc-SLIDE:#x}")
print(f"[lr] {lr:#x} link={lr-SLIDE:#x}")
for i in range(28):
    if not fp or fp % 8: break
    b = uread(fp, 16)
    if not b: print(f"  frame {i}: fp={fp:#x} UNREADABLE"); break
    nfp, nlr = struct.unpack("<QQ", b)
    print(f"  frame {i}: fp={fp:#x} ret={nlr:#x} link={nlr-SLIDE:#x}")
    if nfp <= fp: break
    fp = nfp
# stack bytes around SP (args / nearby pointers)
b = uread(sp, 128)
if b: print("stack[sp..sp+128):", b.hex())
