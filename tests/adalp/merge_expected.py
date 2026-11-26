#!/usr/bin/env python3
# Merge oracle_out.txt (hex lines: 3 ID-reg slots, then one 16B line per
# case) into cases.swift, filling each Case's `e:` field. Also cross-check
# every oracle result against the independent Python model in
# model_expected.txt (derived from QEMU gengvec.c semantics): any
# disagreement means the model — not just the Swift port — is wrong.
import re, struct

raw = open("oracle_out.txt", "rb").read().replace(b"\x00", b"").decode()
names = [l.strip() for l in open("cases_list.txt") if l.strip()]
assert len(raw) == (3 + len(names)) * 32, f"{len(raw)} hex chars vs {len(names)} cases"
lines = [raw[i * 32:(i + 1) * 32] for i in range(3 + len(names))]

def slot_u64pair(line):
    b = bytes.fromhex(line)
    lo = struct.unpack("<Q", b[0:8])[0]
    hi = struct.unpack("<Q", b[8:16])[0]
    return lo, hi

isar0 = struct.unpack("<Q", bytes.fromhex(lines[0])[0:8])[0]
print(f"oracle ID_AA64ISAR0_EL1 = 0x{isar0:016x}")

expected = {}
for name, line in zip(names, lines[3:]):
    expected[name] = slot_u64pair(line)

model = {}
for l in open("model_expected.txt"):
    parts = l.split()
    model[parts[0]] = (int(parts[1], 16), int(parts[2], 16))

bad = 0
for name in names:
    if model[name] != expected[name]:
        bad += 1
        print(f"MODEL MISMATCH {name}: model={model[name]} oracle={expected[name]}")
print(f"model vs oracle: {len(names) - bad}/{len(names)} agree")
assert bad == 0, "python model disagrees with oracle — do not write Swift yet"

src = open("cases.swift").read()
def fill(m):
    name = m.group(1)
    lo, hi = expected[name]
    return m.group(0).replace("e: (0, 0)", f"e: (0x{lo:016X}, 0x{hi:016X})")
src = re.sub(r'Case\(name: "([a-z0-9_]+)"[^\n]*', fill, src)
open("cases.swift", "w").write(src)
print(f"merged expected for {len(expected)} cases")
