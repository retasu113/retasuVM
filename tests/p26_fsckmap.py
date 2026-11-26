#!/usr/bin/env python3
"""Phase 26: walk FSCK's vm_map (map VA 0xfffffe101e0018d0, from thread
0xfffffe1df6228040's task) and check whether the FIRE PCB's PC
0x100c947c0 and SP 0x16f1f3cf8 are mapped there. Also dump fsck's pmap
fields around +0x200..+0x230 to locate its TTBR0.
Run on the PC. Usage: p26_fsckmap.py <dump>
Outputs: p26_fsckmap_out.txt
"""
import struct
import sys

sys.path.insert(0, ".")
from p5_common import Ctx

DUMP = sys.argv[1]
MAP = 0xFFFFFE101E0018D0  # fsck map VA
PMAP = 0xFFFFFE2299FE12A0  # fsck pmap VA
PC = 0x100C947C0
SP = 0x16F1F3CF8

ctx = Ctx(DUMP)
out = open("p26_fsckmap_out.txt", "w")


def log(s=""):
    print(s)
    out.write(s + "\n")


def qva(va):
    b = ctx.read_va(va, 8)
    return struct.unpack("<Q", b)[0] if b else None


# --- fsck pmap fields around the TTBR0 offset ---
log(f"fsck pmap @ {PMAP:#x}:")
for off in range(0x1F0, 0x240, 8):
    v = qva(PMAP + off)
    log(f"  pmap+{off:#04x} = {v if v is None else hex(v)}")
log("")

# --- fsck vm_map header ---
hdr = ctx.read_va(MAP, 0x80)
log(f"fsck vm_map @ {MAP:#x}: first 0x80 B")
for off in range(0, 0x80, 8):
    v = struct.unpack_from("<Q", hdr, off)[0]
    log(f"  map+{off:#04x} = {v:#018x}")
HDR = MAP + 0x10
log(f"\nhdr (map+0x10): prev={qva(HDR):#x} next={qva(HDR + 8):#x} "
    f"start={qva(HDR + 0x10):#x} end={qva(HDR + 0x18):#x}")

# --- walk entries ---
first = qva(HDR + 8)
log(f"first entry VA = {first:#x}")
cur = first
seen = set()
ents = []
while cur and 0xFFFFFE0000000000 <= cur <= 0xFFFFFEFFFFFFFFFF and cur not in seen and len(ents) < 5000:
    seen.add(cur)
    raw = ctx.read_va(cur, 0x20)
    if raw is None:
        break
    prev, nxt, start, end = struct.unpack_from("<QQQQ", raw, 0)
    ents.append((start, end, cur))
    if nxt == HDR or nxt == 0:
        break
    cur = nxt
log(f"entries: {len(ents)}")
ents.sort()
for s, e, c in ents:
    marks = []
    if s <= PC < e:
        marks.append("CONTAINS PC")
    if s <= SP < e:
        marks.append("CONTAINS SP")
    m = (" <-- " + ", ".join(marks)) if marks else ""
    log(f"  [{s:#x}, {e:#x}) size={e - s:#x} entry={c:#x}{m}")
pc_hit = [e for e in ents if e[0] <= PC < e[1]]
sp_hit = [e for e in ents if e[0] <= SP < e[1]]
log(f"\nPC {PC:#x} mapped: {bool(pc_hit)} {pc_hit}")
log(f"SP {SP:#x} mapped: {bool(sp_hit)} {sp_hit}")
if sp_hit:
    s, e, c = sp_hit[0]
    log(f"SP stack entry: [{s:#x}, {e:#x}) size={e - s:#x}; end-SP={e - SP:#x} SP-start={SP - s:#x}")
out.close()
print("wrote p26_fsckmap_out.txt")
