#!/usr/bin/env python3
"""Phase 28e: dump the fired copy's containing function (start 0x7e01eb8),
find branches to the panic block at 0x7e02358, and dump the code feeding the
compare (the ctime source) to distinguish thread_unblock vs
thread_quantum_expire. Also disassemble _mach_absolute_time head to learn the
counter-read pattern (ml_get_timebase).
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

def va_to_off(va):
    for name, vmaddr, vmsize, fileoff, filesize in segs:
        if vmaddr <= va < vmaddr + vmsize:
            return fileoff + (va - vmaddr), name
    return None, None

md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)

print("=== _mach_absolute_time head (counter-read pattern) ===")
start = 0xfffffe0007f35efc
o, _ = va_to_off(start)
for insn in md.disasm(data[o:o + 0x60], start):
    print(f"{insn.address:#x}: {insn.mnemonic:8s} {insn.op_str}")

FN = 0xfffffe0007e01eb8
PANIC_BLOCK = 0xfffffe0007e02358
print(f"\n=== fn {FN:#x}: branches to panic block {PANIC_BLOCK:#x} ===")
o, _ = va_to_off(FN)
insns = list(md.disasm(data[o:o + 0x1400], FN))
for idx, insn in enumerate(insns):
    if insn.op_str.startswith('#'):
        try:
            tgt = int(insn.op_str[1:], 16)
        except ValueError:
            continue
        if tgt == PANIC_BLOCK:
            print(f"branch at {insn.address:#x}: {insn.mnemonic} {insn.op_str}")
            for j in range(max(0, idx - 22), idx + 1):
                p = insns[j]
                print(f"   {p.address:#x}: {p.mnemonic:8s} {p.op_str}")
