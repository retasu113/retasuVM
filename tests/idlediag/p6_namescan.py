"""Phase 6: find config threads via their name strings, exhaustively.

For every distinct "IOConfigThread_'<name>'" string in the dump (outside
the msgbuf ring), take ALL VA aliases of the string (page-walk aliases
plus the physmap alias), find every qword in the dump equal to any
alias, and treat (hitVA - 0x7D8) as a candidate thread. Report each
candidate's id / wait / waitq / stack / state and whether the phase-4
back-pointer rule validates it.

Usage: python3 p6_namescan.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, census_threads, thread_info, DRAM, OFF  # noqa: E402

dump = sys.argv[1]
ctx = Ctx(dump)
data = open(dump, 'rb').read()
MSGBUF_LO, MSGBUF_HI = 0x76A20000, 0x76A80000

# 1. all config name strings
strings = {}  # name -> set of PAs
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
print(f'{len(strings)} distinct config name strings outside msgbuf:')
for s, pas in sorted(strings.items()):
    print(f'  {s!r}: {len(pas)} instance(s) at '
          f'{[hex(p) for p in sorted(pas)][:4]}')

known = census_threads(ctx)
print(f'\nrecord census: {len(known)} threads')

# 2. for each string, find referrers via every alias
for s, pas in sorted(strings.items()):
    aliases = set()
    for pa in pas:
        aliases.update(ctx.va_cands(pa))
        aliases.add(pa + OFF)
    print(f'\n##### {s!r} aliases: {[hex(a) for a in sorted(aliases)]}')
    hits = {}  # candidate thread VA -> hit VA
    for av in aliases:
        pat = struct.pack('<Q', av)
        j = data.find(pat)
        while j != -1:
            if j % 8 == 0:
                hit_pa = j + DRAM
                for hva in ctx.va_cands(hit_pa):
                    hits[hva - 0x7D8] = hva
                hits[hit_pa + OFF - 0x7D8] = hit_pa + OFF
            j = data.find(pat, j + 1)
    if not hits:
        print('  no referrers found')
        continue
    for tva in sorted(hits):
        ti = thread_info(ctx, tva)
        if ti is None:
            print(f'  cand {tva:#x}: unreadable')
            continue
        bp = ctx.Qva(tva + 0x3D8)
        bpv = ctx.Qva(bp) if bp else None
        print(f"  cand thread={tva:#x} id={ti['id']:#x} "
              f"state=0x{ti['state_byte']:02x} wait={ti['wait_event']:#x} "
              f"waitq={ctx.Qva(tva + 0x28) if True else 0:#x} "
              f"stack={ti['stack_va']:#x} name={ti['name']!r} "
              f"in_record_census={tva in known} "
              f"+0x3D8={bp if bp is None else hex(bp)} "
              f"bp_target={bpv if bpv is None else hex(bpv)}")
