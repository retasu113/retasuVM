#!/usr/bin/env python3
"""Disassemble the p23 spin loop region with capstone.
Input: hex string on stdin (bytes starting at file offset 0x308900).
Unslid base VA = 0x180308900. Slid PC = 0x19B87C9EC (unslid 0x1803089EC),
slid LR = 0x19b87cacc (unslid 0x180307acc)."""
import sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

hexs = sys.stdin.read().strip()
code = bytes.fromhex(hexs)
BASE = 0x180308900
PC_UNSLID = 0x1803089EC
LR_UNSLID = 0x180307ACC
md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.detail = False
for insn in md.disasm(code, BASE):
    mark = ""
    if insn.address == PC_UNSLID:
        mark = "   <== PC (slid 0x19B87C9EC)"
    if insn.address == LR_UNSLID:
        mark += "   <== LR (slid 0x19b87cacc)"
    print(f"{insn.address:#x}: {insn.mnemonic:10s} {insn.op_str}{mark}")
