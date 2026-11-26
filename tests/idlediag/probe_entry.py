#!/usr/bin/env python3
"""Probe one fileset entry: is LC_SYMTAB offsets relative to entry base or absolute?"""
import struct
import sys

data = open(sys.argv[1], "rb").read()
base = int(sys.argv[2], 16)
magic = struct.unpack_from("<I", data, base)[0]
print(f"magic={magic:#x}")
(_, _, _, ftype, ncmds, sizeofcmds, _, _) = struct.unpack_from("<IiiIIIII", data, base)
print(f"filetype={ftype} ncmds={ncmds}")
off = base + 32
for i in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<II", data, off)
    cmd &= 0x7FFFFFFF
    if cmd == 0x2:
        symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", data, off + 8)
        print(f"SYMTAB symoff=0x{symoff:x} nsyms={nsyms} stroff=0x{stroff:x} strsize=0x{strsize:x}")
        for label, so, st in (("rel", base + symoff, base + stroff), ("abs", symoff, stroff)):
            try:
                n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", data, so)
                end = data.index(b"\0", st + n_strx)
                nm = data[st + n_strx:end].decode("ascii", "replace")
                print(f"  {label}: sym0 value=0x{n_value:x} name={nm!r}")
            except Exception as e:
                print(f"  {label}: fail {e}")
    if cmd == 0x19:
        segname = data[off + 8:off + 24].split(b"\0")[0].decode("ascii", "replace")
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", data, off + 24)
        print(f"SEG {segname} vmaddr=0x{vmaddr:x} fileoff=0x{fileoff:x} filesize=0x{filesize:x}")
    off += cmdsize
