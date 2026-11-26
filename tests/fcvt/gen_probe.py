#!/usr/bin/env python3
# Probe set: encodings around the fixed-point FCVT family that must NOT
# execute in our engine.
#  (a) sf=0 with scale6 < 32 (bit15 = 0): QEMU @fcvt32 has a literal 1 at
#      bit15, so these match no pattern -> UNDEF. qemu-aarch64 is run
#      per-word; SIGILL (returncode -4) confirms INVALID.
#  (b) type = 10 (half-precision source): QEMU executes these via the
#      MO_16 helpers, but this engine does not support H anywhere
#      (pre-existing stance, cf. the FCVT fp<->fp branch). The engine
#      must MISS them cleanly, never misroute them as S.
# Emits probe_words.txt ("name word expect": expect = INVALID for (a),
# QEMU_ONLY for (b)) and one tiny .s per (a) word for the oracle probe.
def word(sf, typ, opc6, scale6, rn, rd):
    return ((sf << 31) | (0x1E << 24) | (typ << 22) | (opc6 << 16)
            | (scale6 << 10) | (rn << 5) | rd)

SCVTF, UCVTF, FCVTZS, FCVTZU = 0b000010, 0b000011, 0b011000, 0b011001
OPS = [(SCVTF, "scvtf"), (UCVTF, "ucvtf"), (FCVTZS, "fcvtzs"), (FCVTZU, "fcvtzu")]

rows = []
for opc, opn in OPS:
    for sc in (0, 16, 31):
        rows.append((f"{opn}_sf0_sc{sc}_undef", word(0, 0, opc, sc, 1, 2), "INVALID"))
    rows.append((f"{opn}_hsrc", word(0, 2, opc, 40, 1, 2), "QEMU_ONLY"))
    rows.append((f"{opn}_hsrc64", word(1, 2, opc, 40, 1, 2), "QEMU_ONLY"))

with open("probe_words.txt", "w") as f:
    for name, w, expect in rows:
        f.write(f"{name} 0x{w:08X} {expect}\n")

import os
os.makedirs("probe_oracle", exist_ok=True)
for name, w, expect in rows:
    if expect != "INVALID":
        continue
    with open(f"probe_oracle/{name}.s", "w") as f:
        f.write(f""".text
.globl _start
_start:
    movn x2, #0
    mov w3, #0x3fc00000
    fmov s1, w3
    .word 0x{w:08x}
    mov x0, #0
    mov x8, #93
    svc #0
""")
print(f"{len(rows)} probe words")
