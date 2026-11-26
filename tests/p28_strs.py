#!/usr/bin/env python3
"""Phase 28d: locate all 'Non-monotonic time' strings and their code refs,
map each ref to its containing function (pacibsp start), and check whether
the fired copy's function (start 0x7e01eb8) references the 'invoke at' string.
Also check ml_get_timebase in XNU source terms: find _ml_get_timebase symbol.
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

def word(va):
    o, _ = va_to_off(va)
    return struct.unpack_from('<I', data, o)[0]

syms, secs = pickle.load(open('/home/hatch/workspace/retasuvm/tests/logs/kc_syms.pkl', 'rb'))
by_name = {n: a for a, n in syms}
for nm in ['_ml_get_timebase', '_mach_absolute_time', '_thread_unblock', '_thread_quantum_expire', '_thread_invoke']:
    print(nm, hex(by_name[nm]) if nm in by_name else 'NOT IN SYMS')

# find all Non-monotonic strings
strs = {}
pos = 0
while True:
    i = data.find(b'Non-monotonic time:', pos)
    if i < 0:
        break
    end = data.find(b'\x00', i)
    s = data[i:end].decode()
    va, seg = off_to_va(i)
    strs[va] = s
    print(f"STR {va:#x}: {s}")
    pos = i + 1

# find refs (adrp+add) for each string in __TEXT_EXEC
def find_refs(str_va):
    PAGE = str_va & ~0xfff
    OFF12 = str_va & 0xfff
    refs = []
    for name, vmaddr, vmsize, fileoff, filesize in segs:
        if name != '__TEXT_EXEC':
            continue
        words = struct.unpack_from(f'<{filesize//4}I', data, fileoff)
        for i, w in enumerate(words):
            if (w & 0x9f000000) == 0x90000000:
                rd = w & 0x1f
                imm = (((w >> 5) & 0x7ffff) << 2) | ((w >> 29) & 0x3)
                if imm & 0x100000:
                    imm -= 0x200000
                pc = vmaddr + i * 4
                if (pc & ~0xfff) + (imm << 12) == PAGE:
                    for j in range(1, 5):
                        if i + j >= len(words):
                            break
                        w2 = words[i + j]
                        if (w2 & 0xff000000) == 0x91000000 and ((w2 >> 5) & 0x1f) == rd and ((w2 >> 10) & 0xfff) == OFF12 and ((w2 >> 22) & 0x3) == 0:
                            refs.append(pc)
                            break
    return refs

def fn_start(va):
    a = va & ~3
    for p in range(a, a - 0x10000, -4):
        if word(p) == 0xd503237f:
            return p
    return None

for va, s in strs.items():
    refs = find_refs(va)
    for r in refs:
        fs = fn_start(r)
        print(f"ref {r:#x} (fn start {fs:#x}) <- {s[:60]}")
