#!/usr/bin/env python3
"""Extract a byte range from a dump and show it as log text.

Usage: extract_span.py <dump.bin> <offset_hex> <len>
Prints boundary context (repr), first 40 lines, last 80 lines.
"""
import sys

path = sys.argv[1]
off = int(sys.argv[2], 0)
ln = int(sys.argv[3], 0)
with open(path, "rb") as f:
    f.seek(max(0, off - 128))
    pre = f.read(128)
    f.seek(off)
    data = f.read(ln)
    post = f.read(128)

print(f"--- 128 B before span: {pre!r}")
print(f"--- 128 B after span:  {post!r}")
text = data.decode("ascii", "replace")
lines = text.split("\n")
print(f"--- span has {len(lines)} lines ---")
print("=== FIRST 40 LINES ===")
for i, l in enumerate(lines[:40]):
    print(f"{i:5d}: {l}")
print("=== LAST 80 LINES ===")
for i, l in enumerate(lines[-80:], start=len(lines) - 80):
    print(f"{i:5d}: {l}")
