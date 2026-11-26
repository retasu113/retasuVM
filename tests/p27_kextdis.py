#!/usr/bin/env python3
"""Phase 27: disassemble the pthread kext's bsdthread_create (__bsdthread_create,
kernelcache fileoff 0x327ba38, VA 0xfffffe000a27fa38) with capstone.
Also dump the _pthread_internal_functions table raw bytes for the record.
Usage: p27_kextdis.py [nbytes]
"""
import struct
import sys

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

KC = '/home/hatch/workspace/retasuvm/ipsw15/kernelcache.macho'
data = open(KC, 'rb').read()
N = int(sys.argv[1], 0) if len(sys.argv) > 1 else 0x800
BASE_VA = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0xFFFFFE000A27FA38
BASE_OFF = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0x327BA38
OUT = sys.argv[4] if len(sys.argv) > 4 else '/home/hatch/workspace/retasuvm/tests/logs/p27_bsdthread_create.bin'

code = data[BASE_OFF:BASE_OFF + N]
open('/home/hatch/workspace/retasuvm/tests/logs/p27_bsdthread_create.bin', 'wb').write(code)
md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.detail = False
for insn in md.disasm(code, BASE_VA):
    print(f"{insn.address:#x}: {insn.mnemonic:10s} {insn.op_str}")
