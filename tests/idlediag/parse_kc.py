#!/usr/bin/env python3
"""Minimal Mach-O 64 parser for the kernelcache: segments + LC_SYMTAB symbols.

Pure byte parsing (no code from the file is executed). Writes:
  kc_syms_mine.json  : {"segs":[...], "syms":[[value,"name"],...] sorted by value}
Usage: parse_kc.py <kernelcache.macho> <out.json>
"""
import json
import struct
import sys

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_FILESET_ENTRY = 0x35


def parse(data, base=0, depth=0):
    magic = struct.unpack_from("<I", data, base)[0]
    if magic != 0xFEEDFACF:
        raise ValueError(f"bad magic {magic:#x} at {base}")
    (_, _, _, _, ncmds, sizeofcmds, _, _) = struct.unpack_from("<IiiIIIII", data, base)
    off = base + 32
    segs = []
    symtab = None
    filesets = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        cmd &= 0x7FFFFFFF  # strip LC_REQ_DYLD
        if cmd == LC_SEGMENT_64:
            segname = data[off + 8:off + 24].split(b"\0")[0].decode("ascii", "replace")
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", data, off + 24)
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            sects = []
            so = off + 72
            for i in range(nsects):
                sname = data[so + 80 * i:so + 80 * i + 16].split(b"\0")[0].decode("ascii", "replace")
                sgname = data[so + 80 * i + 16:so + 80 * i + 32].split(b"\0")[0].decode("ascii", "replace")
                saddr, ssize, soffset = struct.unpack_from("<QQI", data, so + 80 * i + 32)
                sects.append({"sect": sname, "seg": sgname, "addr": saddr, "size": ssize, "off": soffset})
            segs.append({"seg": segname, "vmaddr": vmaddr, "vmsize": vmsize,
                         "fileoff": fileoff, "filesize": filesize, "sects": sects})
        elif cmd == LC_SYMTAB:
            # NOTE: in fileset entries, symtab offsets are absolute (file start),
            # verified empirically on com.apple.kernel (first sym = _Assert).
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", data, off + 8)
            symtab = (symoff, nsyms, stroff, strsize)
        elif cmd == LC_FILESET_ENTRY:
            # fileset_entry_command: vmaddr@+8, fileoff@+16, entry_id lc_str@+24
            foff = struct.unpack_from("<Q", data, off + 16)[0]
            name_off = struct.unpack_from("<I", data, off + 24)[0]
            nm = data[off + name_off:data.index(b"\0", off + name_off)].decode("ascii", "replace")
            filesets.append({"name": nm, "fileoff": base + foff})
        off += cmdsize
    syms = []
    if symtab:
        symoff, nsyms, stroff, strsize = symtab
        for i in range(nsyms):
            n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", data, symoff + 16 * i)
            if n_strx == 0 or n_value == 0:
                continue
            end = data.index(b"\0", stroff + n_strx)
            name = data[stroff + n_strx:end].decode("ascii", "replace")
            syms.append([n_value, name])
    return segs, syms, filesets


def main():
    data = open(sys.argv[1], "rb").read()
    segs, syms, filesets = parse(data)
    print(f"top-level: {len(segs)} segments, {len(syms)} syms, {len(filesets)} fileset entries")
    for s in segs:
        print(f"  SEG {s['seg']:20s} vmaddr=0x{s['vmaddr']:x} vmsize=0x{s['vmsize']:x} fileoff=0x{s['fileoff']:x} filesize=0x{s['filesize']:x}")
    for fe in filesets[:5]:
        print(f"  FILESET {fe['name']} @fileoff 0x{fe['fileoff']:x}")
    # If this is a fileset container, the real kernel is usually the first entry;
    # merge syms/segs from each entry, offsetting nothing (VAs are absolute).
    all_syms = list(syms)
    all_segs = list(segs)
    for fe in filesets:
        try:
            s2, sy2, _ = parse(data, fe["fileoff"], 1)
            all_segs.extend(s2)
            all_syms.extend(sy2)
            print(f"  entry {fe['name']}: +{len(sy2)} syms, +{len(s2)} segs")
        except Exception as e:
            print(f"  entry {fe['name']}: parse failed: {e}")
    all_syms.sort()
    json.dump({"segs": all_segs, "syms": all_syms}, open(sys.argv[2], "w"))
    print(f"wrote {sys.argv[2]}: {len(all_syms)} syms total")


if __name__ == "__main__":
    main()
