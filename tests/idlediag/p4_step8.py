"""Phase 4 step 8: identify the A/B records' Y pointers (thread candidates).

Builds the PA->VA reverse map from the pmap enumeration, gets the VAs of
the A record (PA 0x78DE81E8) and a B record (PA 0x78DE8428), then dumps
their Y-field targets looking for back-pointers / TASK_VA / thread ids.
"""
import struct
import sys

sys.path.insert(0, '.')
from p4_lib import Dump, walk

DUMP = '/home/retasu/retasuvm/inst/imagetest/home_idlediag/dram_idlediag1.bin'
d = Dump(DUMP)
ROOT = 0x77B98000
TASK_VA = 0xFFFFFE249E0FC0A8
OA = 0x0000FFFFFFFFC000


def W(va):
    return walk(d, ROOT, va, 14, 1)


# reverse map for the two record pages (targeted enumeration)
def va_of_pa(target):
    for l1 in range(2048):
        e1 = d.u64_pa(ROOT + l1 * 8)
        if not e1 or e1 & 3 != 3:
            continue
        l2tab = e1 & OA
        for l2 in range(2048):
            e2 = d.u64_pa(l2tab + l2 * 8)
            if not e2 or e2 & 3 != 3:
                continue
            l3tab = e2 & OA
            for l3 in range(2048):
                e3 = d.u64_pa(l3tab + l3 * 8)
                if e3 and (e3 & OA) == (target & ~0x3FFF):
                    va = (0xFFFF << 48) | (1 << 47) | (l1 << 36) | \
                        (l2 << 25) | (l3 << 14)
                    return va + (target & 0x3FFF)
    return None


A_PA = 0x78DE81E8
B_PA = 0x78DE8428
A_VA = va_of_pa(A_PA)
B_VA = va_of_pa(B_PA)
print(f'A record PA {A_PA:#x} -> VA {A_VA if A_VA is None else hex(A_VA)}')
print(f'B record PA {B_PA:#x} -> VA {B_VA if B_VA is None else hex(B_VA)}')

# Y fields: A1 +0xF8, B1 +0x38 (B at region+0x240 => PA A_PA+0x240, Y at +0x38)
a_raw = d.read_pa(A_PA, 0x120)
A_Y = struct.unpack_from('<Q', a_raw, 0xF8)[0]
b_raw = d.read_pa(A_PA + 0x240, 0x60)
B_Y = struct.unpack_from('<Q', b_raw, 0x38)[0]
print(f'A1 Y (+0xF8) = {A_Y:#x}')
print(f'B1 Y (+0x38) = {B_Y:#x}')

for name, yva, owner_va in [('A1.Y', A_Y, A_VA), ('B1.Y', B_Y,
                                                 B_VA + 0x240 if B_VA else None)]:
    pa = W(yva)
    print(f'\n== {name} target {yva:#x} -> PA {pa if pa is None else hex(pa)} ==')
    if pa is None:
        continue
    raw = d.read_pa(pa, 0x400)
    for off in range(0, 0x400, 8):
        v = struct.unpack_from('<Q', raw, off)[0]
        if v:
            note = ''
            if v == TASK_VA:
                note = ' <== TASK_VA'
            if owner_va and v == owner_va:
                note = ' <== OWNER RECORD VA (back-pointer!)'
            print(f'   +{off:#05x}: {v:#018x}{note}')
