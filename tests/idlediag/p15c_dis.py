#!/usr/bin/env python3
"""Phase 15 continuation: disassemble an arbitrary VA range of the
kernelcache with the p15_apfsdis symbol/string annotation.
Usage: p15c_dis.py <startVA hex> <n_insns>"""
import sys
sys.path.insert(0, '/home/hatch/workspace/retasuvm/tests/idlediag')
import p15_apfsdis as D

start = int(sys.argv[1], 16)
n = int(sys.argv[2]) if len(sys.argv) > 2 else 100
# reuse disas() by temporarily faking: it disassembles from `start`
# until the next symbol; emulate by calling its internals:
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = True
code = D.data[start - D.BASE:start - D.BASE + n * 4 + 64]
adrp = {}
count = 0
for ins in md.disasm(code, start):
    ann = ""
    if ins.mnemonic == "adrp":
        try:
            adrp[ins.operands[0].reg] = ins.operands[1].imm
        except Exception:
            pass
    if ins.mnemonic in ("add", "ldr", "ldrb", "ldrsw") and len(ins.operands) >= 2:
        op = ins.operands[1]
        try:
            if op.type == 3 and op.mem.base in adrp:
                tgt = adrp[op.mem.base] + op.mem.disp
                s = D.cstr_at(tgt)
                sy, off = D.sym_near(tgt)
                if s:
                    ann = f"   ; str {tgt:#x} {s!r}"
                elif sy and off < 0x40:
                    ann = f"   ; {tgt:#x} -> {sy[1]}+{off:#x}"
        except Exception:
            pass
    if ins.mnemonic in ("bl", "b", "b.eq", "b.ne", "b.hi", "b.lo", "b.hs",
                        "b.ls", "b.ge", "b.lt", "b.gt", "b.le", "cbz", "cbnz",
                        "tbz", "tbnz") and ins.op_str.startswith("#"):
        try:
            t = int(ins.op_str.split(",")[-1].strip()[1:], 16)
            sy, off = D.sym_near(t)
            if sy:
                ann = f"   ; {sy[1]}+{off:#x}"
        except Exception:
            pass
    print(f"{ins.address:#x}: {ins.mnemonic:8s} {ins.op_str}{ann}")
    count += 1
    if count >= n:
        break
