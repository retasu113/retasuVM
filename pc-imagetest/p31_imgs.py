import struct, sys
sys.path.insert(0, ".")
from p27_dump import Dump as RawDump, walk as uwalk
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
LROOT = 0x80824000
CACHE = 0x18A520000
LINK = 0x180000000
hdr = uread(LROOT, CACHE, 0x400)
moff, mcnt = struct.unpack_from("<II", hdr, 16)
print(f"mappings: off={moff:#x} cnt={mcnt}")
for i in range(mcnt):
    addr, size, foff = struct.unpack_from("<QQQ", hdr, moff + i * 32)
    print(f"  map{i}: addr={addr:#x} size={size:#x} fileoff={foff:#x}")
imgs = []
va = CACHE
end = CACHE + 0x340000
while va < end:
    b = uread(LROOT, va, 4)
    if b and struct.unpack("<I", b)[0] == 0xFEEDFACF:
        page = uread(LROOT, va, 0x1000)
        ncmds = struct.unpack_from("<I", page, 16)[0]
        off = 32; name = "?"; textbase = None
        for _ in range(min(ncmds, 200)):
            if off + 8 > 0x1000: break
            cmd, cmdsize = struct.unpack_from("<II", page, off)
            if cmdsize < 8 or cmdsize > 0x1000: break
            if cmd == 0xD:  # LC_ID_DYLIB
                noff = struct.unpack_from("<I", page, off + 8)[0]
                e = page.find(b"\x00", off + noff)
                name = page[off + noff:e].decode("ascii", "replace")
            if cmd == 0x19:
                segname = page[off + 8:off + 24].rstrip(b"\x00").decode("ascii", "replace")
                if segname == "__TEXT":
                    textbase = struct.unpack_from("<Q", page, off + 24)[0]
            off += cmdsize
            if cmdsize == 0: break
        link = va - 0xA520000
        imgs.append((link, name))
        print(f"img @link {link:#x} (hdr textbase {textbase:#x}): {name}")
    va += 0x4000
def sym_user(linkpc):
    best = None
    for base, name in imgs:
        if base <= linkpc and (best is None or base > best[0]): best = (base, name)
    return f"{best[1]} +{linkpc - best[0]:#x}" if best else "?"
print()
for lbl, lk in (("pc", 0x1800a9284), ("lr", 0x1800a927c), ("f0", 0x180096ff4), ("f1", 0x180096ee0),
                ("f4", 0x1802d585c), ("f5", 0x1802bea28), ("f7", 0x180083900), ("f8", 0x1800e43ec),
                ("f9", 0x1800ef454), ("f10-15", 0x1800ef400), ("f16", 0x1800f3c88), ("f17", 0x1800ef77c),
                ("f18", 0x180113144), ("f19", 0x180107f9c), ("f20", 0x180107a80), ("f21", 0x180187d2c),
                ("f22", 0x18016d668), ("f24", 0x1800eeefc), ("f25", 0x18012b89c), ("f26", 0x18014b5cc), ("f27", 0x180148358)):
    print(f"  {lbl}: {lk:#x} -> {sym_user(lk)}")
