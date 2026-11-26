#!/usr/bin/env python3
"""Phase 22: parse libsystem_c mach-o header at cache file offset 0x304000
(chunk 48, offset 0x4000) and report LC_SYMTAB + __TEXT segment.
Then list the chunks that must be decoded for the symtab/strtab."""
import struct

CHUNK48 = "/tmp/p22_pc_48.bin"
HDR_OFF = 0x4000  # file offset 0x304000 within chunk 48
PC = 0x1803089EC

d = open(CHUNK48, "rb").read()
b = d[HDR_OFF:HDR_OFF + 4096]
magic, cputype, cpusub, ftype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<IIIIIIII", b, 0)
print(f"magic={magic:#x} cputype={cputype:#x} filetype={ftype} ncmds={ncmds} sizeofcmds={sizeofcmds:#x}")
off = 32
sym = None
text_seg = None
for i in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<II", b, off)
    if cmd == 0x19:  # LC_SEGMENT_64
        segname = b[off + 8:off + 24].rstrip(b"\x00").decode()
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", b, off + 24)
        print(f"  LC_SEGMENT_64 {segname}: vmaddr={vmaddr:#x} vmsize={vmsize:#x} fileoff={fileoff:#x} filesize={filesize:#x}")
        if segname == "__TEXT":
            text_seg = (vmaddr, fileoff)
    elif cmd == 0x2:  # LC_SYMTAB
        symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", b, off + 8)
        sym = (symoff, nsyms, stroff, strsize)
        print(f"  LC_SYMTAB symoff={symoff:#x} nsyms={nsyms} stroff={stroff:#x} strsize={strsize:#x}")
    elif cmd == 0xB:  # LC_DYLD_INFO_ONLY
        pass
    off += cmdsize
print(f"PC {PC:#x} file offset (via __TEXT): {text_seg[1] + (PC - text_seg[0]):#x}" if text_seg else "no __TEXT seg")
if sym:
    symoff, nsyms, stroff, strsize = sym
    print(f"symtab chunks: {symoff // 65536}..{(symoff + nsyms * 16 - 1) // 65536}")
    print(f"strtab chunks: {stroff // 65536}..{(stroff + strsize - 1) // 65536}")
