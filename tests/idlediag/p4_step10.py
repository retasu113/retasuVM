"""Phase 4 step 10: study the name-table region around PA 0x78c6c440."""
import re
import struct
import sys

sys.path.insert(0, '.')
from p4_lib import Dump

DUMP = '/home/retasu/retasuvm/inst/imagetest/home_idlediag/dram_idlediag1.bin'
d = Dump(DUMP)

BASE = 0x78C6C000
raw = d.read_pa(BASE, 0x3000)
# all printable strings >= 6 chars with offsets
for m in re.finditer(rb'[\x20-\x7e]{6,}', raw):
    print(f'str @{BASE + m.start():#x} (+{m.start():#x}): {m.group()!r}')
print('\nnonzero qwords:')
for off in range(0, len(raw), 8):
    v = struct.unpack_from('<Q', raw, off)[0]
    if v and not (0x2020202020202020 <= v <= 0x7E7E7E7E7E7E7E7E):
        print(f'  {BASE + off:#x} (+{off:#05x}): {v:#018x}')
