"""Phase 8: dump-wide scan only — locate stacks containing return
addresses into _external_module_resources / AppleAPFSContainer::start
(the holder signature), without any thread enumeration.
Usage: python3 p8_wscan.py <dump>
"""
import re
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, make_sym, SLIDE  # noqa: E402

ctx = Ctx(sys.argv[1])
bracket = make_sym()
EXT_FN = (0xFFFFFE0009FD19FC + SLIDE, 0xFFFFFE0009FD1B08 + SLIDE)
CONT_START = (0xFFFFFE0009FD18DC + SLIDE, 0xFFFFFE0009FD19FC + SLIDE)
WAIT_RET = 0xFFFFFE0009FD1A4C + SLIDE

pat = re.compile(rb'(?=(.[\x58-\x5c]\x28\x22\x00\xfe\xff\xff))')
data = open(sys.argv[1], 'rb').read()
hits = []
for m in pat.finditer(data):
    pos = m.start()
    if pos % 8:
        continue
    v = struct.unpack('<Q', m.group(1))[0]
    if v == WAIT_RET or EXT_FN[0] <= v < EXT_FN[1] or CONT_START[0] <= v < CONT_START[1]:
        pa = pos + 0x70000000
        vas = ctx.va_cands(pa)
        hits.append((v, pa, vas))
for v, pa, vas in sorted(hits):
    print(f'  {v:#x} ({bracket(v)})  PA {pa:#x}  VAs {[hex(x) for x in (vas or [])]}')
print(f'total {len(hits)} hits; WAIT_RET present: '
      f'{any(v == WAIT_RET for v, _, _ in hits)}')
