#!/usr/bin/env python3
"""Phase 24: verify the launchd pmap identification.
- pa_of / va_cands for the pmap struct PAs.
- TTBR0 field offset inside the launchd pmap struct.
- Cross-check: the two launchd census threads' task->map->pmap.
Usage: p24_pmapverify.py <dump>
"""
import struct
import sys

sys.path.insert(0, ".")
from p5_common import Ctx  # noqa: E402

DUMP = sys.argv[1]
ctx = Ctx(DUMP)
pmap = 0xFFFFFE19480844E0
print(f"launchd pmap VA {pmap:#x} pa_of -> "
      f"{ctx.pa_of(pmap):#x}" if ctx.pa_of(pmap) else "pa_of -> None")
print(f"va_cands(0x78e885f8): {[hex(c) for c in ctx.va_cands(0x78E885F8)]}")
print(f"va_cands(0x78e886f8): {[hex(c) for c in ctx.va_cands(0x78E886F8)]}")
v = ctx.Qva(pmap + 0x100)
print(f"Qva(pmap+0x100) = {v:#x}" if v is not None else "Qva(pmap+0x100) = None")
raw = ctx.read_va(pmap, 0x400)
for o in range(0, 0x400, 8):
    q = struct.unpack_from("<Q", raw, o)[0]
    if q == 0x85BCC000:
        print(f"  TTBR0 0x85bcc000 at pmap+{o:#x}")
    if q == 0xFFFFFE0022A042D0:
        print(f"  _kernel_pmap+0x270 at pmap+{o:#x}")
# kernel pmap for contrast: its TTBR0 field
kp = ctx.pmap_va
kraw = ctx.read_va(kp, 0x400)
print(f"kernel pmap VA {kp:#x}")
for o in range(0, 0x400, 8):
    q = struct.unpack_from("<Q", kraw, o)[0]
    if q == 0x77B98000:
        print(f"  kernel TTBR0 0x77b98000 at kpmap+{o:#x}")
