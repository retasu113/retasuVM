import struct, sys
sys.path.insert(0, ".")
from p5_common import Ctx
from p27_dump import Dump as RawDump, walk as uwalk
ctx = Ctx("home_p30/dram_fpend_cycle1.bin")
def is_heap(v): return v is not None and 0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF
def u64(va, off=0):
    b = ctx.read_va(va + off, 8) if is_heap(va) else None
    return struct.unpack("<Q", b)[0] if b else None
T = 0xFFFFFE2839D0A020
L = 0xFFFFFE2839D0B010
for name, t in (("aueb", T), ("launchd", L)):
    print(f"{name} thread {t:#x}:")
    for off in range(0x3A0, 0x3E8, 8):
        print(f"   +{off:#x} = {u64(t, off):#x}")
# task ptr candidates in aueb thread: fields equal to a struct whose +0x50 == T or +0x58 == T
ATASK = 0xFFFFFE2DDFF9EB38
# pmap root
amap = u64(ATASK, 0x28); apmap = u64(amap, 0x40) if is_heap(amap) else None
aroot = u64(apmap, 0x08) if is_heap(apmap) else None
print(f"ATASK={ATASK:#x} map={amap:#x} pmap={apmap:#x} root={aroot:#x}")
upcb = u64(T, 0x100); ss = upcb + 0x08
fp, lr, sp, pc = u64(ss, 0xE8), u64(ss, 0xF0), u64(ss, 0xF8), u64(ss, 0x100)
print(f"pc={pc:#x} sp={sp:#x} fp={fp:#x} lr={lr:#x} wait_event={u64(T,0x18):#x}")
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
print(f"[pc] link={pc-SLIDE:#x}  [lr] link={lr-SLIDE:#x}")
for i in range(28):
    if not fp or fp % 8: break
    b = uread(fp, 16)
    if not b: print(f"  frame {i}: fp={fp:#x} UNREADABLE"); break
    nfp, nlr = struct.unpack("<QQ", b)
    print(f"  frame {i}: fp={fp:#x} ret={nlr:#x} link={nlr-SLIDE:#x}")
    if nfp <= fp: break
    fp = nfp
b = uread(sp, 96)
if b: print("stack@sp:", b.hex())
