#!/usr/bin/env python3
"""Phase 11: disassemble PE_halt_restart path in the Sequoia kernelcache and
find all callers of _PE_halt_restart, recovering the w0 constant at each site.

Usage: p11_disas.py <syms.pkl> <kernelcache.macho> <mode> [args]
  mode=func  <linkVA hex> [maxbytes]   disassemble from VA to next symbol
  mode=xref  <linkVA hex>             scan exec ranges for BL/B to target
"""
import bisect
import pickle
import struct
import sys

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

BASE = 0xFFFFFE0007004000


def load(pkl, kc):
    syms, ranges = pickle.load(open(pkl, "rb"))
    data = open(kc, "rb").read()
    return syms, ranges, data


def sym_at(syms, vals, va):
    idx = bisect.bisect_right(vals, va) - 1
    if idx < 0:
        return None, None
    return syms[idx], va - syms[idx][0]


def main():
    pkl, kc, mode = sys.argv[1], sys.argv[2], sys.argv[3]
    syms, ranges, data = load(pkl, kc)
    vals = [s[0] for s in syms]
    md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
    md.detail = False

    if mode == "func":
        va = int(sys.argv[4], 16)
        maxb = int(sys.argv[5], 0) if len(sys.argv) > 5 else 0x600
        idx = bisect.bisect_right(vals, va)
        end = syms[idx][0] if idx < len(syms) else va + maxb
        end = min(end, va + maxb)
        sym, off = sym_at(syms, vals, va)
        print(f"== {sym[1] if sym else '?'} @0x{va:x} .. 0x{end:x} ==")
        foff = va - BASE
        for i in md.disasm(data[foff:foff + (end - va)], va):
            print(f"  0x{i.address:x}: {i.mnemonic} {i.op_str}")
    elif mode == "xref":
        target = int(sys.argv[4], 16)
        hits = []
        for a, b, _ in ranges:
            foff = a - BASE
            chunk = data[foff:foff + (b - a)]
            for off in range(0, len(chunk) - 3, 4):
                (w,) = struct.unpack_from("<I", chunk, off)
                # BL: 100101 imm26 ; B: 000101 imm26
                if (w >> 26) in (0b100101, 0b000101):
                    imm = w & 0x3FFFFFF
                    if imm & 0x2000000:
                        imm -= 0x4000000
                    dst = a + off + imm * 4
                    if dst == target:
                        hits.append((a + off, (w >> 26) == 0b100101))
            # also scan for ADRP+ADD/LDR pointer references is out of scope
        print(f"{len(hits)} direct branch sites to 0x{target:x}")
        for site, is_bl in hits:
            sym, off = sym_at(syms, vals, site)
            print(f"  0x{site:x} {'BL' if is_bl else 'B '} in {sym[1] if sym else '?'} +0x{off:x}")
            # disassemble 12 insns before the call to find w0 setup
            foff = site - BASE
            for i in md.disasm(data[foff - 48:foff + 4], site - 48):
                mark = " <==" if i.address == site else ""
                print(f"      0x{i.address:x}: {i.mnemonic} {i.op_str}{mark}")
    else:
        print("unknown mode")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
