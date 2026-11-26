#!/usr/bin/env python3
# Fill cases.swift `e:` fields from the Python model (model_expected.txt)
# instead of the oracle — used only to classify the PRE-FIX engine's
# behaviour (THROW vs wrong value) while qemu-aarch64 is unavailable.
# merge_expected.py later overwrites with oracle values and asserts
# model == oracle for every case.
import re

model = {}
for l in open("model_expected.txt"):
    p = l.split()
    model[p[0]] = (int(p[1], 16), int(p[2], 16))

src = open("cases.swift").read()
def fill(m):
    name = m.group(1)
    lo, hi = model[name]
    return re.sub(r"e: \([^)]*\)", f"e: (0x{lo:016X}, 0x{hi:016X})", m.group(0))
src = re.sub(r'Case\(name: "([a-z0-9_]+)"[^\n]*', fill, src)
open("cases.swift", "w").write(src)
print(f"model expected merged for {len(model)} cases")
