import re, sys
data = open("home_p30/dram_fpend_cycle1.bin", "rb").read()
pat = b"auearlyboot"
hits = []
i = data.find(pat)
while i != -1 and len(hits) < 40:
    hits.append(i)
    i = data.find(pat, i + 1)
print(f"{len(hits)} hits (PA = off + 0x70000000)")
for h in hits:
    lo = max(0, h - 200); hi = min(len(data), h + 300)
    chunk = data[lo:hi]
    strs = re.findall(rb"[ -~]{4,}", chunk)
    joined = b" | ".join(strs).decode("ascii", "replace")
    print(f"@PA {h + 0x70000000:#x}: {joined[:400]}")
    print()
