"""Phase 7: minimal AArch64 decoder for kernelcache.macho call sites.
Decodes BL/B targets and ADRP+ADD address materializations around a
given link VA, bracketed with the symbol table — enough to name the
callee and the lock/event argument of a blocking call.
Usage: python3 p7_disas.py <kernelcache.macho> <link_va_hex> [n_insns]
Assumes __TEXT vmaddr == 0xFFFFFE0000000000 at file offset 0 (verified
by checking the call-site word is a BL).
"""
import json
import os
import struct
import sys

sys.path.insert(0, '.')
from p5_common import load_syms  # noqa: E402

BASE = 0xFFFFFE0000000000
syms = sorted(load_syms()['syms'])
import bisect  # noqa: E402
saddrs = [s[0] for s in syms]


def bracket(va):
    i = bisect.bisect_right(saddrs, va) - 1
    if i >= 0:
        return f'{syms[i][1]} +{va - syms[i][0]:#x}'
    return '?'


def sxt(v, bits):
    return v - (1 << bits) if v >> (bits - 1) else v


path = sys.argv[1]
va = int(sys.argv[2], 0)
n = int(sys.argv[3]) if len(sys.argv) > 3 else 24
data = open(path, 'rb').read()

from parse_kc import parse  # noqa: E402

_segs, _syms, _filesets = parse(data)
for _fe in _filesets:
    _s2, _sy2, _ = parse(data, _fe['fileoff'], 1)
    _segs += _s2


def va2off(v):
    for s in _segs:
        if s['vmaddr'] <= v < s['vmaddr'] + s['filesize']:
            return s['fileoff'] + (v - s['vmaddr'])
    raise ValueError(f'VA {v:#x} not in any segment')


off = va2off(va)
regs = {}
for i in range(n):
    a = va + i * 4
    w = struct.unpack_from('<I', data, off + i * 4)[0]
    txt = ''
    if w >> 26 == 0x25:  # BL
        tgt = a + sxt(w & 0x3FFFFFF, 26) * 4
        txt = f'BL  {tgt:#x}  {bracket(tgt)}'
    elif w >> 26 == 0x05:  # B
        tgt = a + sxt(w & 0x3FFFFFF, 26) * 4
        txt = f'B   {tgt:#x}  {bracket(tgt)}'
    elif w & 0x9F000000 == 0x90000000:  # ADRP
        rd = w & 31
        imm = sxt(((w >> 3) & 0x1FFFFC) | ((w >> 29) & 3), 21)
        page = (a & ~0xFFF) + imm * 4096
        regs[rd] = page
        txt = f'ADRP x{rd}, {page:#x}  {bracket(page)}'
    elif w & 0xFF800000 == 0x91000000:  # ADD imm64
        rd, rn = w & 31, (w >> 5) & 31
        imm = (w >> 10) & 0xFFF
        if (w >> 22) & 1:
            imm <<= 12
        if rn in regs:
            val = regs[rn] + imm
            regs[rd] = val
            txt = f'ADD  x{rd}, x{rn}, #{imm:#x} -> {val:#x}  {bracket(val)}'
        else:
            txt = f'ADD  x{rd}, x{rn}, #{imm:#x}'
    elif w & 0xFFFFFC1F == 0xD63F0000:  # BLR
        txt = f'BLR  x{(w >> 5) & 31}'
    elif w & 0xFF000000 == 0xAA000000:  # MOV reg (ORR)
        txt = f'MOV  x{w & 31}, x{(w >> 16) & 31}'
    elif w & 0xFF800000 == 0xD2800000:  # MOVZ
        txt = f'MOVZ x{w & 31}, #{(w >> 5) & 0xFFFF}'
    print(f'  {a:#x}: {w:08x}  {txt}')
