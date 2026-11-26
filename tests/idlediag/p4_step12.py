"""Phase 4 step 12: learn t_task offset from known threads; census v2;
locate the holder of the 'Container' name pointer.
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
OFF = 0xFFFFFDFFAC000000

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
segs_by_pa = sorted(segs, key=lambda s: s[1])
seg_pas = [s[1] for s in segs_by_pa]


def pa_of(va):
    i = bisect.bisect_right(seg_vas, va) - 1
    if i < 0:
        return None
    sva, spa, ln = segs[i]
    return spa + (va - sva) if va < sva + ln else None


def va_candidates(pa):
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


KNOWN = {
    'AppleAPFSMedia': 0xFFFFFE239BDEB010,
    'IOResources': 0xFFFFFE239BF24838,
    'defaults': 0xFFFFFE239BF20838,
}
print('== TASK_VA offsets inside known threads ==')
t_task_off = None
for nm, tva in KNOWN.items():
    tpa = pa_of(tva)
    raw = d.read_pa(tpa, 0x900)
    offs = [o for o in range(0, len(raw) - 8, 8)
            if struct.unpack_from('<Q', raw, o)[0] == TASK_VA]
    print(f'  {nm} thread {tva:#x}: TASK_VA at {offs}')
    if offs:
        t_task_off = offs[0]
print(f't_task offset = {t_task_off if t_task_off is None else hex(t_task_off)}')

# ---- census v2: any record field -> thread candidate, validate by
# t_task at learned offset OR +0x3D8 back-pointer ----
data = open(DUMP, 'rb').read()
pat = struct.pack('<Q', TASK_VA)
hits = []
i = data.find(pat)
while i != -1:
    if i % 8 == 0:
        hits.append(i)
    i = data.find(pat, i + 1)

threads = {}
for h in hits:
    rec_pa = h + DRAM
    rec_vas = va_candidates(rec_pa)
    if not rec_vas:
        continue
    raw = d.read_pa(rec_pa, 0x120)
    for foff in range(0, 0x120, 8):
        y = struct.unpack_from('<Q', raw, foff)[0]
        if not (0xFFFFFE0000000000 <= y <= 0xFFFFFEFFFFFFFFFF):
            continue
        ok = False
        if t_task_off is not None and Qva(y + t_task_off) == TASK_VA:
            ok = True
        if not ok:
            back = Qva(y + 0x3D8)
            if back is not None and back - foff in rec_vas:
                ok = True
        if ok:
            threads[y] = rec_vas[0]
print(f'\ncensus v2: {len(threads)} validated threads')

# ---- who points at the Container name string? ----
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

named = {}
for tva in threads:
    tpa = pa_of(tva)
    raw = d.read_pa(tpa, 0x900)
    for off in range(0, len(raw) - 8, 8):
        v = struct.unpack_from('<Q', raw, off)[0]
        if v in names:
            named[tva] = (names[v], off)
            break
print(f'{len(named)} named threads in census v2:')
for tva, (nm, off) in sorted(named.items(), key=lambda kv: kv[1][0]):
    print(f'  {nm}: thread={tva:#x} nameptr@{off:#x}')

# Container name VAs and their holders
cont_vas = [va for va, nm in names.items() if nm == "IOConfigThread_'Container'"]
print(f'\nContainer name string VAs: {[hex(v) for v in cont_vas]}')
for cva in cont_vas:
    p = struct.pack('<Q', cva)
    j = data.find(p)
    while j != -1:
        holder_pa = j + DRAM
        hvas = va_candidates(holder_pa)
        print(f'  ptr at PA {holder_pa:#x} VA candidates '
              f'{[hex(v) for v in hvas]}')
        j = data.find(p, j + 1)
