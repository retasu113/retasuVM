#!/usr/bin/env python3
"""Summarize the service-start front of a rotated msgbuf region.

Usage: front.py <region.txt>
Emits: ts span, IOConfigThread id census, and every substantive
(non spin-fail-safe) line in chronological order with its guest ts.
"""
import re
import sys

text = open(sys.argv[1], errors="replace").read()
lines = text.split("\n")
ts_re = re.compile(r"^\[\s*(\d+\.\d+)\]:")

stamped = []
for l in lines:
    m = ts_re.match(l)
    if m:
        stamped.append((float(m.group(1)), l))

# rotate at the largest downward jump
wrap = 0
max_drop = 0.0
for k in range(len(stamped) - 1):
    d = stamped[k][0] - stamped[k + 1][0]
    if d > max_drop:
        max_drop = d
        wrap = k
order = stamped[wrap + 1:] + stamped[:wrap + 1]

print(f"stamped={len(order)} ts_span={order[0][0]:.1f}..{order[-1][0]:.1f}")

ids = {}
for s, l in order:
    for m in re.finditer(r"IOConfigThread_'([^']+)' \[([0-9a-f]+)\]", l):
        ids.setdefault(m.group(2), m.group(1))
print(f"config_thread_ids={len(ids)}: " +
      ", ".join(f"{k}={v}" for k, v in sorted(ids.items())))

print("=== substantive lines (chronological) ===")
for s, l in order:
    if "triggered fail-safe" in l:
        continue
    print(f"{s:.1f} {ts_re.sub('', l).strip()}")
