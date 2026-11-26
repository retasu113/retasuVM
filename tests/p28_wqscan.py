#!/usr/bin/env python3
"""Phase 28 follow-up: locate candidate arm_thread_state64 builders in the
pthread kext (setup_wqthread's SP store). Signature: a 64-bit STR to
[reg, #0xF8] (__sp slot) with, within the next 16 instructions, a 64-bit
STR to [same reg, #0x100] (__pc slot). __bsdthread_create's known site
(unslid 0xfffffe000a27fce4 / 0xa27fcfc) must appear; report all others in
the kext VA range.
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
            return vmaddr + (o - fileoff), name
    return None, None

def va_to_off(va):
    for name, vmaddr, vmsize, fileoff, filesize in segs:
        if vmaddr <= va < vmaddr + vmsize:
            return fileoff + (va - vmaddr), name
    return None, None

# find which segment holds the kext (bsdthread_create VA)
kva = 0xfffffe000a27fa38
ko, kseg = va_to_off(kva)
print(f"bsdthread_create VA {kva:#x} in segment {kseg} fileoff {ko:#x}")
for name, vmaddr, vmsize, fileoff, filesize in segs:
    print(f"SEG {name:16s} va {vmaddr:#x}..{vmaddr+vmsize:#x} fileoff {fileoff:#x}")

SP_PAT = 0xF9007C00   # STR x?, [x?, #0xF8] with Rt/Rn masked out below
PC_PAT = 0xF9008000   # STR x?, [x?, #0x100]
MASK = 0xFFFFFC00

cands = []
n = len(data) // 4
words = struct.unpack_from(f'<{n}I', data, 0)
for i in range(n):
    w = words[i]
    if (w & MASK) == SP_PAT:
        rn = (w >> 5) & 0x1F
        # look ahead 16 insns for PC store with same Rn
        for j in range(1, 17):
            if i + j >= n:
                break
            w2 = words[i + j]
            if (w2 & MASK) == PC_PAT and ((w2 >> 5) & 0x1F) == rn:
                va, seg = off_to_va(i * 4)
                if va is not None:
                    cands.append((va, seg, rn))
                break

print(f"\ncandidates (SP store + PC store within 16 insns): {len(cands)}")
for va, seg, rn in cands:
    print(f"  {va:#x} ({seg}) Rn=x{rn}")

# disassemble around candidates in the kext segment only
md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
for va, seg, rn in cands:
    if seg != kseg:
        continue
    print(f"\n--- kext candidate {va:#x} ---")
    start = va - 0x30
    o, _ = va_to_off(start)
    for insn in md.disasm(data[o:o + 0x90], start):
        mark = ' <== SP store' if insn.address == va else ''
        print(f"{insn.address:#x}: {insn.mnemonic:8s} {insn.op_str}{mark}")
