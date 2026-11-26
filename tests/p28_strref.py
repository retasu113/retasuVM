#!/usr/bin/env python3
"""Phase 28b: find code referencing the 'Non-monotonic time: last_dispatch'
string (VA 0xfffffe000704ce82) via adrp/add pairs; disassemble around each
reference; also dump the window around the panic caller PC 0x7e02378.
"""
import struct, sys, pickle, bisect
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

syms, secs = pickle.load(open('/home/hatch/workspace/retasuvm/tests/logs/kc_syms.pkl', 'rb'))
addrs = [a for a, _ in syms]
def resolve(va):
    i = bisect.bisect_right(addrs, va) - 1
    a, n = syms[i]
    return f"{n} + 0x{va-a:x}"

STR_VA = 0xfffffe000704ce82
PAGE = STR_VA & ~0xfff
OFF12 = STR_VA & 0xfff
print(f"string page {PAGE:#x} off {OFF12:#x}")

md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)

# scan __TEXT_EXEC for adrp whose target page == PAGE, then check following
# add (within 3 insns) with imm == OFF12 into same reg
refs = []
for name, vmaddr, vmsize, fileoff, filesize in segs:
    if name != '__TEXT_EXEC':
        continue
    words = struct.unpack_from(f'<{filesize//4}I', data, fileoff)
    for i, w in enumerate(words):
        if (w & 0x9f000000) == 0x90000000:  # ADRP
            rd = w & 0x1f
            immlo = (w >> 29) & 0x3
            immhi = (w >> 5) & 0x7ffff
            imm = (immhi << 2) | immlo
            if imm & 0x100000:
                imm -= 0x200000
            pc = vmaddr + i * 4
            tgt_page = (pc & ~0xfff) + (imm << 12)
            if tgt_page == PAGE:
                # look ahead up to 4 insns for ADD rd, rd, #OFF12
                for j in range(1, 5):
                    if i + j >= len(words):
                        break
                    w2 = words[i + j]
                    if (w2 & 0xff000000) == 0x91000000:  # ADD imm (64-bit, no shift)
                        rn = (w2 >> 5) & 0x1f
                        rd2 = w2 & 0x1f
                        imm12 = (w2 >> 10) & 0xfff
                        sh = (w2 >> 22) & 0x3
                        if rn == rd and imm12 == OFF12 and sh == 0:
                            refs.append(pc)
                            break
print("string refs:", [hex(r) for r in refs])
for r in refs:
    print(f"\n--- around ref {r:#x} ({resolve(r)}) ---")
    start = r - 0x60
    o, _ = va_to_off(start)
    for insn in md.disasm(data[o:o + 0x100], start):
        mark = ''
        if insn.address == r:
            mark = ' <== adrp str'
        print(f"{insn.address:#x}: {insn.mnemonic:8s} {insn.op_str}{mark}")

print("\n--- window around caller PC 0x7e02378 ---")
start = 0xfffffe0007e02330
o, _ = va_to_off(start)
for insn in md.disasm(data[o:o + 0xc0], start):
    mark = ' <== CALLER PC' if insn.address == 0xfffffe0007e02378 else ''
    print(f"{insn.address:#x}: {insn.mnemonic:8s} {insn.op_str}{mark}")
