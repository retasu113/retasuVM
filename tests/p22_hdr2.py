#!/usr/bin/env python3
"""Phase 22 step 2: dump raw dyld cache header qwords for both candidates;
find all dyld_v1 occurrences in the dump."""
import struct, re
D = "/home/retasu/retasuvm/inst/imagetest/home_p23/dram_fpend_cycle1.bin"
f = open(D, "rb")
data = f.read()
print(f"dump size {len(data)}")
hits = [m.start() for m in re.finditer(b"dyld_v1", data)]
print(f"'dyld_v1' hits: {len(hits)}")
for h in hits:
    print(f"  file off {h:#x} -> PA {h + 0x70000000:#x}")

for pa_addr in (0x81344000, 0x81fb4000):
    off = pa_addr - 0x70000000
    b = data[off:off + 0x400]
    print(f"\n=== header at PA {pa_addr:#x} (file off {off:#x}) ===")
    print(f"magic: {b[:16]!r}")
    for i in range(0, 0x100, 8):
        q = struct.unpack_from("<Q", b, i)[0]
        print(f"  +{i:#05x}: {q:#018x} ({q})")
    print("  mapping area raw qwords (+0x228..+0x328):")
    for i in range(0x228, 0x328, 8):
        q = struct.unpack_from("<Q", b, i)[0]
        print(f"  +{i:#05x}: {q:#018x}")
