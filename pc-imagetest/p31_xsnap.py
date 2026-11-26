import struct, sys
sys.path.insert(0, ".")
from p5_common import Ctx
from p27_dump import Dump as RawDump, walk as uwalk
name = sys.argv[1]
ctx = Ctx(f"home_p30/{name}")
def is_heap(v): return v is not None and 0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF
def u64(va, off=0):
    b = ctx.read_va(va + off, 8) if is_heap(va) else None
    return struct.unpack("<Q", b)[0] if b else None
def show(tag, t):
    upcb = u64(t, 0x100); ss = upcb + 0x08
    print(f"{tag} t={t:#x} wait={u64(t,0x18):#x} pc={u64(ss,0x100):#x} sp={u64(ss,0xF8):#x} fp={u64(ss,0xE8):#x} lr={u64(ss,0xF0):#x} x0={u64(ss,0):#x} x19={u64(ss,0x98):#x} x20={u64(ss,0xA0):#x}")
show("aueb   ", 0xFFFFFE2839D0A020)
show("launchd", 0xFFFFFE2839D0B010)
show("launchd", 0xFFFFFE2839D08040)
show("launchd", 0xFFFFFE2839D09828)
# aueb stack frame fingerprint: first 6 saved fps via its pmap
d = RawDump(f"home_p30/{name}")
def uread(rootpa, va, n):
    out = b""
    while n > 0:
        chunk = min(n, 0x4000 - (va & 0x3FFF))
        pa = uwalk(d, rootpa, va)
        if pa is None: return None
        b = d.pa(pa, chunk)
        if b is None: return None
        out += b; va += chunk; n -= chunk
    return out
t = 0xFFFFFE2839D0A020
upcb = u64(t, 0x100); ss = upcb + 0x08
fp = u64(ss, 0xE8)
chain = []
for i in range(8):
    if not fp: break
    b = uread(0x80898000, fp, 16)
    if not b: break
    nfp, nlr = struct.unpack("<QQ", b)
    chain.append(f"{fp:#x}->{nlr:#x}")
    if nfp <= fp: break
    fp = nfp
print("aueb fp chain:", " | ".join(chain))
