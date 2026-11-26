import pickle, struct, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
kc = open('/home/hatch/workspace/retasuvm/ipsw15/kernelcache.macho','rb').read()
magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, res = struct.unpack_from('<IIIIIIII', kc, 0)
segs = []
off = 32
for i in range(ncmds):
    cmd, cmdsize = struct.unpack_from('<II', kc, off)
    if cmd == 0x19:  # LC_SEGMENT_64
        name = kc[off+8:off+24].rstrip(b'\0').decode()
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', kc, off+24)
        segs.append((name, vmaddr, vmsize, fileoff, filesize))
    off += cmdsize
def va2off(va):
    for name, vmaddr, vmsize, fileoff, filesize in segs:
        if vmaddr <= va < vmaddr + filesize:
            return fileoff + (va - vmaddr)
    return None
syms, _ = pickle.load(open('/home/hatch/workspace/retasuvm/tests/logs/kc_syms.pkl','rb'))
symmap = {}
for addr, name in syms:
    symmap.setdefault(name, []).append(addr)
target = int(sys.argv[1], 16)
# size = next symbol after target
alladdrs = sorted(a for a, n in syms)
import bisect
idx = bisect.bisect_right(alladdrs, target)
end = alladdrs[idx] if idx < len(alladdrs) else target + 0x2000
o = va2off(target)
code = kc[o:o + (end - target)]
md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.detail = False
count = 0
simd = {}
other = {}
for insn in md.disasm(code, target):
    count += 1
    m = insn.mnemonic
    other[m] = other.get(m, 0) + 1
    if insn.op_str and ('q' in insn.op_str.split(',')[0][-2:] or 'v' in insn.op_str.split(',')[0][-2:] or 'd' in insn.op_str.split(',')[0][-2:] or 's' in insn.op_str.split(',')[0][-2:]):
        simd[m] = simd.get(m, 0) + 1
print(f'function @0x{target:x} size={end-target} insns~{count}')
print('mnemonics:', sorted(other.items(), key=lambda kv: -kv[1])[:25])
