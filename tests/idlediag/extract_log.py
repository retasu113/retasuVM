#!/usr/bin/env python3
"""Grow the full kernel-log text region around an anchor offset and
analyze it: unique lines (deduped), first/last lines, keyword hits.

Usage: extract_log.py <dump.bin> <anchor_offset_hex> [out.txt]
A byte counts as text if printable ASCII or \\n\\r\\t. Region grows
while every 256-byte window has >=85% text bytes (gaps of binary up to
~38 B tolerated per window).
"""
import re
import sys
from collections import Counter

path = sys.argv[1]
anchor = int(sys.argv[2], 0)
out = sys.argv[3] if len(sys.argv) > 3 else None
data = open(path, "rb").read()

TEXT = set(b"\n\r\t") | set(range(0x20, 0x7F))


def text_frac(chunk):
    return sum(1 for b in chunk if b in TEXT) / max(1, len(chunk))


W = 256
start = anchor
while start - W >= 0 and text_frac(data[start - W:start]) >= 0.85:
    start -= W
end = anchor
while end + W <= len(data) and text_frac(data[end:end + W]) >= 0.85:
    end += W
print(f"region: 0x{start:x} .. 0x{end:x} ({end - start} bytes)")

raw = data[start:end]
text = raw.decode("ascii", "replace")
lines = text.split("\n")
print(f"lines: {len(lines)}")

if out:
    with open(out, "w") as f:
        f.write(text)
    print(f"region text written to {out}")

ts = re.compile(r"^\[\s*(\d+\.\d+)\]:")


def stamp(l):
    m = ts.match(l)
    return float(m.group(1)) if m else None


stamped = [(stamp(l), l) for l in lines]
valid = [s for s, _ in stamped if s is not None]
if valid:
    print(f"timestamp range: {min(valid)} .. {max(valid)}")

print("=== FIRST 15 LINES ===")
for l in lines[:15]:
    print(f"  {l}")
print("=== LAST 30 LINES ===")
for l in lines[-30:]:
    print(f"  {l}")

norm = Counter()
first_seen = {}
last_seen = {}
for s, l in stamped:
    key = re.sub(r"\[\s*\d+\.\d+\]:", "[T]:", l)
    key = re.sub(r"0x[0-9a-fA-F]+", "0xPTR", key)
    key = re.sub(r"\b\d+\b", "N", key)
    norm[key] += 1
    if key not in first_seen:
        first_seen[key] = s
    last_seen[key] = s
print(f"=== UNIQUE NORMALIZED LINES: {len(norm)} ===")
for key, cnt in norm.most_common(10000):
    if cnt == 1:
        tag = "once"
    else:
        tag = f"x{cnt} first={first_seen[key]} last={last_seen[key]}"
    print(f"  [{tag}] {key}")
