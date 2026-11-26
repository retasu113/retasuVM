#!/usr/bin/env python3
"""Phase 26: symbolize the FIRE PCB's PC 0x100c947c0 in fsck's binary by
reading fsck's Mach-O from RAM via a TTBR0 walk (fsck root 0x85b70000,
from fsck pmap ttep +0x08). Parses LC_SEGMENT_64 + LC_SYMTAB, finds the
nearest symbol at/below the PC, and lists fsck's segments.
Run on the PC. Usage: p26_fscksym.py <dump>
Outputs: p26_fscksym_out.txt
"""
import struct
import sys

sys.path.insert(0, ".")
from p4_lib import Dump, walk

DUMP = sys.argv[1]
ROOT = 0x85B70000  # fsck TTBR0 root (pmap ttep)
BASE = 0x100C0C000  # fsck executable base (map min_offset)
PC = 0x100C947C0
SP = 0x16F1F3CF8

d = Dump(DUMP)
out = open("p26_fscksym_out.txt", "w")


def log(s=""):
    print(s)
    out.write(s + "\n")


def read_uva(va, n):
    # root_level=1 (L1 root, index bits [46:36]) — same as the kernel
    # TTBR1 walk in p5_common; TTBR0 uses the same geometry for a 48-bit VA.
    pa = walk(d, ROOT, va, 14, 1)
    if pa is None:
        return None
    return d.read_pa(pa, n)


def u64_uva(va):
    b = read_uva(va, 8)
    return struct.unpack("<Q", b)[0] if b else None


# --- Mach-O header at BASE ---
hdr = read_uva(BASE, 0x1000)
if hdr is None or hdr[:4] != b"\xcf\xfa\xed\xfe":
    log(f"FAIL: no Mach-O magic at {BASE:#x} (got {hdr[:4] if hdr else None})")
    sys.exit(1)
magic, cputype, cpusub, ftype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<IIIIIIII", hdr, 0)
log(f"Mach-O @ {BASE:#x}: cputype={cputype:#x} filetype={ftype} ncmds={ncmds} sizeofcmds={sizeofcmds:#x}")
off = 32
segs = []
symtab = None
for i in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<II", hdr, off)
    if cmd == 0x19:  # LC_SEGMENT_64
        segname = hdr[off + 8:off + 24].split(b"\x00")[0].decode()
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", hdr, off + 24)
        segs.append((segname, vmaddr, vmsize, fileoff, filesize))
        log(f"  seg {segname}: vmaddr={vmaddr:#x} vmsize={vmsize:#x} fileoff={fileoff:#x} filesize={filesize:#x}")
    elif cmd == 0x2:  # LC_SYMTAB
        symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", hdr, off + 8)
        symtab = (symoff, nsyms, stroff, strsize)
        log(f"  LC_SYMTAB: symoff={symoff:#x} nsyms={nsyms} stroff={stroff:#x} strsize={strsize:#x}")
    off += cmdsize

# slide = BASE - __TEXT vmaddr (unslid)
text = [s for s in segs if s[0] == "__TEXT"]
if not text:
    log("FAIL: no __TEXT segment")
    sys.exit(1)
tname, tvmaddr, tvmsize, tfileoff, tfilesize = text[0]
slide = BASE - tvmaddr
log(f"\n__TEXT unslid vmaddr={tvmaddr:#x}; slide={slide:#x}")
unslid_pc = PC - slide
log(f"PC {PC:#x} unslid = {unslid_pc:#x}")

# find segment + file offset for the PC
for name, vmaddr, vmsize, fileoff, filesize in segs:
    if vmaddr <= unslid_pc < vmaddr + vmsize:
        foff = fileoff + (unslid_pc - vmaddr)
        log(f"PC in segment {name}: file offset {foff:#x}")
        break
else:
    log("PC is in NO segment (unslid)")

# --- symbol table: read symtab + strtab from RAM via file offsets ---
# The file is mapped in the __TEXT/__LINKEDIT segments; translate a file
# offset to a VA: find the segment containing it, VA = BASE + (seg.vmaddr - tvmaddr) + (foff - seg.fileoff).
def fileoff_to_va(foff):
    for name, vmaddr, vmsize, fileoff, filesize in segs:
        if fileoff <= foff < fileoff + filesize:
            return BASE + (vmaddr - tvmaddr) + (foff - fileoff)
    return None


if symtab:
    symoff, nsyms, stroff, strsize = symtab
    log(f"\nreading {nsyms} symtab entries...")
    best = None  # (sym_value_unslid, name)
    for i in range(nsyms):
        va = fileoff_to_va(symoff + i * 16)
        if va is None:
            continue
        ent = read_uva(va, 16)
        if ent is None:
            continue
        n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", ent, 0)
        if n_type & 0x0E != 0x0E and n_type != 0x0F:
            # only consider defined symbols (N_SECT); skip undefined/debug
            if n_type & 0x0E == 0x00 and n_sect == 0:
                continue
        if n_value == 0:
            continue
        # read the name
        sva = fileoff_to_va(stroff + n_strx)
        if sva is None:
            continue
        raw = read_uva(sva, 128)
        if raw is None:
            continue
        end = raw.find(b"\x00")
        name = raw[:end if end >= 0 else 128].decode("utf-8", "replace")
        if n_value <= unslid_pc:
            if best is None or n_value > best[0]:
                best = (n_value, name, n_type, n_sect)
    if best:
        v, name, ntype, nsect = best
        log(f"\nNEAREST SYMBOL at/below PC: {name} (unslid {v:#x}, PC offset +{unslid_pc - v:#x}, type={ntype:#x} sect={nsect})")
    else:
        log("\nNo symbol found at/below PC (symtab may be stripped or unreadable)")
else:
    log("\nNo LC_SYMTAB — binary is stripped")
out.close()
print("wrote p26_fscksym_out.txt")
