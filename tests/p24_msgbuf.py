#!/usr/bin/env python3
"""Phase 24: extract the XNU msgbuf (ring buffer) from the p24 final dump.

Finds all timestamped log lines matching [  123.456789]:, reconstructs
each line, then orders them by ring position: the ring is a contiguous
region in file order; the wrap point is where the timestamp drops.
Usage: p24_msgbuf.py <dump> [out.txt]
"""
import re
import sys

DUMP = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else "p24_c1_msgbuf.txt"
data = open(DUMP, "rb").read()
N = len(data)
print(f"dump {N} B")

pat = re.compile(rb"\[\s*(\d+)\.(\d{6})\]:")
hits = []  # (file_off, ts_float, line_text)
for m in pat.finditer(data):
    # line = from match start to next \n (cap 2000 B)
    start = m.start()
    end = data.find(b"\n", start, start + 2000)
    if end == -1:
        end = start + 200
    line = data[start:end].decode("ascii", "replace")
    ts = float(m.group(1)) + float(m.group(2)) / 1e6
    hits.append((start, ts, line))
print(f"{len(hits)} timestamped lines")

# The ring: file order is ring order except for one wrap where ts drops.
# Find the biggest ts drop between consecutive hits in file order.
if hits:
    worst = None
    for a, b in zip(hits, hits[1:]):
        drop = a[1] - b[1]
        if worst is None or drop > worst[0]:
            worst = (drop, a, b)
    print(f"largest ts drop in file order: {worst[0]:.3f}s "
          f"({worst[1][1]:.3f} -> {worst[2][1]:.3f}) at file {worst[2][0]:#x}")
    # rotate so output starts just after the wrap
    idx = hits.index(worst[2])
    ordered = hits[idx:] + hits[:idx]
else:
    ordered = hits

with open(OUT, "w") as f:
    for off, ts, line in ordered:
        f.write(line + "\n")
print(f"wrote {OUT}: {len(ordered)} lines, "
      f"ts {ordered[0][1]:.3f} .. {ordered[-1][1]:.3f}" if ordered else "empty")

# keyword summary
text = "\n".join(l for _, _, l in ordered)
for kw in ("userspace boot", "load_init_program", "BSD root", "pid 2 exited",
           "fsck", "launchd", "DSMOS", "IOConsoleUsers", "loginwindow",
           "WindowServer", "panic", "hash mismatch", "CoreAnalytics",
           "shared_region", "img4", "os.dmg", "app.dmg", "Preboot",
           "apfs_announce", "decmpfs", "UserAMFI", "core dump"):
    c = text.count(kw)
    print(f"  {kw!r}: {c}")
