"""Phase 4 step 11: census all A/B records -> validated thread structs,
then identify the IOConfigThreads by their name-string pointers.

Validation: thread+0x3D8 == record_VA + (offset of the thread-pointer
field in the record)  [observed for both A (+0xF8) and B (+0x38)].
Names: string-pool copies of "IOConfigThread_'<svc>'" outside the msgbuf
ring; a thread is identified if thread[0..0x900) points at one.
"""
import bisect
import struct
import sys

sys.path.insert(0, '.')
from p4_lib import Dump

DUMP = '/home/retasu/retasuvm/inst/imagetest/home_idlediag/dram_idlediag1.bin'
d = Dump(DUMP)
ROOT = 0x77B98000
TASK_VA = 0xFFFFFE249E0FC0A8
OA = 0x0000FFFFFFFFC000
DRAM = 0x70000000

# ---- segment enumeration -> sorted (va, pa, len) ----
segs = []
for l1 in range(2048):
    e1 = d.u64_pa(ROOT + l1 * 8)
    if not e1:
        continue
    va1 = (0xFFFF << 48) | (1 << 47) | (l1 << 36)
    if e1 & 3 == 1:
        segs.append((va1, e1 & 0x0000FFFFF0000000, 1 << 36))
        continue
    if e1 & 3 != 3:
        continue
    l2tab = e1 & OA
    for l2 in range(2048):
        e2 = d.u64_pa(l2tab + l2 * 8)
        if not e2:
            continue
        va2 = va1 | (l2 << 25)
        if e2 & 3 == 1:
            segs.append((va2, e2 & 0x0000FFFFFFE00000, 1 << 25))
            continue
        if e2 & 3 != 3:
            continue
        l3tab = e2 & OA
        for l3 in range(2048):
            e3 = d.u64_pa(l3tab + l3 * 8)
            if e3 and e3 & 3 == 3:
                segs.append((va2 | (l3 << 14), e3 & OA, 1 << 14))
segs.sort()
seg_vas = [s[0] for s in segs]
print(f'{len(segs)} segments')


def pa_of(va):
    i = bisect.bisect_right(seg_vas, va) - 1
    if i < 0:
        return None
    sva, spa, ln = segs[i]
    if va < sva + ln:
        return spa + (va - sva)
    return None


OFF = 0xFFFFFDFFAC000000
segs_by_pa = sorted(segs, key=lambda s: s[1])
seg_pas = [s[1] for s in segs_by_pa]


def va_candidates(pa):
    """All VAs mapping to pa, excluding the physmap alias (pa + OFF)."""
    out = []
    i = bisect.bisect_right(seg_pas, pa) - 1
    while i >= 0 and segs_by_pa[i][1] + segs_by_pa[i][2] > pa:
        sva, spa, ln = segs_by_pa[i]
        if spa <= pa < spa + ln:
            va = sva + (pa - spa)
            if va != pa + OFF:
                out.append(va)
        i -= 1
    return out


def Qva(va):
    pa = pa_of(va)
    return None if pa is None else d.u64_pa(pa)


# ---- name strings ----
data = open(DUMP, 'rb').read()
names = {}
i = data.find(b"IOConfigThread_'")
while i != -1:
    pa = i + DRAM
    if not (0x76A20000 <= pa < 0x76A80000):
        end = data.find(b"'", i + 16)
        nm = data[i:end + 1].decode('ascii', 'replace')
        for va in va_candidates(pa):
            names[va] = nm
    i = data.find(b"IOConfigThread_'", i + 1)
print(f'{len(names)} stored config-thread name strings')

# ---- census records: qwords == TASK_VA ----
pat = struct.pack('<Q', TASK_VA)
hits = []
i = data.find(pat)
while i != -1:
    if i % 8 == 0:
        hits.append(i)
    i = data.find(pat, i + 1)
print(f'{len(hits)} TASK_VA qwords')

threads = {}   # thread_va -> (record_va, kind)
for h in hits:
    rec_pa = h + DRAM
    for rec_va in va_candidates(rec_pa):
        for kind, yoff in [('A', 0xF8), ('B', 0x38)]:
            y = d.u64_pa(rec_pa + yoff)
            if not (0xFFFFFE0000000000 <= y <= 0xFFFFFEFFFFFFFFFF):
                continue
            back = Qva(y + 0x3D8)
            if back == rec_va + yoff:
                threads[y] = (rec_va, kind)
print(f'{len(threads)} validated thread structs')

# ---- identify named threads ----
named = []
for tva in threads:
    tpa = pa_of(tva)
    raw = d.read_pa(tpa, 0x900)
    for off in range(0, len(raw) - 8, 8):
        v = struct.unpack_from('<Q', raw, off)[0]
        if v in names:
            named.append((names[v], tva, off))
            break
print(f'\n{len(named)} named IOConfigThreads:')
for nm, tva, off in sorted(named):
    rec_va, kind = threads[tva]
    print(f'  {nm}: thread={tva:#x} nameptr@{off:#x} record={rec_va:#x} ({kind})')
