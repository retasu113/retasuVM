import pickle, struct, sys, re
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
kc = open('/home/hatch/workspace/retasuvm/ipsw15/kernelcache.macho','rb').read()
ncmds, sizeofcmds = struct.unpack_from('<II', kc, 16)
segs = []
off = 32
for i in range(ncmds):
    cmd, cmdsize = struct.unpack_from('<II', kc, off)
    if cmd == 0x19:
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', kc, off+24)
        segs.append((vmaddr, fileoff, filesize))
    off += cmdsize
def va2off(va):
    for vmaddr, fileoff, filesize in segs:
        if vmaddr <= va < vmaddr + filesize:
            return fileoff + (va - vmaddr)
    return None
syms, _ = pickle.load(open('/home/hatch/workspace/retasuvm/tests/logs/kc_syms.pkl','rb'))
alladdrs = sorted(a for a, n in syms)
import bisect
target = int(sys.argv[1], 16)
idx = bisect.bisect_right(alladdrs, target)
end = alladdrs[idx] if idx < len(alladdrs) else target + 0x4000
o = va2off(target)
code = kc[o:o + (end - target)]
md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
simd_insns = {}
scalar = {}
fp_ops = re.compile(r'\b[vqdbhs]\d{1,2}\b|\b[wx]\d{1,2}\.|\.')
n = 0
for insn in md.disasm(code, target):
    n += 1
    ops = insn.op_str
    first = ops.split(',')[0].strip() if ops else ''
    if re.match(r'^[vqdbhs]\d+$', first) or re.search(r'\bv\d+\.', ops) or insn.mnemonic.startswith(('fadd','fmul','fcvt','fmla','fdiv','fsqrt','frint','fmax','fmin','fcmp')):
        simd_insns[insn.mnemonic] = simd_insns.get(insn.mnemonic, 0) + 1
    else:
        scalar[insn.mnemonic] = scalar.get(insn.mnemonic, 0) + 1
print(f'@0x{target:x} size={end-target} bytes, linear insns={n}')
print('SIMD/FP:', simd_insns)
print('top scalar:', sorted(scalar.items(), key=lambda kv: -kv[1])[:15])
