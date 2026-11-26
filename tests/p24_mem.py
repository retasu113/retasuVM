#!/usr/bin/env python3
"""Phase 24: read the spinning process's userspace memory from the p24
final dump via its TTBR0 (root PA 0x85bcc000, from the capture's
ttbr0el1=0x4000085bcc000; top bits are the ASID).

Verifies every captured value against RAM, dumps the full FILE struct,
the __suio + context, the iov entries, the stack frame, the data buffer,
extracts __sfvwrite/__vfprintf/__swrite code bytes for local disassembly,
and scans the dump for the TTBR0-root qword (pmap struct) and the spin
kernel-stack base qword (thread struct).

Usage: p24_mem.py <dump>   (run on the PC; dump is 4 GiB)
Outputs: p24_mem_out.txt, p24_sfvwrite.bin, p24_vfprintf.bin,
         p24_swrite.bin, p24_swrite2.bin (code bytes)
"""
import struct
import sys

DUMP = sys.argv[1]
DRAM = 0x70000000
TTBR0 = 0x85bcc000
data = open(DUMP, "rb").read()
N = len(data)
print(f"dump {N} B")
out = open("p24_mem_out.txt", "w")

def log(s=""):
    print(s)
    out.write(s + "\n")

def u64(off):
    return struct.unpack_from("<Q", data, off)[0]

def walk(root_pa, va, root_level=1):
    granule, idx_bits, page_size = 14, 11, 1 << 14
    table_pa = root_pa
    for level in range(root_level, 4):
        shift = granule + (3 - level) * idx_bits
        idx = (va >> shift) & ((1 << idx_bits) - 1)
        if level == root_level and root_level == 0:
            idx = (va >> 47) & 0x1
        off = table_pa - DRAM + idx * 8
        if off < 0 or off + 8 > N:
            return None
        entry = u64(off)
        if entry & 0x1 == 0:
            return None
        typ = entry & 0x3
        if level == 3:
            if typ != 0x3:
                return None
            return (entry & 0x0000FFFFFFFFC000) + (va & (page_size - 1))
        if typ == 0x3:
            table_pa = entry & 0x0000FFFFFFFFC000
            continue
        if typ == 0x1:
            oa_mask = (~0) & ~((1 << shift) - 1) & 0x0000FFFFFFFFFFFF
            return (entry & oa_mask) + (va & ((1 << shift) - 1))
        return None
    return None

def read_va(va, n):
    """Read n bytes at userspace VA via TTBR0 (16K pages)."""
    buf = b""
    while len(buf) < n:
        cur = va + len(buf)
        pa = walk(TTBR0, cur & ~0x3FFF)
        if pa is None:
            return None
        off_in_page = cur & 0x3FFF
        take = min(n - len(buf), 0x4000 - off_in_page)
        buf += data[pa - DRAM + off_in_page: pa - DRAM + off_in_page + take]
    return buf

def q_at(va):
    b = read_va(va, 8)
    return struct.unpack("<Q", b)[0] if b else None

def d_at(va):
    b = read_va(va, 4)
    return struct.unpack("<I", b)[0] if b else None

def h_at(va):
    b = read_va(va, 2)
    return struct.unpack("<H", b)[0] if b else None

# ---------- 1. VA -> PA walks ----------
FILE_VA = 0x16efd2d10
UIO_VA = 0x16efd2a38
IOVCUR = 0x16efd2d20
DATA_VA = 0x16efd34a0
X29 = 0x16efd28f8
CODE_VA = 0x19bed097c   # __sfvwrite entry (slid)
LR_VA = 0x19bed0acc
log("--- VA -> PA (TTBR0 0x85bcc000) ---")
for name, va in (("FILE x19", FILE_VA), ("uio x20", UIO_VA),
                 ("iovcur x26", IOVCUR), ("data x22", DATA_VA),
                 ("x29 frame", X29), ("__sfvwrite", CODE_VA),
                 ("LR (__vfprintf)", LR_VA),
                 ("x4 0x100e2dcee", 0x100e2dcee),
                 ("x16 0x19c0752c0", 0x19c0752c0),
                 ("x17 0x20b064e20", 0x20b064e20)):
    pa = walk(TTBR0, va)
    log(f"  {name:20s} VA {va:#x} -> PA {pa if pa is None else hex(pa)}")

