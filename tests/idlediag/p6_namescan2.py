"""Phase 6: fast config-thread scan via heap name strings.

- Collect "IOConfigThread_'<name>'" string instances; keep only HEAP
  instances (those with a non-physmap VA alias = actual thread-name
  allocations, as opposed to static catalogue copies).
- One regex pass over all mapped non-physmap segments <=256MB for
  qwords equal to any heap alias; candidate thread = hitVA - 0x7D8.
- No back-pointer requirement (that is the point); report its status.

Usage: python3 p6_namescan2.py <dump>
"""
import re
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, thread_info, DRAM, OFF  # noqa: E402

dump = sys.argv[1]
ctx = Ctx(dump)
data = open(dump, 'rb').read()
MSGBUF_LO, MSGBUF_HI = 0x76A20000, 0x76A80000

strings = {}
i = data.find(b"IOConfigThread_'")
while i != -1:
    pa = i + DRAM
    if not (MSGBUF_LO <= pa < MSGBUF_HI):
        end = data.find(b'\x00', i, i + 80)
        try:
            s = data[i:end].decode('ascii')
        except UnicodeDecodeError:
            s = None
        if s and s.startswith("IOConfigThread_'") and s.endswith("'"):
            strings.setdefault(s, set()).add(pa)
    i = data.find(b"IOConfigThread_'", i + 1)

alias_owner = {}  # alias VA -> name string
for s, pas in strings.items():
    for pa in pas:
        for av in ctx.va_cands(pa):
            alias_owner[av] = s
print(f'{len(alias_owner)} heap name-string aliases for '
      f'{len(strings)} distinct names', flush=True)

pat = re.compile(b'|'.join(re.escape(struct.pack('<Q', v))
                           for v in alias_owner))
cands = {}
nseg = 0
for sva, spa, ln in ctx.segs:
    if ln > (1 << 28):
        continue
    if sva - spa == OFF:  # physmap alias segment: skip (dup coverage)
        continue
    nseg += 1
    chunk = data[spa - DRAM: spa - DRAM + ln]
    for m in pat.finditer(chunk):
        hva = sva + m.start()
        av = struct.unpack('<Q', m.group())[0]
        cands.setdefault(hva - 0x7D8, set()).add(alias_owner[av])
print(f'scanned {nseg} segments; {len(cands)} candidate threads',
      flush=True)

KNOWN_CFG = {0xFFFFFE184A0D3010, 0xFFFFFE184A0CC040, 0xFFFFFE184A482020,
             0xFFFFFE184A48B808, 0xFFFFFE184A48F010, 0xFFFFFE184A47C838}
for tva in sorted(cands):
    ti = thread_info(ctx, tva)
    if ti is None:
        print(f'  cand {tva:#x}: unreadable (names {cands[tva]})')
        continue
    bp = ctx.Qva(tva + 0x3D8)
    bpv = ctx.Qva(bp) if bp else None
    print(f"  thread={tva:#x} id={ti['id']:#x} "
          f"state=0x{ti['state_byte']:02x} wait={ti['wait_event']:#x} "
          f"waitq={ctx.Qva(tva + 0x28):#x} stack={ti['stack_va']:#x} "
          f"name={ti['name']!r} phase5_census={tva in KNOWN_CFG} "
          f"bp_ok={bpv == tva}", flush=True)
