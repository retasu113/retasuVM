"""Phase 4 step 13: (a) find holders of the Container name pointer;
(b) deep-dive the named config threads: field map + kernel-stack
return addresses, symbolicated.
"""
import bisect
import json
import struct
import sys

sys.path.insert(0, '.')
from p4_lib import Dump

DUMP1 = '/home/retasu/retasuvm/inst/imagetest/home_idlediag/dram_idlediag1.bin'
d = Dump(DUMP1)
ROOT = 0x77B98000
TASK_VA = 0xFFFFFE249E0FC0A8
OA = 0x0000FFFFFFFFC000
DRAM = 0x70000000
OFF = 0xFFFFFDFFAC000000
SLIDE = 0x182B4000

syms = sorted(json.load(open('kc_syms_mine.json'))['syms'])
saddrs = [s[0] for s in syms]


def sym(rtva):
    link = rtva - SLIDE
    i = bisect.bisect_right(saddrs, link) - 1
    if i >= 0:
        return f'{syms[i][1]} +{link - syms[i][0]:#x}'
    return '?'


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
    if va < sva + ln and DRAM <= spa + (va - sva) < DRAM + (1 << 32):
        return spa + (va - sva)
    return None


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


data = open(DUMP1, 'rb').read()

# ---------- (a) Container name holders ----------
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

cont_vas = [va for va, nm in names.items()
            if nm == "IOConfigThread_'Container'"]
print(f'Container name VAs: {[hex(v) for v in cont_vas]}')
for cva in cont_vas:
    p = struct.pack('<Q', cva)
    j = data.find(p)
    while j != -1:
        holder_pa = j + DRAM
        print(f'  name ptr stored at PA {holder_pa:#x}, '
              f'holder VA candidates {[hex(v) for v in va_candidates(holder_pa)]}')
        j = data.find(p, j + 1)

# ---------- (b) named thread deep-dive ----------
NAMED = {
    'AppleAPFSMedia': 0xFFFFFE239BDEB010,
    'AppleDiskImagesController': 0xFFFFFE239BDE1828,
    'AppleVirtIOPCITransport': 0xFFFFFE239BDE9030,
    'IOResources': 0xFFFFFE239BF24838,
    'IOSurfaceParavirtMapperDevice': 0xFFFFFE239BF27010,
    'defaults': 0xFFFFFE239BF20838,
}
TEXT_LO, TEXT_HI = 0xFFFFFE001D000000, 0xFFFFFE0024000000
for nm, tva in NAMED.items():
    tpa = pa_of(tva)
    print(f'\n===== {nm} thread {tva:#x} (PA {tpa:#x}) =====')
    raw = d.read_pa(tpa, 0x900)
    stack_va = struct.unpack_from('<Q', raw, 0xE8)[0]
    print(f'  +0xD0 (main?) = {struct.unpack_from("<Q", raw, 0xD0)[0]:#x} '
          f'-> {sym(struct.unpack_from("<Q", raw, 0xD0)[0])}')
    print(f'  +0xE8 (stack?) = {stack_va:#x}')
    # stack return addresses: scan the 16K stack page(s)
    spa = pa_of(stack_va)
    if spa:
        sraw = d.read_pa(spa & ~0x3FFF, 0x4000)
        rets = []
        for off in range(0, len(sraw) - 8, 8):
            v = struct.unpack_from('<Q', sraw, off)[0]
            if TEXT_LO <= v < TEXT_HI:
                rets.append((off, v))
        print(f'  stack page has {len(rets)} text-range qwords; top 20:')
        for off, v in rets[:20]:
            print(f'    stack+{off:#05x}: {v:#x} -> {sym(v)}')
