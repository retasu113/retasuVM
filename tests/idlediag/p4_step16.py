"""Phase 4 step 16: (a) config-thread census by thread_id (+0x498);
(b) FP-walk from the saved context (thread+0x148 -> stack spot);
(c) dump the +0x018 wait-event targets.
"""
import bisect
import json
import struct
import sys

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

# ---- (a) thread census by id: every record field -> candidate thread ----
pat = struct.pack('<Q', TASK_VA)
hits = []
i = data.find(pat)
while i != -1:
    if i % 8 == 0:
        hits.append(i)
    i = data.find(pat, i + 1)

cands = set()
for h in hits:
    rec_pa = h + DRAM
    raw = d.read_pa(rec_pa, 0x120)
    for foff in range(0, 0x120, 8):
        y = struct.unpack_from('<Q', raw, foff)[0]
        if 0xFFFFFE0000000000 <= y <= 0xFFFFFEFFFFFFFFFF:
            cands.add(y)
print(f'{len(cands)} thread candidates from record fields')

WANT = {0xD4: 'Container', 0xD3: 'iBootSystemContainer',
        0xD5: 'RecoveryOSContainer', 0x7C: 'IOResources',
        0xE2: 'AppleAPFSMedia(a)', 0xE3: 'AppleAPFSMedia(b)',
        0xEA: 'AppleAPFSMedia(c)', 0x103: 'AppleAPFSMedia(d)',
        0x10B: 'AppleAPFSMedia(e)', 0xF1: 'IOTimeSyncRootService',
        0xF3: 'AppleUSBHostResources'}
found = {}
for y in cands:
    tid = Qva(y + 0x498)
    if tid in WANT:
        nm = read_cstr(Qva(y + 0x7D8) or 0)
        found[tid] = (y, nm)
        print(f'  id {tid:#x} ({WANT[tid]}): thread {y:#x} name {nm!r}')

# ---- (b)+(c) deep dive ----
TARGETS = {}
for tid, (y, nm) in found.items():
    TARGETS[f'{WANT[tid]} id={tid:#x}'] = y
TARGETS.setdefault('IOResources cfg id=0x7c', 0xFFFFFE239BF24838)
TARGETS.setdefault('AppleAPFSMedia cfg id=0xe2', 0xFFFFFE239BDEB010)

TEXT_LO, TEXT_HI = 0xFFFFFE001E000000, 0xFFFFFE0023400000
for label, tva in TARGETS.items():
    print(f'\n===== {label} thread {tva:#x} =====')
    we = Qva(tva + 0x018)
    print(f'  wait_event candidate (+0x018) = {we if we is None else hex(we)}')
    if we:
        wpa = pa_of(we)
        if wpa:
            raw = d.read_pa(wpa, 0x80)
            for off in range(0, 0x80, 8):
                v = struct.unpack_from('<Q', raw, off)[0]
                if v:
                    note = ''
                    if TEXT_LO <= v < TEXT_HI:
                        note = f'  ; {sym(v)}'
                    print(f'    waitobj+{off:#04x}: {v:#018x}{note}')
    stack_va = Qva(tva + 0xE8)
    ctx = Qva(tva + 0x148)
    print(f'  stack {stack_va:#x} saved-ctx ptr (+0x148) = {ctx:#x}')
    if stack_va and ctx and stack_va <= ctx < stack_va + 0x4000:
        spa = pa_of(stack_va)
        sraw = d.read_pa(spa, 0x4000)
        off = ctx - stack_va
        print(f'  FP-walk from stack+{off:#x}:')
        seen = set()
        for depth in range(20):
            if off in seen or not (0 <= off < 0x4000 - 16):
                break
            seen.add(off)
            fp = struct.unpack_from('<Q', sraw, off)[0]
            lr = struct.unpack_from('<Q', sraw, off + 8)[0]
            print(f'    [{depth}] fp={fp:#x} lr={lr:#x} -> {sym(lr)}')
            if not (stack_va <= fp < stack_va + 0x4000):
                break
            off = fp - stack_va
