#!/usr/bin/env python3
"""Find symbols by substring in kc_syms.pkl and disassemble link-VA ranges."""
import pickle, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

BASE = 0xFFFFFE0007004000
syms, exec_ranges = pickle.load(open(sys.argv[1], "rb"))
data = open(sys.argv[2], "rb").read()
md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)

def disasm(link_va, nbytes):
    foff = link_va - BASE
    for i in md.disasm(data[foff:foff + nbytes], link_va):
        print(f"  0x{i.address:x}: {i.mnemonic} {i.op_str}")

mode = sys.argv[3]
if mode == "find":
    pat = sys.argv[4].lower()
    for va, name in syms:
        if pat in name.lower():
            print(f"0x{va:x}  {name}")
elif mode == "dis":
    disasm(int(sys.argv[4], 16), int(sys.argv[5], 0))