# ---------- 2. __suio ----------
log("\n--- __suio @ x20 = 0x16efd2a38 (capture: iov=0x16efd2d10 iovcnt=1862085200 resid=1) ---")
raw = read_va(UIO_VA, 0x40)
for i in range(0, 0x40, 8):
    v = struct.unpack_from("<Q", raw, i)[0]
    log(f"  uio+{i:#04x} = {v:#018x}")
log(f"  uio_iov   = {q_at(UIO_VA):#x}   (capture 0x16efd2d10)")
log(f"  uio_iovcnt= {d_at(UIO_VA+8)}   (capture 1862085200 = 0x6efd2e90)")
log(f"  uio_resid = {d_at(UIO_VA+0xC)} (capture 1)")
log(f"  uio_iov == FILE* ? {q_at(UIO_VA) == FILE_VA}")

# ---------- 3. FILE struct ----------
log("\n--- FILE @ x19 = 0x16efd2d10 (capture: _p=0x16efd34a8 _r=0 _w=0 _flags=0x208 _file=65535) ---")
fraw = read_va(FILE_VA, 0xA0)
def fq(off):
    return struct.unpack_from("<Q", fraw, off)[0]
def fd(off):
    return struct.unpack_from("<I", fraw, off)[0]
def fh(off):
    return struct.unpack_from("<H", fraw, off)[0]
log(f"  _p        +0x00 = {fq(0):#x}")
log(f"  _r        +0x08 = {fd(8)}")
log(f"  _w        +0x0C = {fd(0xC)}")
log(f"  _flags    +0x10 = {fh(0x10):#x}")
log(f"  _file     +0x12 = {fh(0x12)} ({fh(0x12) - 65536 if fh(0x12) >= 32768 else fh(0x12)} as signed short)")
log(f"  _bf._base +0x18 = {fq(0x18):#x}")
log(f"  _bf._size +0x20 = {fd(0x20)}")
log(f"  _lbfsize  +0x28 = {fd(0x28)}")
log(f"  _cookie   +0x30 = {fq(0x30):#x}")
log(f"  _close    +0x38 = {fq(0x38):#x}")
log(f"  _read     +0x40 = {fq(0x40):#x}")
log(f"  _seek     +0x48 = {fq(0x48):#x}")
log(f"  _write    +0x50 = {fq(0x50):#x}")
log(f"  _ext.base +0x58 = {fq(0x58):#x}")
log(f"  _ext.size +0x60 = {fd(0x60)}")
log(f"  _up       +0x68 = {fq(0x68):#x}")
log(f"  _ur       +0x70 = {fd(0x70)}")
log(f"  _ubuf     +0x74 = {fraw[0x74:0x77].hex()}")
log(f"  _nbuf     +0x77 = {fraw[0x77:0x78].hex()}")
log(f"  _lb.base  +0x78 = {fq(0x78):#x}")
log(f"  _lb.size  +0x80 = {fd(0x80)}")
log(f"  _blksize  +0x88 = {fd(0x88)}")
log(f"  _offset   +0x90 = {fq(0x90):#x}")
log(f"  _extra    +0x98 = {fq(0x98):#x}")
log(f"  _p - _bf._base = {fq(0) - fq(0x18)}  (bytes consumed in buffer)")
log(f"  _write fn slid VA {fq(0x50):#x} -> unslid {fq(0x50) - 0x1bbc8000:#x} (if in cache)")
for fn_name, fn_va in (("_close", fq(0x38)), ("_read", fq(0x40)),
                       ("_seek", fq(0x48)), ("_write", fq(0x50))):
    if fn_va:
        log(f"  {fn_name} fn VA {fn_va:#x} walks to PA {walk(TTBR0, fn_va)}")

# ---------- 4. iov entries ----------
log("\n--- iov entries at uio_iov = 0x16efd2d10 (= FILE base) ---")
for i in range(4):
    ptr = q_at(FILE_VA + i * 16)
    ln = q_at(FILE_VA + i * 16 + 8)
    log(f"  iov[{i}] @ {FILE_VA + i*16:#x}: ptr={ptr:#x} len={ln if ln is None else hex(ln)}")
