#!/usr/bin/env python3
"""Phase 8: full capstone disassembly of a kernelcache function range,
with BL targets bracketed by symbol, and ADRP-based address tracking.
Usage: p8_disas.py <kernelcache.macho> <start_va_hex> <end_va_hex>
"""
import bisect
import struct
import sys

from capstone import CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN, Cs

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


path, lo, hi = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0)
data = open(path, 'rb').read()
_segs, _s, _filesets = parse(data)
for _fe in _filesets:
    _s2, _sy2, _ = parse(data, _fe['fileoff'], 1)
    _segs += _s2


def va2off(v):
    for s in _segs:
        if s['vmaddr'] <= v < s['vmaddr'] + s['filesize']:
            return s['fileoff'] + (v - s['vmaddr'])
    raise ValueError(f'VA {v:#x} not in any segment')


off = va2off(lo)
code = data[off:off + (hi - lo)]
md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.detail = False
for ins in md.disasm(code, lo):
    ann = ''
    if ins.mnemonic in ('bl', 'b') and ins.op_str.startswith('#'):
        tgt = int(ins.op_str[1:], 16)
        ann = f'   ; {bracket(tgt)}'
    elif ins.mnemonic == 'adrp':
        try:
            page = int(ins.op_str.split('#')[1], 16)
            ann = f'   ; page of {bracket(page)}'
        except Exception:
            pass
    print(f'{ins.address:#018x}: {ins.mnemonic:8s} {ins.op_str}{ann}')
