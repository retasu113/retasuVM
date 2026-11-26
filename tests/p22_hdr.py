#!/usr/bin/env python3
"""Phase 22 step 1: verify dyld cache header candidates + inspect the
kernel-stack table structure from phase 21."""
import struct
D = "/home/retasu/retasuvm/inst/imagetest/home_p23/dram_fpend_cycle1.bin"
f = open(D, "rb")

def read_at_pa(pa_addr, n):
    f.seek(pa_addr - 0x70000000)
    return f.read(n)

for pa_addr in (0x81344000, 0x81fb4000):
    b = read_at_pa(pa_addr, 4096)
    print(f"PA {pa_addr:#x}: magic={b[:16]!r}")
    if b[:7] == b"dyld_v1":
        mappingOffset, mappingCount, imagesOffset, imagesCount = struct.unpack_from("<IIII", b, 16)
        print(f"  mappingOffset={mappingOffset:#x} mappingCount={mappingCount} imagesOffset={imagesOffset:#x} imagesCount={imagesCount}")
        for i in range(mappingCount):
            addr, foff, size, maxp, initp = struct.unpack_from("<QQQII", b, mappingOffset + i * 32)
            print(f"  map[{i}]: addr={addr:#x} fileOff={foff:#x} size={size:#x} maxProt={maxp} initProt={initp}")
    print()

# structure at VA 0xFFFFFE0024A3A770 -> PA 0x77fde770 (per phase 21)
b = read_at_pa(0x77fde770, 0x400)
print("struct at PA 0x77fde770 (VA 0xFFFFFE0024A3A770), 0x30-byte entries:")
for i in range(10):
    e = b[i * 0x30:(i + 1) * 0x30]
    qs = struct.unpack("<6Q", e)
    print(f"  [{i}] " + " ".join(f"{q:#018x}" for q in qs))
