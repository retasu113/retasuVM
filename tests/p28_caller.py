#!/usr/bin/env python3
"""Phase 28: resolve the Non-monotonic-time panic caller PC.
Slid caller 0xfffffe00200b6378, slide 0x182b4000 -> unslid 0xfffffe0007e02378.
Disassemble around it, find the panic-string reference, find the containing
function start, then scan __TEXT_EXEC for all bl call sites to that start.
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

def off_to_va(o):
    for name, vmaddr, vmsize, fileoff, filesize in segs:
        if fileoff <= o < fileoff + filesize:
            return vmaddr + (o - fileoff), name
    return None, None

# 1. find the panic string VA
needle = b'Non-monotonic time: last_dispatch at'
idx = data.find(needle)
str_va, seg = off_to_va(idx)
print(f"panic string at fileoff {idx:#x} VA {str_va:#x} ({seg})")

syms, secs = pickle.load(open('/home/hatch/workspace/retasuvm/tests/logs/kc_syms.pkl', 'rb'))
addrs = [a for a, _ in syms]
def resolve(va):
    i = bisect.bisect_right(addrs, va) - 1
    a, n = syms[i]
    return f"{n} + 0x{va-a:x}"

TARGET = 0xfffffe0007e02378
print(f"caller unslid {TARGET:#x} -> {resolve(TARGET)}")

md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)

# 2. disassemble a window ending a bit after TARGET
start = TARGET - 0x180
o, _ = va_to_off(start)
code = data[o:o + 0x1c0]
insns = list(md.disasm(code, start))
for insn in insns:
    mark = ' <== CALLER PC' if insn.address == TARGET else ''
    print(f"{insn.address:#x}: {insn.mnemonic:8s} {insn.op_str}{mark}")

# 3. find function start: scan backwards from TARGET for 'ret' end of previous fn
#    or a typical prologue. Walk instruction by instruction from a page-aligned
#    earlier point and record addresses of 'ret'.
scan_start = TARGET - 0x2000
o, _ = va_to_off(scan_start)
code = data[o:o + 0x2000 + 0x10]
rets = []
prev = None
for insn in md.disasm(code, scan_start):
    if insn.address >= TARGET:
        break
    if insn.mnemonic == 'ret':
        rets.append(insn.address)
print("\nlast 3 'ret' before caller:", [hex(r) for r in rets[-3:]])
if rets:
    fn_start = rets[-1] + 4
    print(f"probable containing-function start: {fn_start:#x} -> {resolve(fn_start)}")
    # 4. scan __TEXT_EXEC for bl to fn_start
    for name, vmaddr, vmsize, fileoff, filesize in segs:
        if name != '__TEXT_EXEC':
            continue
        print(f"scanning __TEXT_EXEC {vmaddr:#x}..{vmaddr+vmsize:#x}")
        calls = []
        base = fileoff
        for i in range(0, filesize - 3, 4):
            w = struct.unpack_from('<I', data, base + i)[0]
            if (w >> 26) == 0b100101:  # BL
                imm = w & 0x3ffffff
                if imm & 0x2000000:
                    imm -= 0x4000000
                tgt = vmaddr + i + imm * 4
                if tgt == fn_start:
                    calls.append(vmaddr + i)
        print(f"bl call sites to {fn_start:#x}: {[hex(c) for c in calls]}")
        for c in calls:
            print(f"   site {c:#x} in {resolve(c)}")
