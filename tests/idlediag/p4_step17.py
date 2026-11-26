"""Phase 4 step 17: (a) census of +0x018 wait_event values across all
thread candidates; who waits on 0xFFFFFE2FEA093818?
(b) dump that object + find its holders; (c) stack-top context dump
for two config threads.
"""
import bisect
import json
import struct
import sys
from collections import Counter

sys.path.insert(0, '.')
from p4_lib import Dump

D1 = '/home/retasu/retasuvm/inst/imagetest/home_idlediag/dram_idlediag1.bin'
d = Dump(D1)
ROOT = 0x77B98000
TASK_VA = 0xFFFFFE249E0FC0A8
OA = 0x0000FFFFFFFFC000
DRAM = 0x70000000
OFF = 0xFFFFFDFFAC000000
SLIDE = 0x182B4000
GATE = 0xFFFFFE2FEA093818

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
    if va < sva + ln:
        pa = spa + (va - sva)
        if DRAM <= pa < DRAM + (1 << 32):
            return pa
    return None


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


def Qva(va):
    pa = pa_of(va)
    return None if pa is None else d.u64_pa(pa)


def read_cstr(va, maxlen=80):
    pa = pa_of(va)
    if pa is None:
        return None
    raw = d.read_pa(pa, maxlen)
    end = raw.find(b'\x00')
    try:
        return raw[:end if end >= 0 else maxlen].decode('ascii')
    except UnicodeDecodeError:
        return None


data = open(D1, 'rb').read()
pat = struct.pack('<Q', TASK_VA)
hits = []
i = data.find(pat)
while i != -1:
    if i % 8 == 0:
        hits.append(i)
    i = data.find(pat, i + 1)
cands = set()
for h in hits:
    raw = d.read_pa(h + DRAM, 0x120)
    for foff in range(0, 0x120, 8):
        y = struct.unpack_from('<Q', raw, foff)[0]
        if 0xFFFFFE0000000000 <= y <= 0xFFFFFEFFFFFFFFFF:
            cands.add(y)

waits = Counter()
gate_waiters = []
for y in cands:
    we = Qva(y + 0x018)
    if we:
        waits[we] += 1
        if we == GATE:
            tid = Qva(y + 0x498)
            nm = read_cstr(Qva(y + 0x7D8) or 0)
            gate_waiters.append((y, tid, nm))
print('top wait_event values:')
for we, n in waits.most_common(10):
    print(f'  {we:#x}: {n} threads  ({sym(we)})')
print(f'\nthreads waiting on GATE {GATE:#x}: {len(gate_waiters)}')
for y, tid, nm in gate_waiters:
    print(f'  thread {y:#x} id={tid if tid is None else hex(tid)} name={nm!r}')

print(f'\n== GATE object dump ({GATE:#x}) ==')
gpa = pa_of(GATE)
raw = d.read_pa(gpa, 0x200)
for off in range(0, 0x200, 8):
    v = struct.unpack_from('<Q', raw, off)[0]
    if v:
        print(f'  +{off:#05x}: {v:#018x}')

print('\n== holders of GATE pointer ==')
p = struct.pack('<Q', GATE)
j = data.find(p)
while j != -1:
    hpa = j + DRAM
    print(f'  PA {hpa:#x} VA cands {[hex(v) for v in va_cands(hpa)]}')
    j = data.find(p, j + 1)

print('\n== stack tops ==')
for label, tva in [('APFSMedia(a) 0xe2', 0xFFFFFE239BDEB010),
                   ('IOResources 0x7c', 0xFFFFFE239BF24838)]:
    stack_va = Qva(tva + 0xE8)
    spa = pa_of(stack_va)
    sraw = d.read_pa(spa, 0x4000)
    print(f'-- {label} stack {stack_va:#x}, qwords 0x3E80..0x4000:')
    for off in range(0x3E80, 0x4000, 8):
        v = struct.unpack_from('<Q', sraw, off)[0]
        if v:
            note = f'  ; {sym(v)}' if 0xFFFFFE001E000000 <= v < 0xFFFFFE0023400000 else ''
            print(f'   +{off:#x}: {v:#018x}{note}')