log("  iov[cur] via watchpoint formula (ptr=[x26-0x10], len=[x26+0x08]):")
log(f"    ptr = q@{IOVCUR - 0x10:#x} = {q_at(IOVCUR - 0x10):#x}")
log(f"    len = q@{IOVCUR + 0x08:#x} = {q_at(IOVCUR + 0x08):#x}")

# ---------- 5. stack frame ----------
log("\n--- stack frame at x29 = 0x16efd28f8 (saved regs) ---")
for name, va in (("saved x19", X29 - 8), ("saved x20", X29 - 0x10),
                 ("saved x21", X29 - 0x18), ("saved x22", X29 - 0x20),
                 ("saved x23", X29 - 0x28), ("saved x24", X29 - 0x30),
                 ("saved x25", X29 - 0x38), ("saved x26", X29 - 0x40),
                 ("saved x27", X29 - 0x48), ("saved x28", X29 - 0x50),
                 ("saved x29", X29), ("saved x30 (LR)", X29 + 8)):
    log(f"  {name:18s} [{va:#x}] = {q_at(va) if q_at(va) is None else hex(q_at(va))}")
log("  non-zero qwords x29-0x200 .. x29+0x100:")
for va in range(X29 - 0x200, X29 + 0x100, 8):
    v = q_at(va)
    if v:
        log(f"    [{va:#x}] = {v:#018x}")

# ---------- 6. data buffer ----------
log("\n--- data buffer at x22 = 0x16efd34a0 (first 256 B) ---")
buf = read_va(DATA_VA, 256)
log(f"  hex: {buf[:64].hex()}")
log(f"  repr: {buf!r}")

# ---------- 7. code extraction ----------
log("\n--- code extraction (for local capstone disassembly) ---")
def extract(va, n, fname):
    b = read_va(va, n)
    if b is None:
        log(f"  {fname}: VA {va:#x} NOT MAPPED")
        return
    open(fname, "wb").write(b)
    log(f"  {fname}: {n} B from VA {va:#x} (unslid {va - 0x1bbc8000:#x})")
extract(0x19bed097c, 0x39C, "p24_sfvwrite.bin")          # __sfvwrite
extract(0x19becda68, 0x6000, "p24_vfprintf.bin")        # __vfprintf (0x180305a68)
extract(0x19beddc60, 0x200, "p24_swrite.bin")           # 0x180315c60
extract(0x19beddc30, 0x200, "p24_swrite2.bin")          # 0x180315c30
extract(0x19bed0acc - 0x100, 0x200, "p24_callsite.bin") # around the LR call site

# ---------- 8. TTBR0-root qword scan (pmap struct) ----------
log("\n--- scan: qword 0x85bcc000 (TTBR0 root) occurrences ---")
pat = struct.pack("<Q", 0x85bcc000)
occs = []
i = data.find(pat)
while i != -1:
    if i % 8 == 0:
        occs.append(i)
    i = data.find(pat, i + 1)
log(f"  {len(occs)} aligned occurrence(s)")
for off in occs[:20]:
    pa = DRAM + off
    log(f"  @PA {pa:#x} (file {off:#x})")
    for j in range(-0x20, 0x40, 8):
        v = struct.unpack_from("<Q", data, off + j)[0]
        if v:
            log(f"      {pa + j:#x} {v:#018x}")

# ---------- 9. spin kernel-stack base qword scan ----------
SPIN_STACK_BASE = 0xFFFFFEB9A25B4000  # spEL1 0xFFFFFEB9A25B8000 - 0x4000
log(f"\n--- scan: qword {SPIN_STACK_BASE:#x} (spin kernel-stack base) ---")
pat = struct.pack("<Q", SPIN_STACK_BASE)
occs = []
i = data.find(pat)
while i != -1:
    if i % 8 == 0:
        occs.append(i)
    i = data.find(pat, i + 1)
log(f"  {len(occs)} aligned occurrence(s)")
for off in occs[:20]:
    pa = DRAM + off
    log(f"  @PA {pa:#x} (file {off:#x})")
    for j in range(-0x40, 0x48, 8):
        v = struct.unpack_from("<Q", data, off + j)[0]
        if v:
            log(f"      {pa + j:#x} {v:#018x}")

out.close()
print("wrote p24_mem_out.txt")
