#!/usr/bin/env python3
"""Phase 26: read the launchd worker thread's user PCB from the p25 final
dump and verify the saved state the exception-return path restores.

The capture: faultPC 0xfffffe00200352fc (unslid 0xfffffe0007d812fc) is
`mov sp, x1` in XNU's exception_return (locore.s); x0 = PCB pointer
0xfffffe18502adee0 (= spEL0Prev: SP_EL0 holds the PCB pointer while the
kernel runs, per EL0_64_VECTOR); x1 = [PCB+0x100] = saved SP 0x16f1f3cf8.
Frame layout = arm_thread_state64 at PCB+0x08 (x0@+0x08 ... x29@+0xF0,
LR@+0xF8, SP@+0x100, PC@+0x108, CPSR@+0x110, q0-q31@+0x140..0x330).

Run on the PC (dump is 4 GiB). Usage: p26_pcb.py <dump>
Outputs: p26_pcb_out.txt
"""
import struct
import sys

sys.path.insert(0, ".")
from p5_common import Ctx  # noqa: E402

DUMP = sys.argv[1]
PCB_VA = 0xFFFFFE18502ADEE0
SPIN_TTBR0 = 0x85B70000
SPEL1 = 0xFFFFFECEFA5F8000
DRAM = 0x70000000

ctx = Ctx(DUMP)
out = open("p26_pcb_out.txt", "w")


def log(s=""):
    print(s)
    out.write(s + "\n")


log(f"--- PCB @ VA {PCB_VA:#x} via TTBR1 (kernel root 0x77b98000) ---")
pcb = ctx.read_va(PCB_VA, 0x340)
if pcb is None:
    log("FAIL: PCB VA not readable via TTBR1")
    sys.exit(1)
log(f"read {len(pcb)} B OK")

def q(off):
    return struct.unpack_from("<Q", pcb, off)[0]

def d(off):
    return struct.unpack_from("<I", pcb, off)[0]

log(f"  PCB+0x00 (pre-state field) = {q(0):#018x}")
names = ["x%d" % i for i in range(29)] + ["fp(x29)"]
for i in range(29):
    log(f"  x{i:<2d} @+{0x08 + i*8:#05x} = {q(0x08 + i*8):#018x}")
log(f"  fp  @+0xF0 = {q(0xF0):#018x}")
log(f"  lr  @+0xF8 = {q(0xF8):#018x}")
log(f"  SP  @+0x100 = {q(0x100):#018x}  (capture spEL0=0x16f1f3cf8; %%16={q(0x100) % 16})")
log(f"  PC  @+0x108 = {q(0x108):#018x}  (capture excElr=0x198eb5640)")
log(f"  CPSR@+0x110 = {d(0x110):#010x}")
log(f"  q0  @+0x140 = {q(0x140):#018x} {q(0x148):#018x}")
log(f"  q1  @+0x150 = {q(0x150):#018x} {q(0x158):#018x}")
nz_q = 0
for i in range(32):
    if q(0x140 + i * 16) or q(0x140 + i * 16 + 8):
        nz_q += 1
log(f"  nonzero q regs: {nz_q}/32")
nz_gpr = sum(1 for i in range(29) if q(0x08 + i * 8) != 0)
log(f"  nonzero GPRs (x0..x28): {nz_gpr}/29; fp!=0: {q(0xF0) != 0}; lr!=0: {q(0xF8) != 0}")

log("\n--- scan: PCB pointer qword 0xfffffe18502adee0 occurrences ---")
data = open(DUMP, "rb").read()
pat = struct.pack("<Q", PCB_VA)
occs = []
i = data.find(pat)
while i != -1:
    if i % 8 == 0:
        occs.append(i)
    i = data.find(pat, i + 1)
log(f"  {len(occs)} aligned occurrence(s)")
for off in occs[:10]:
    pa = DRAM + off
    log(f"  @PA {pa:#x} (file {off:#x})")
    for j in range(-0x20, 0x40, 8):
        v = struct.unpack_from("<Q", data, off + j)[0]
        if v:
            log(f"      {pa + j:#x} {v:#018x}")

log("\n--- scan: TTBR0 root qword 0x85b70000 occurrences (pmap struct) ---")
pat = struct.pack("<Q", SPIN_TTBR0)
occs = []
i = data.find(pat)
while i != -1:
    if i % 8 == 0:
        occs.append(i)
    i = data.find(pat, i + 1)
log(f"  {len(occs)} aligned occurrence(s)")
for off in occs[:10]:
    pa = DRAM + off
    log(f"  @PA {pa:#x} (file {off:#x})")
    for j in range(-0x20, 0x40, 8):
        v = struct.unpack_from("<Q", data, off + j)[0]
        if v:
            log(f"      {pa + j:#x} {v:#018x}")

log(f"\n--- kernel stack spEL1={SPEL1:#x}: base qword {SPEL1 - 0x4000:#x} ---")
pat = struct.pack("<Q", SPEL1 - 0x4000)
occs = []
i = data.find(pat)
while i != -1:
    if i % 8 == 0:
        occs.append(i)
    i = data.find(pat, i + 1)
log(f"  {len(occs)} aligned occurrence(s)")
for off in occs[:10]:
    pa = DRAM + off
    log(f"  @PA {pa:#x} (file {off:#x})")

log("\n--- read top of spEL1 kernel stack (16 qwords below spEL1) ---")
top = ctx.read_va(SPEL1 - 0x80, 0x80)
if top:
    for j in range(0, 0x80, 8):
        v = struct.unpack_from("<Q", top, j)[0]
        if v:
            log(f"  spEL1-0x80+{j:#04x} ({SPEL1 - 0x80 + j:#x}) = {v:#018x}")
else:
    log("  (not readable via TTBR1)")

out.close()
print("wrote p26_pcb_out.txt")
