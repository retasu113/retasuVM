"""Phase 4 step 14: full thread roster with names read directly from
thread+0x7D8 name pointers; FP-walk the config threads' stacks.
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
    if va < sva + ln:
        pa = spa + (va - sva)
        if DRAM <= pa < DRAM + (1 << 32):
            return pa
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


def read_cstr(va, maxlen=80):
    pa = pa_of(va)
    if pa is None:
        return None
    raw = d.read_pa(pa, maxlen)
    end = raw.find(b'\x00')
    if end == -1:
        end = maxlen
    try:
        return raw[:end].decode('ascii')
    except UnicodeDecodeError:
        return None


data = open(DUMP1, 'rb').read()

# ---- census: records -> threads via +0x3D8 back-pointer ----
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
    for foff in (0xF8, 0x38):
        y = struct.unpack_from('<Q', raw, foff)[0]
        if not (0xFFFFFE0000000000 <= y <= 0xFFFFFEFFFFFFFFFF):
            continue
        back = Qva(y + 0x3D8)
        if back is not None and back - foff in rec_vas:
            threads[y] = back - foff
print(f'{len(threads)} validated threads')

# ---- roster with names ----
roster = {}
for tva in threads:
    nptr = Qva(tva + 0x7D8)
    nm = read_cstr(nptr) if nptr else None
    roster[tva] = nm
print('\n== roster (named threads) ==')
for tva, nm in sorted(roster.items(), key=lambda kv: (kv[1] or '', kv[0])):
    if nm:
        print(f'  {tva:#x}: {nm!r}')

# ---- FP-walk config threads ----
TEXT_LO, TEXT_HI = 0xFFFFFE001E000000, 0xFFFFFE0023400000
targets = {tva: nm for tva, nm in roster.items()
           if nm and 'IOConfigThread' in nm}
print(f'\n== FP-walks for {len(targets)} IOConfigThreads ==')
for tva, nm in sorted(targets.items(), key=lambda kv: kv[1]):
    stack_va = Qva(tva + 0xE8)
    print(f'\n-- {nm} thread {tva:#x} stack {stack_va:#x}')
    if stack_va is None:
        continue
    spa = pa_of(stack_va)
    if spa is None:
        print('   stack VA does not map')
        continue
    sraw = d.read_pa(spa, 0x4000)
    # find FP-chain head: scan top 0x1000 for (fp in stack, lr in text)
    head = None
    for off in range(0x4000 - 0x1000, 0x4000 - 16, 8):
        fp = struct.unpack_from('<Q', sraw, off)[0]
        lr = struct.unpack_from('<Q', sraw, off + 8)[0]
        if stack_va <= fp < stack_va + 0x4000 and TEXT_LO <= lr < TEXT_HI:
            head = off
            break
    if head is None:
        print('   no FP chain head found in top 4K')
        continue
    print(f'   chain head at stack+{head:#x}:')
    off = head
    seen = set()
    for depth in range(24):
        if off in seen or not (0 <= off < 0x4000 - 16):
            break
        seen.add(off)
        fp = struct.unpack_from('<Q', sraw, off)[0]
        lr = struct.unpack_from('<Q', sraw, off + 8)[0]
        print(f'     [{depth}] lr={lr:#x} -> {sym(lr)}')
        if not (stack_va <= fp < stack_va + 0x4000):
            break
        off = fp - stack_va
