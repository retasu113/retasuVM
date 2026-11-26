#!/usr/bin/env python3
"""Phase 11: locate a kext inside the kernelcache fileset and list its symbols."""
import struct, sys

KC = "/home/hatch/workspace/retasuvm/ipsw15/kernelcache.macho"
data = open(KC, "rb").read()

def parse_header(off):
    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<IiiIIIII", data, off)
    assert magic == 0xFEEDFACF, hex(magic)
    return ncmds, sizeofcmds

def load_commands(off):
    ncmds, _ = parse_header(off)
    cmds = []
    p = off + 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, p)
        cmds.append((cmd, p, cmdsize))
        p += cmdsize
    return cmds

entries = []
for cmd, p, size in load_commands(0):
    if cmd == 0x80000035:  # LC_FILESET_ENTRY
        vmaddr, fileoff, entryoff = struct.unpack_from("<QQQ", data, p + 8)
        end = data.index(b"\x00", p + entryoff)
        name = data[p + entryoff:end].decode()
        entries.append((name, vmaddr, fileoff))

target = sys.argv[1] if len(sys.argv) > 1 else "AppleDiskImages2"
for name, vmaddr, fileoff in entries:
    if target.lower() in name.lower():
        print(f"FILESET {name} vmaddr={vmaddr:#x} fileoff={fileoff:#x}")
        # symtab of this entry
        for cmd, p, size in load_commands(fileoff):
            if cmd == 0x2:  # LC_SYMTAB
                symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", data, p + 8)
                print(f"  symtab off={symoff} nsyms={nsyms}")
                hits = []
                for i in range(nsyms):
                    n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", data, symoff + i * 16)
                    if n_strx == 0 or n_value == 0:
                        continue
                    send = data.index(b"\x00", stroff + n_strx)
                    sname = data[stroff + n_strx:send].decode("utf-8", "replace")
                    if any(k in sname for k in ("createDriveInKernel", "_di_root_image", "handleStart", "KDIFileBackingStore", "IOHDIXController")):
                        hits.append((n_value, sname))
                for v, s in sorted(hits):
                    print(f"  {v:#x}  {s}")
