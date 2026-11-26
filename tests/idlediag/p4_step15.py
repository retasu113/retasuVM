"""Phase 4 step 15: locate Container's thread via its name-pool pointer;
dump1/dump2 field diffs for key threads to find stable wait fields.
"""
import bisect
import struct
import sys

sys.path.insert(0, '.')
from p4_lib import Dump

D1 = '/home/retasu/retasuvm/inst/imagetest/home_idlediag/dram_idlediag1.bin'
D2 = '/home/retasu/retasuvm/inst/imagetest/home_idlediag/dram_idlediag2.bin'
d1, d2 = Dump(D1), Dump(D2)
ROOT = 0x77B98000
TASK_VA = 0xFFFFFE249E0FC0A8
OA = 0x0000FFFFFFFFC000
DRAM = 0x70000000
OFF = 0xFFFFFDFFAC000000

segs = []
for l1 in range(2048):
    e1 = d1.u64_pa(ROOT + l1 * 8)
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
        e2 = d1.u64_pa(l2tab + l2 * 8)
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
            e3 = d1.u64_pa(l3tab + l3 * 8)
            if e3 and e3 & 3 == 3:
                segs.append((va2 | (l3 << 14), e3 & OA, 1 << 14))
segs.sort()
seg_vas = [s[0] for s in segs]


def pa_of(va, dd=None):
    dd = dd or d1
    i = bisect.bisect_right(seg_vas, va) - 1
    if i < 0:
        return None
    sva, spa, ln = segs[i]
    if va < sva + ln:
        pa = spa + (va - sva)
        if DRAM <= pa < DRAM + (1 << 32):
            return pa
    return None


def Qva(va, dd=None):
    dd = dd or d1
    pa = pa_of(va, dd)
    return None if pa is None else dd.u64_pa(pa)


data = open(D1, 'rb').read()

# ---- (a) Container thread via name-pool pointer ----
hits = []
i = data.find(b"IOConfigThread_'Container'")
while i != -1:
    hits.append(i + DRAM)
    i = data.find(b"IOConfigThread_'Container'", i + 1)
pool_pas = [p for p in hits
            if not (0x76A20000 <= p < 0x76B00000)]
print(f'Container name hits: {len(hits)}, non-ring PAs: '
      f'{[hex(p) for p in pool_pas]}')
# VA of each pool PA via walk-based reverse: use seg list candidates
segs_by_pa = sorted(segs, key=lambda s: s[1])
seg_pas = [s[1] for s in segs_by_pa]


def va_cands(pa):
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


container_thread = None
for pa in pool_pas:
    for va in va_cands(pa):
        p = struct.pack('<Q', va)
        j = data.find(p)
        while j != -1:
            holder_pa = j + DRAM
            hvas = va_cands(holder_pa)
            print(f'  name VA {va:#x} referenced at PA {holder_pa:#x} '
                  f'holder VAs {[hex(v) for v in hvas]}')
            for hv in hvas:
                if hv - 0x7D8 > 0xFFFFFE0000000000:
                    cand = hv - 0x7D8
                    if Qva(cand + 0x7D8) == va:
                        container_thread = cand
                        print(f'    -> thread candidate {cand:#x} '
                              f'(name ptr at +0x7D8)')
            j = data.find(p, j + 1)
print(f'Container thread: '
      f'{container_thread if container_thread is None else hex(container_thread)}')

# ---- (b) dump1/dump2 diffs ----
TARGETS = {
    'AppleAPFSMedia cfg': 0xFFFFFE239BDEB010,
    'IOResources cfg': 0xFFFFFE239BF24838,
    'idle #0': 0xFFFFFE239BF1B808,
    'IOTimeSyncDaemonService wl': 0xFFFFFE239BD50838,
}
if container_thread:
    TARGETS['Container cfg'] = container_thread
for nm, tva in TARGETS.items():
    pa1, pa2 = pa_of(tva, d1), pa_of(tva, d2)
    print(f'\n===== {nm} thread {tva:#x} =====')
    if pa1 is None or pa2 is None:
        print('  unmapped in a dump')
        continue
    r1 = d1.read_pa(pa1, 0x900)
    r2 = d2.read_pa(pa2, 0x900)
    for off in range(0, 0x900, 8):
        v1 = struct.unpack_from('<Q', r1, off)[0]
        v2 = struct.unpack_from('<Q', r2, off)[0]
        if v1 or v2:
            mark = '  ' if v1 == v2 else ' *'
            print(f'  {mark} +{off:#05x}: {v1:#018x} -> {v2:#018x}')
