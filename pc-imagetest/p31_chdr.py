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
hdr = uread(LROOT, CACHE, 0x100)
print("magic:", hdr[:16])
for off in range(16, 0x60, 4):
    print(f"  u32@{off:#x} = {struct.unpack_from('<I', hdr, off)[0]:#x}")
