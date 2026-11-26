#!/usr/bin/env python3
"""Reconstruct chronological order of a ring-buffer log region and
summarize: newest lines, unique non-repetitive lines.

Usage: rotate_log.py <region.txt> [tail_n]
"""
import re
import sys
from collections import Counter

path = sys.argv[1]
tail_n = int(sys.argv[2]) if len(sys.argv) > 2 else 40
text = open(path, errors="replace").read()
lines = text.split("\n")
ts_re = re.compile(r"^\[\s*(\d+\.\d+)\]:")

stamped = []
for i, l in enumerate(lines):
    m = ts_re.match(l)
    if m:
        stamped.append((i, float(m.group(1)), l))
print(f"stamped lines: {len(stamped)} of {len(lines)}")

# Find the wrap: largest downward jump between consecutive stamped lines.
wrap_after = None
max_drop = 0.0
for k in range(len(stamped) - 1):
    drop = stamped[k][1] - stamped[k + 1][1]
    if drop > max_drop:
        max_drop = drop
        wrap_after = k
print(f"wrap after stamped #{wrap_after} (drop {max_drop:.3f}s)")

# Chronological order of stamped lines: start just after the wrap.
order = stamped[wrap_after + 1:] + stamped[:wrap_after + 1]
print(f"chronological ts: {order[0][1]} .. {order[-1][1]}")
print(f"=== NEWEST {tail_n} LINES (chronological) ===")
for _, s, l in order[-tail_n:]:
    print(f"  {l}")

norm = Counter()
first = {}
last = {}
for _, s, l in order:
    key = ts_re.sub("[T]:", l)
    key = re.sub(r"0x[0-9a-fA-F]+", "0xPTR", key)
    key = re.sub(r"\b\d+\b", "N", key)
    norm[key] += 1
    first.setdefault(key, s)
    last[key] = s
print(f"=== UNIQUE NORMALIZED: {len(norm)} ===")
for key, cnt in sorted(norm.items(), key=lambda kv: -kv[1]):
    print(f"  [x{cnt} {first[key]}..{last[key]}] {key}")
