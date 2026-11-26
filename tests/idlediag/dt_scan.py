#!/usr/bin/env python3
"""Scan a DRAM dump for Apple-format device-tree properties.

Apple DT binary format: node = u32 nProps, u32 nChildren, then props,
then children. Property = char name[32], u32 length, value padded to 4.
An `interrupts` property in the AIC encoding holds 3 u32 cells per
interrupt: (type, number, flags); type 0 = SPI. We look for SPI 19
(INTID 51) and report every interrupts property found, with nearby
property names for node context.

Usage: dt_scan.py <dump.bin>
"""
import re
import struct
import sys

data = open(sys.argv[1], "rb").read()
print(f"dump size {len(data)}")

NAME = b"interrupts" + b"\x00" * 22  # 32-byte property name field
hits = [m.start() for m in re.finditer(re.escape(NAME), data)]
print(f"'interrupts' property-name hits: {len(hits)}")

for h in hits:
    ln = struct.unpack_from("<I", data, h + 32)[0]
    if ln == 0 or ln > 256 or ln % 4 != 0:
        print(f"  @0x{h:x}: implausible length {ln}, skipped")
        continue
    cells = struct.unpack_from("<%dI" % (ln // 4), data, h + 36)
    trips = [cells[i:i + 3] for i in range(0, len(cells) - 2, 3)]
    mark = "  <<<< SPI 19" if any(t[0] == 0 and t[1] == 19 for t in trips) else ""
    print(f"  @0x{h:x}: len={ln} cells={cells} triples={trips}{mark}")
    # Context: printable strings in the 512 B before this property
    # (sibling property names / the node's 'name' value live nearby).
    ctx = data[max(0, h - 512):h]
    strs = re.findall(rb"[\x20-\x7e]{3,}", ctx)
    print(f"      preceding strings: {[s.decode() for s in strs[-14:]]}")

# Also census all (0, N, flags) triples anywhere they appear as an
# interrupts-shaped value right after any 32-byte name field ending in
# 'interrupts' with different padding (defensive; same as above).
# And locate 'device-tree' root name strings for orientation.
for probe in (b"device-tree", b"chosen", b"arm-io", b"aic", b"virtio",
              b"product", b"compatible"):
    hs = [m.start() for m in re.finditer(re.escape(probe), data)]
    near = [h for h in hs if 0x1E000000 <= h <= 0x20000000]
    print(f"probe {probe!r}: {len(hs)} hits total, {len(near)} in 0x1e000000-0x20000000"
          + (f", first near @0x{near[0]:x}" if near else ""))
