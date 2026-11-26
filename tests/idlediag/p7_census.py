"""Phase 7: full thread census of an EARLY (wedge-forming) dump.
Prints every thread (id, name, wait_event, waitq, turnstile, state),
highlights IOConfigThreads, reads the IOKit job globals, and runs two
[9c]-specific searches that do not depend on the record census:
(1) thread-zone signature scan for *(p+0x498)==0x9c with a valid stack;
(2) heap IOConfigThread_'gfx' name-string -> thread via +0x7D8.
Usage: python3 p7_census.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, census_threads, thread_info  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva
d = ctx.d

# IOKit job globals (link cluster 0xA7D4550, slide constant across runs;
# runtime VA below; statics live in the physmap-static range).
BASE = 0xFFFFFE0022A88550
vals = {}
for off in (0x00, 0x04, 0x08, 0x0C):
    raw = d.read_pa(BASE - 0xFFFFFDFFAC000000 + off, 4)
    vals[off] = struct.unpack('<I', raw)[0]
print(f'job globals: +0x00={vals[0]} +0x04={vals[4]} '
      f'gNumConfigThreads(+0x08)={vals[8]} gHigh(+0x0C)={vals[12]}')

threads = census_threads(ctx)
print(f'census: {len(threads)} threads')
infos = {}
for tva in sorted(threads):
    ti = thread_info(ctx, tva)
    if ti is None:
        continue
    infos[tva] = ti
    tag = ' <== CONFIG' if ti['name'] and 'IOConfigThread' in ti['name'] else ''
    print(f'  {tva:#x} id={ti["id"]:#06x} name={ti["name"]!r} '
          f'wait={ti["wait_event"]:#x} waitq={Q(tva + 0x28):#x} '
          f'ts={Q(tva + 0x30):#x} state=0x{ti["state_byte"]:02x}{tag}')

print('\n--- [9c] thread-zone signature scan ---')
# Thread-zone range derived from THIS dump's census (per-boot heap layout
# differs; the phase-6 hardcoded range missed this boot's zone).
tvas = sorted(infos)
zone_lo = tvas[0] & ~0xFFFFFFF
zone_hi = (tvas[-1] | 0xFFFFFFF) + 1
print(f'  thread zone derived: {zone_lo:#x}..{zone_hi:#x}')
found = 0
for sva, spa, ln in ctx.segs:
    if not (zone_lo <= sva < zone_hi):
        continue
    if not (0x70000000 <= spa and spa + ln <= 0xB0000000):
        continue
    raw = d.read_pa(spa, ln)
    for off in range(0, ln - 0x500, 8):
        if struct.unpack_from('<Q', raw, off + 0x498)[0] == 0x9c:
            tva = sva + off
            st = struct.unpack_from('<Q', raw, off + 0xE8)[0]
            if 0xFFFFFE0000000000 <= st <= 0xFFFFFEFFFFFFFFFF:
                ti = thread_info(ctx, tva)
                print(f'  candidate {tva:#x} stack={st:#x} '
                      f'name={ti["name"]!r} wait={ti["wait_event"]:#x} '
                      f'waitq={Q(tva + 0x28):#x}')
                found += 1
print(f'  {found} candidates')

print('\n--- heap IOConfigThread_ name roster ---')
pat = b"IOConfigThread_'"
by_name_ptr = {}
for tva in infos:
    np = Q(tva + 0x7D8)
    if np:
        by_name_ptr[np] = tva
seen = set()
for sva, spa, ln in ctx.segs:
    if ln > (1 << 28):
        continue
    if not (0x70000000 <= spa and spa + ln <= 0xB0000000):
        continue  # MMIO-mapped segment, not in the DRAM dump file
    raw = d.read_pa(spa, ln)
    idx = 0
    while True:
        j = raw.find(pat, idx)
        if j < 0:
            break
        idx = j + 1
        nva = sva + j
        if nva <= 0xFFFFFE2000000000 or nva in seen:
            continue
        seen.add(nva)
        s = ctx.read_cstr(nva, 64)
        tva = by_name_ptr.get(nva)
        extra = ''
        if tva:
            ti = infos[tva]
            extra = (f' -> thread {tva:#x} id={ti["id"]:#x} '
                     f'wait={ti["wait_event"]:#x}')
        print(f'  {nva:#x} {s!r}{extra}')
