#!/usr/bin/env python3
"""Phase 29: disassemble a kernelcache function given its file offset.
Usage: p29_kextdis.py <fileoff_hex> [nbytes] [end_va_hex]
Prints VA-annotated disassembly; stops at ret if end not given (heuristic:
disassemble nbytes, default 0x1000).
"""
import struct, sys
sys.path.insert(0, '/home/hatch/workspace/retasuvm/tests/pytools')
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

KC = '/home/hatch/workspace/retasuvm/ipsw15/kernelcache.macho'
data = open(KC, 'rb').read()
magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from('<8I', data, 0)
segs = []
off = 32
for i in range(ncmds):
    cmd, cmdsize = struct.unpack_from('<2I', data, off)
    if cmd == 0x19:
        name = data[off + 8:off + 24].split(b'\x00')[0].decode()
        vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects, segflags = struct.unpack_from('<8Q', data, off + 24)
        segs.append((name, vmaddr, vmsize, fileoff, filesize))
    off += cmdsize

def off_to_va(o):
    for name, vmaddr, vmsize, fileoff, filesize in segs:
        if fileoff <= o < fileoff + filesize:
            return vmaddr + (o - fileoff)
    return None

fo = int(sys.argv[1], 0)
n = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0x1000
va = off_to_va(fo)
print(f"# fileoff {fo:#x} -> VA {va:#x}")
md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
for insn in md.disasm(data[fo:fo + n], va):
    w = struct.unpack_from('<I', data, fo + (insn.address - va))[0]
    print(f"{insn.address:#x}: {w:08x}  {insn.mnemonic:10s} {insn.op_str}")
