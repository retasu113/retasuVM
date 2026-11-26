"""Phase-5 common library: derive per-run parameters (TTBR root, kernel_task
VA) from a DRAM dump itself, build the segment map, thread-census helpers.

Reuses the phase-4 validated geometry: 16 KiB granule, TTBR root = L1 table
(index bits [46:36]); physmap OFF valid for the static VA range.
Slide is assumed 0x182B4000 (identical in every run so far) and VERIFIED by
anchor walks before use.
"""
import bisect
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from p4_lib import Dump, walk  # noqa: E402

DRAM = 0x70000000
OA = 0x0000FFFFFFFFC000
OFF = 0xFFFFFDFFAC000000
SLIDE = 0x182B4000

_here = os.path.dirname(os.path.abspath(__file__))
_syms = None


def load_syms():
    global _syms
    if _syms is None:
        for cand in (os.path.join(_here, 'kc_syms_mine.json'),
                     'kc_syms_mine.json'):
            if os.path.exists(cand):
                _syms = json.load(open(cand))
                break
    return _syms


def link_of(name):
    for a, n in load_syms()['syms']:
        if n == name:
            return a
    return None


def make_sym():
    syms = sorted(load_syms()['syms'])
    saddrs = [s[0] for s in syms]

    def sym(rtva):
        link = rtva - SLIDE
        i = bisect.bisect_right(saddrs, link) - 1
        if i >= 0:
            return f'{syms[i][1]} +{link - syms[i][0]:#x}'
        return '?'
    return sym


class Ctx:
    def __init__(self, dump_path):
        self.d = Dump(dump_path)
        self.path = dump_path
        # _kernel_pmap var: link VA + slide; the var and the pmap struct are
        # both in the static physmap range, so read them via physmap.
        kp_link = link_of('_kernel_pmap')
        self.kp_var_rt = kp_link + SLIDE
        self.pmap_va = self.d.u64_phys(self.kp_var_rt)
        self.root = self.d.u64_phys(self.pmap_va + 0x08) & 0x0000FFFFFFFFFFFF
        # _kernel_task var -> kernel_task VA (heap pointer, per-run)
        kt_link = link_of('_kernel_task')
        self.task_va = self.d.u64_phys(kt_link + SLIDE)
        self._build_segs()
        self._validate()

    def _build_segs(self):
        d, ROOT = self.d, self.root
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
        self.segs = segs
        self.seg_vas = [s[0] for s in segs]
        self.segs_by_pa = sorted(segs, key=lambda s: s[1])
        self.seg_pas = [s[1] for s in self.segs_by_pa]

    def _validate(self):
        anchors = [(0xFFFFFE0022A22484, 'msgbuf VA'),
                   (0xFFFFFE00201D5E68, 'park PC VA'),
                   (self.kp_var_rt, '_kernel_pmap var')]
        for va, name in anchors:
            got = walk(self.d, self.root, va, 14, 1)
            exp = va - OFF
            status = 'OK' if got == exp else f'MISMATCH got={got} exp={exp}'
            print(f'  anchor {name}: walk={got:#x} {status}')
            if got != exp:
                raise SystemExit(f'anchor validation failed for {name}')

    def pa_of(self, va):
        i = bisect.bisect_right(self.seg_vas, va) - 1
        if i < 0:
            return None
        sva, spa, ln = self.segs[i]
        if va < sva + ln:
            pa = spa + (va - sva)
            if DRAM <= pa < DRAM + (1 << 32):
                return pa
        return None

    def va_cands(self, pa):
        out = []
        i = bisect.bisect_right(self.seg_pas, pa) - 1
        while i >= 0 and self.segs_by_pa[i][1] + self.segs_by_pa[i][2] > pa:
            sva, spa, ln = self.segs_by_pa[i]
            if spa <= pa < spa + ln:
                va = sva + (pa - spa)
                if va != pa + OFF:
                    out.append(va)
            i -= 1
        return out

    def Qva(self, va):
        pa = self.pa_of(va)
        return None if pa is None else self.d.u64_pa(pa)

    def read_va(self, va, size):
        pa = self.pa_of(va)
        return None if pa is None else self.d.read_pa(pa, size)

    def read_cstr(self, va, maxlen=96):
        if not va:
            return None
        raw = self.read_va(va, maxlen)
        if raw is None:
            return None
        end = raw.find(b'\x00')
        try:
            return raw[:end if end >= 0 else maxlen].decode('ascii')
        except UnicodeDecodeError:
            return None


def census_threads(ctx):
    """Phase-4 census: records are structs whose first qword == kernel_task
    VA; a record field (A:+0xF8 / B:+0x38, and in v2 any field) points at a
    thread struct validated by *(thread+0x3D8) == &record_field."""
    d = ctx.d
    data = open(ctx.path, 'rb').read()
    pat = struct.pack('<Q', ctx.task_va)
    hits = []
    i = data.find(pat)
    while i != -1:
        if i % 8 == 0:
            hits.append(i)
        i = data.find(pat, i + 1)
    threads = {}
    for h in hits:
        rec_pa = h + DRAM
        raw = d.read_pa(rec_pa, 0x120)
        for rec_va in ctx.va_cands(rec_pa):
            for foff in range(0, 0x120, 8):
                y = struct.unpack_from('<Q', raw, foff)[0]
                if not (0xFFFFFE0000000000 <= y <= 0xFFFFFEFFFFFFFFFF):
                    continue
                if ctx.Qva(y + 0x3D8) == rec_va + foff:
                    threads[y] = (rec_va, foff)
    return threads


def thread_info(ctx, tva):
    raw = ctx.read_va(tva, 0x900)
    if raw is None:
        return None
    u = lambda off: struct.unpack_from('<Q', raw, off)[0]  # noqa: E731
    name = ctx.read_cstr(u(0x7D8))
    return {
        'va': tva,
        'id': u(0x498),
        'name': name,
        'wait_event': u(0x018),
        'state_byte': raw[0xB8],
        'stack_va': u(0xE8),
        'saved_ctx': u(0x148),
        'raw': raw,
    }
