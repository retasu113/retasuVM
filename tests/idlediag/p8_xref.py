#!/usr/bin/env python3
"""Phase 8 xref scans over kernelcache.macho.

Modes:
  filesets                       list fileset entries + segment VA ranges
  bl <target_va> <lo> <hi>       list BL/B call sites to target in [lo,hi)
  ref <target_va> <lo> <hi>      list ADRP-based references to target in [lo,hi)
                                 (LDR/STR unsigned-imm or ADD-imm using a
                                  register last set by ADRP to target's page,
                                  with matching scaled offset)
"""
import bisect
import struct
import sys

sys.path.insert(0, '.')
from p5_common import load_syms  # noqa: E402
from parse_kc import parse  # noqa: E402

syms = sorted(load_syms()['syms'])
saddrs = [s[0] for s in syms]


def bracket(va):
    i = bisect.bisect_right(saddrs, va) - 1
    if i >= 0:
        return f'{syms[i][1]} +{va - syms[i][0]:#x}'
    return '?'


data = open(sys.argv[1], 'rb').read()
_segs, _s, _filesets = parse(data)
entries = {}
for _fe in _filesets:
    _s2, _sy2, _ = parse(data, _fe['fileoff'], 1)
    entries[_fe['name']] = _s2
    _segs += _s2


def va2off(v):
    for s in _segs:
        if s['vmaddr'] <= v < s['vmaddr'] + s['filesize']:
            return s['fileoff'] + (v - s['vmaddr'])
    raise ValueError(f'VA {v:#x} not in any segment')


def sxt(v, bits):
    return v - (1 << bits) if v >> (bits - 1) else v


mode = sys.argv[2]
if mode == 'filesets':
    for name, segs in entries.items():
        rng = [(s['seg'], s['vmaddr'], s['vmaddr'] + s['vmsize']) for s in segs if s['vmsize']]
        desc = ' '.join(f"{n}:[{a:#x},{b:#x})" for n, a, b in rng)
        print(f'{name}: {desc}')
    sys.exit(0)

target = int(sys.argv[3], 0)
lo, hi = int(sys.argv[4], 0), int(sys.argv[5], 0)
off = va2off(lo)
n = (hi - lo) // 4
words = struct.unpack_from(f'<{n}I', data, off)

if mode == 'bl':
    for i, w in enumerate(words):
        if w >> 26 in (0x25, 0x05):
            a = lo + i * 4
            tgt = a + sxt(w & 0x3FFFFFF, 26) * 4
            if tgt == target:
                print(f'{a:#x}: {"BL" if w >> 26 == 0x25 else "B "} in {bracket(a)}')
elif mode == 'ref':
    page = target & ~0xFFF
    want = target & 0xFFF
    regs = {}  # reg -> (page_value, insn_index)
    for i, w in enumerate(words):
        a = lo + i * 4
        if w & 0x9F000000 == 0x90000000:  # ADRP
            rd = w & 31
            imm = sxt(((w >> 3) & 0x1FFFFC) | ((w >> 29) & 3), 21)
            regs[rd] = ((a & ~0xFFF) + imm * 4096, i)
            continue
        rn = (w >> 5) & 31
        if rn not in regs or regs[rn][0] != page or i - regs[rn][1] > 12:
            continue
        if w & 0xFF800000 == 0x91000000:  # ADD imm64
            imm = (w >> 10) & 0xFFF
            if (w >> 22) & 1:
                imm <<= 12
            if imm == want:
                print(f'{a:#x}: ADD -> {bracket(a)}')
        elif w & 0x3B000000 == 0x39000000:  # LDR/STR unsigned imm
            size = (w >> 30) & 3
            imm = ((w >> 10) & 0xFFF) << size
            if imm == want:
                kind = 'LDR' if (w >> 22) & 1 else 'STR'
                print(f'{a:#x}: {kind} (size {size}) -> {bracket(a)}')
