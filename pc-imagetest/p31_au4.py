import struct, sys
sys.path.insert(0, ".")
from p5_common import Ctx, make_sym
from p27_dump import Dump as RawDump, walk as uwalk
ctx = Ctx("home_p30/dram_fpend_cycle1.bin")
sym = make_sym()
def is_heap(v): return v is not None and 0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF
def u64(va, off=0):
    b = ctx.read_va(va + off, 8) if is_heap(va) else None
    return struct.unpack("<Q", b)[0] if b else None
T = 0xFFFFFE2839D0A020
AROOT = 0x80898000
upcb = u64(T, 0x100); ss = upcb + 0x08
print("aueb saved user regs:")
for n in range(0, 29):
    print(f"  x{n} = {u64(ss, n*8):#x}")
print(f"  fp={u64(ss,0xE8):#x} lr={u64(ss,0xF0):#x} sp={u64(ss,0xF8):#x} pc={u64(ss,0x100):#x} cpsr={u64(ss,0x108):#x}")
d = RawDump("home_p30/dram_fpend_cycle1.bin")
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
pc = u64(ss, 0x100)
code = uread(AROOT, pc - 32, 64)
print("\ninstructions around pc (runtime):")
for i in range(16):
    w = struct.unpack_from("<I", code, i*4)[0]
    mark = " <-- pc" if pc - 32 + i*4 == pc else ""
    print(f"  {pc-32+i*4:#x}: {w:08x}{mark}")
# kernel stack scan
stack_va = u64(T, 0xE8)
print(f"\nthread+0xE8 (stack?) = {stack_va:#x}")
if is_heap(stack_va):
    raw = ctx.read_va(stack_va, 0x8000)
    if raw:
        hits = []
        for off in range(0, len(raw) - 8, 8):
            v = struct.unpack_from("<Q", raw, off)[0]
            if 0xFFFFFE0010000000 <= v <= 0xFFFFFE0030000000:
                hits.append((off, v, sym(v)))
        for off, v, s in hits[:40]:
            print(f"  stack+{off:#x}: {v:#x} {s}")
        print(f"  ({len(hits)} kernel-text-like qwords)")
# dyld cache image list via launchd space
LROOT = 0x80824000
CACHE = 0x18A520000
hdr = uread(LROOT, CACHE, 0x100)
imgs_off, imgs_cnt = struct.unpack_from("<II", hdr, 24)
infos = uread(LROOT, CACHE + imgs_off, imgs_cnt * 32)
images = []
for i in range(imgs_cnt):
    addr, mt, ino, poff2, pad = struct.unpack_from("<QQQII", infos, i * 32)
    images.append((addr, poff2))
def path_of(poff2):
    b = uread(LROOT, CACHE + poff2, 160)
    if not b: return "?"
    e = b.find(b"\x00")
    return b[:e if e >= 0 else 160].decode("ascii", "replace")
def sym_user(linkpc):
    best = None
    for addr, poff2 in images:
        if addr <= linkpc and (best is None or addr > best[0]): best = (addr, poff2)
    if best: return f"{path_of(best[1])} +{linkpc - best[0]:#x}"
    return "?"
SLIDE = 0xA520000
print(f"\ncache images: {len(images)}")
for label, rpc in (("aueb pc", pc), ("aueb lr", u64(ss, 0xF0))):
    print(f"  {label}: link {rpc-SLIDE:#x} -> {sym_user(rpc-SLIDE)}")
for lbl, lk in (("f0", 0x180096ff4), ("f4", 0x1802d585c), ("f7", 0x180083900), ("f8", 0x1800e43ec), ("f16", 0x1800f3c88), ("f21", 0x180187d2c), ("f25", 0x18012b89c)):
    print(f"  frame {lbl}: link {lk:#x} -> {sym_user(lk)}")
