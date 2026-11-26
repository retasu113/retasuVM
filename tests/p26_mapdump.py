#!/usr/bin/env python3
"""Phase 26: dump all vm_map entries of launchd's map (p25 dump)."""
import struct
import sys

sys.path.insert(0, ".")
from p5_common import Ctx

DUMP = sys.argv[1]
MAP = 0xFFFFFE101E0016C0  # launchd map VA (from p26_stackmap.py)
HDR = MAP + 0x10
SP = 0x16F1F3CF8

ctx = Ctx(DUMP)


def qva(va):
    b = ctx.read_va(va, 8)
    return struct.unpack("<Q", b)[0] if b else None


first = qva(HDR + 8)
print("first entry", hex(first))
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
print("entries:", len(ents))
ents.sort()
for s, e, c in ents:
    mark = " <-- CONTAINS SP" if s <= SP < e else ""
    print(f"  [{s:#x}, {e:#x}) size={e - s:#x} entry={c:#x}{mark}")
print("max end:", hex(max(e for _, e, _ in ents)) if ents else None)
print("min start:", hex(min(s for s, _, _ in ents)) if ents else None)
