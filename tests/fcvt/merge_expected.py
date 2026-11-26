#!/usr/bin/env python3
# Merge oracle_out.txt (hex dump: one 16B slot per case) into cases.swift,
# filling each Case's `e:` field. Cross-check every oracle result against
# the independent exact Python model in model_expected.txt: any
# disagreement means the model - not just the Swift port - is wrong.
import re, struct

raw = open("oracle_out.txt", "rb").read().replace(b"\x00", b"").decode()
names = [l.strip() for l in open("cases_list.txt") if l.strip()]
assert len(raw) == len(names) * 32, f"{len(raw)} hex chars vs {len(names)} cases"
lines = [raw[i * 32:(i + 1) * 32] for i in range(len(names))]

expected = {}
for name, line in zip(names, lines):
    b = bytes.fromhex(line)
    lo, hi = struct.unpack("<QQ", b)
    assert hi == 0, f"{name}: oracle output high qword nonzero: {hi:#x}"
    expected[name] = lo

model = {}
for l in open("model_expected.txt"):
    parts = l.split()
    model[parts[0]] = int(parts[1], 16)

bad = 0
for name in names:
    if model[name] != expected[name]:
        print(f"MODEL != ORACLE {name}: model=0x{model[name]:016X} oracle=0x{expected[name]:016X}")
        bad += 1
print(f"model vs oracle: {len(names) - bad}/{len(names)} agree")
assert bad == 0, "model disagrees with oracle - fix the model first"

src = open("cases_placeholder.swift").read()
out = []
for line in src.splitlines():
    m = re.match(r'\s*Case\(name: "([^"]+)", .*e: 0\),$', line)
    if m:
        line = line.replace("e: 0)", f"e: 0x{expected[m.group(1)]:016X})")
    out.append(line)
open("cases.swift", "w").write("\n".join(out) + "\n")
print("cases.swift written")

# Runtime TSV (the Swift array literal for ~3900 cases OOMs swiftc;
# the harness parses this file instead).
import csv
rows = {}
for line in out:
    m = re.match(r'\s*Case\(name: "([^"]+)", word: 0x([0-9A-F]+), kind: (\d+), '
                 r'rn: (\d+), rd: (\d+), src: 0x([0-9A-F]+), e: 0x([0-9A-F]+)\)', line)
    if m:
        rows[m.group(1)] = m.groups()
with open("cases.txt", "w") as f:
    for name in names:
        g = rows[name]
        f.write(f"{name} 0x{g[1]} {g[2]} {g[3]} {g[4]} 0x{g[5]} 0x{g[6]}\n")
print("cases.txt written")
