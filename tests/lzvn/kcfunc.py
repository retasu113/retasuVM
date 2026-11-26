import pickle, struct, sys
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
target = int(sys.argv[1], 16); size = int(sys.argv[2], 0)
o = va2off(target)
code = kc[o:o+size]
md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
for insn in md.disasm(code, target):
    print('0x%x:\t%s\t%s' % (insn.address, insn.mnemonic, insn.op_str))
