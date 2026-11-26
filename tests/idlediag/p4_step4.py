"""Phase 4 step 4: cpu_data page diff + thread_ro target analysis."""
import struct
import sys

sys.path.insert(0, '.')
from p4_lib import Dump, walk, OFF

DUMP = '/home/retasu/retasuvm/inst/imagetest/home_idlediag/dram_idlediag1.bin'
d = Dump(DUMP)
ROOT = 0x77B98000
TASK_VA = 0xFFFFFE249E0FC0A8


def W(va):
    return walk(d, ROOT, va, 14, 1)


# 1. diff the two cpu_data candidate pages
a = d.read_pa(0x739C6000, 0x2000)   # via page tables (x20)
b = d.read_pa(0x73C66000, 0x2000)   # via physmap arithmetic
diff = sum(1 for i in range(0x2000) if a[i] != b[i])
print(f'cpu_data candidates: walk page vs physmap page differ in '
      f'{diff}/8192 bytes')

# 2. census of kernel_task value occurrences (tro records)
needle = struct.pack('<Q', TASK_VA)
hits = []
pos = 0
f = open(DUMP, 'rb')
data = f.read()
f.close()
start = 0
while True:
    i = data.find(needle, start)
    if i < 0:
        break
    hits.append(i)
    start = i + 1
print(f'\nkernel_task value occurrences in dump1: {len(hits)}')

# tro records: task ptr at +0x00, record size 0x120. Show fields of first 3
# records that sit in a dense run (offset delta 0x120 from a neighbour).
hitset = set(hits)
recs = [h for h in hits if (h - 0x120) in hitset or (h + 0x120) in hitset]
print(f'in 0x120-runs: {len(recs)}')
for h in recs[:3]:
    rec_pa = h + 0x70000000
    print(f'\n-- tro record at dump_off {h:#x} (PA {rec_pa:#x}) --')
    raw = d.read_pa(rec_pa, 0x120)
    for off in range(0, 0x120, 8):
        v = struct.unpack_from('<Q', raw, off)[0]
        if v:
            print(f'   +{off:#05x}: {v:#018x}')

# 3. for the first record, follow +0x110 (thread candidate) and +0x40 (stack)
if recs:
    h = recs[0]
    rec_pa = h + 0x70000000
    raw = d.read_pa(rec_pa, 0x120)
    stack_va = struct.unpack_from('<Q', raw, 0x40)[0]
    thr_va = struct.unpack_from('<Q', raw, 0x110)[0]
    print(f'\nrecord stack field +0x40 = {stack_va:#x} -> walk PA {W(stack_va)}')
    print(f'record thread field +0x110 = {thr_va:#x} -> walk PA '
          f'{W(thr_va) if W(thr_va) is None else hex(W(thr_va))}')
    tpa = W(thr_va)
    if tpa:
        print(f'\n== thread-candidate struct at {thr_va:#x} (PA {tpa:#x}) ==')
        raw = d.read_pa(tpa, 0x400)
        for off in range(0, 0x400, 8):
            v = struct.unpack_from('<Q', raw, off)[0]
            if v:
                tag = ''
                if v == TASK_VA:
                    tag = ' <== kernel_task VA'
                if v == stack_va:
                    tag = ' <== stack VA (== tro +0x40)'
                print(f'   +{off:#05x}: {v:#018x}{tag}')
