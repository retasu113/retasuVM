#!/usr/bin/env python3
"""List load commands of a Mach-O 64 file (diagnostic)."""
import struct
import sys

NAMES = {0x1: "SEGMENT", 0x19: "SEGMENT_64", 0x2: "SYMTAB", 0xB: "DYSYMTAB",
         0x24: "UUID", 0x35: "FILESET_ENTRY", 0x26: "FUNCTION_STARTS",
         0x29: "DATA_IN_CODE", 0x1D: "CODE_SIGNATURE", 0x21: "ENCRYPTION_INFO",
         0x2C: "DYLD_INFO_ONLY", 0x80000022: "DYLD_INFO", 0x32: "BUILD_VERSION",
         0x33: "DYLD_EXPORTS_TRIE", 0x34: "DYLD_CHAINED_FIXUPS", 0x36: "FILES",
         0x80000034: "DYLD_CHAINED_FIXUPS_LC"}


def dump(path):
    data = open(path, "rb").read()
    magic = struct.unpack_from("<I", data, 0)[0]
    print(f"{path}: size={len(data)} magic={magic:#x}")
    if magic != 0xFEEDFACF:
        return
    (_, _, _, ftype, ncmds, sizeofcmds, _, _) = struct.unpack_from("<IiiIIIII", data, 0)
    print(f"  filetype={ftype} ncmds={ncmds}")
    off = 32
    for i in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        extra = ""
        if cmd == 0x2:
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", data, off + 8)
            extra = f" symoff=0x{symoff:x} nsyms={nsyms} stroff=0x{stroff:x} strsize=0x{strsize:x}"
        if cmd == 0x19:
            segname = data[off + 8:off + 24].split(b"\0")[0].decode("ascii", "replace")
            extra = f" {segname}"
        print(f"  [{i}] {NAMES.get(cmd, hex(cmd))}{extra} size={cmdsize}")
        off += cmdsize


for p in sys.argv[1:]:
    dump(p)
