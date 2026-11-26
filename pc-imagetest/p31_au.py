import struct, sys
sys.path.insert(0, ".")
from p5_common import Ctx
from p27_dump import Dump as RawDump, walk as uwalk
ctx = Ctx("home_p30/dram_fpend_cycle1.bin")
def is_heap(v): return v is not None and 0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF
def u64(va, off=0):
    b = ctx.read_va(va + off, 8) if is_heap(va) else None
    return struct.unpack("<Q", b)[0] if b else None
LAUNCHD = 0xFFFFFE2DDFFC63A0
AUEB = 0xFFFFFE2DFF9E3A0
LTASK = 0xFFFFFE2DDFFC6B38
poff = None
for off in range(0, 0x800, 8):
    if u64(LAUNCHD, off) == LTASK: poff = off; break
print(f"proc->task offset: {poff:#x}" if poff is not None else "proc->task NOT FOUND")
ATASK = u64(AUEB, poff) if poff is not None else None
print(f"auearlyboot task = {ATASK:#x}")
first = u64(ATASK, 0x50) if is_heap(ATASK) else None
print(f"auearlyboot first thread = {first:#x} (expect 0xfffffe2839d0a020)")
# pmap root: task+0x28 = map, map+0x40 = pmap, pmap+0x08 = root
amap = u64(ATASK, 0x28); apmap = u64(amap, 0x40) if is_heap(amap) else None
aroot = u64(apmap, 0x08) if is_heap(apmap) else None
print(f"auearlyboot map={amap:#x} pmap={apmap:#x} ttbr0_root={aroot:#x}" if aroot else "pmap chain failed")
# launchd pmap root for cache parse (expect 0x80824000)
lmap = u64(LTASK, 0x28); lpmap = u64(lmap, 0x40) if is_heap(lmap) else None
lroot = u64(lpmap, 0x08) if is_heap(lpmap) else None
print(f"launchd ttbr0_root={lroot:#x}")
# auearlyboot thread user regs
T = first
upcb = u64(T, 0x100)
uss = upcb + 0x08
regs = {n: u64(uss, o) for n, o in (("fp", 0xE8), ("lr", 0xF0), ("sp", 0xF8), ("pc", 0x100))}
print(f"auearlyboot thread upcb={upcb:#x} pc={regs['pc']:#x} sp={regs['sp']:#x} fp={regs['fp']:#x} lr={regs['lr']:#x}")
print(f"  wait_event={u64(T, 0x18):#x} state_int@0xB8raw={ctx.read_va(T+0xB0, 16).hex()}")
# FP walk in auearlyboot space
d = RawDump("home_p30/dram_fpend_cycle1.bin")
def uread(va, n):
    out = b""
    while n > 0:
        chunk = min(n, 0x4000 - (va & 0x3FFF))
        pa = uwalk(d, aroot & 0x0000FFFFFFFFFFFF, va)
        if pa is None: return None
        b = d.pa(pa, chunk)
        if b is None: return None
        out += b; va += chunk; n -= chunk
    return out
SLIDE = 0xA520000
fp = regs["fp"]; lr = regs["lr"]
print("FP chain (runtime -> link):")
print(f"  [pc] {regs['pc']:#x} -> {regs['pc']-SLIDE:#x}")
print(f"  [lr] {lr:#x} -> {lr-SLIDE:#x}")
for i in range(24):
    if not fp or fp % 8: break
    b = uread(fp, 16)
    if not b: print(f"  frame {i}: fp={fp:#x} UNREADABLE"); break
    nfp, nlr = struct.unpack("<QQ", b)
    print(f"  frame {i}: fp={fp:#x} ret={nlr:#x} -> link {nlr-SLIDE:#x}")
    if nfp <= fp: break
    fp = nfp
# dyld cache image list via launchd space
def lread(va, n):
    out = b""
    while n > 0:
        chunk = min(n, 0x4000 - (va & 0x3FFF))
        pa = uwalk(d, lroot & 0x0000FFFFFFFFFFFF, va)
        if pa is None: return None
        b = d.pa(pa, chunk)
        if b is None: return None
        out += b; va += chunk; n -= chunk
    return out
CACHE = 0x18A520000
hdr = lread(CACHE, 0x100)
print("cache magic:", hdr[:16])
imgs_off, imgs_cnt = struct.unpack_from("<II", hdr, 24)
print(f"images: off={imgs_off:#x} count={imgs_cnt}")
infos = lread(CACHE + imgs_off, imgs_cnt * 32)
images = []
for i in range(imgs_cnt):
    addr, mt, ino, poff2, pad = struct.unpack_from("<QQQII", infos, i * 32)
    images.append((addr, poff2))
def path_of(poff2):
    b = lread(CACHE + poff2, 128)
    if not b: return "?"
    e = b.find(b"\x00")
    return b[:e if e >= 0 else 128].decode("ascii", "replace")
def sym_user(linkpc):
    best = None
    for addr, poff2 in images:
        if addr <= linkpc and (best is None or addr > best[0]): best = (addr, poff2)
    if best: return f"{path_of(best[1])} +{linkpc - best[0]:#x}"
    return "?"
print("\nsymbolized (link-time):")
for label, rpc in (("aueb pc", regs["pc"]), ("aueb lr", lr)):
    print(f"  {label}: {rpc - SLIDE:#x} -> {sym_user(rpc - SLIDE)}")
