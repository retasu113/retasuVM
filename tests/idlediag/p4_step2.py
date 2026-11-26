"""Phase 4 step 2: enumerate the kernel pmap's mappings table-side.

Walks the descriptor tree rooted at TTBR 0x77B98000 and records every
block/page segment as (va_base, pa_base, size). Then answers anchor
questions by lookup -- no index arithmetic from the VA side.
"""
import sys

sys.path.insert(0, '.')
from p4_lib import Dump

DUMP = '/home/retasu/retasuvm/inst/imagetest/home_idlediag/dram_idlediag1.bin'
d = Dump(DUMP)
ROOT = 0x77B98000
OA = 0x0000FFFFFFFFC000

segments = []  # (va, pa, size, kind)


def va_base(l1, l2=0, l3=0):
    return (0xFFFF << 48) | (1 << 47) | (l1 << 36) | (l2 << 25) | (l3 << 14)


for l1 in range(2048):
    e1 = d.u64_pa(ROOT + l1 * 8)
    if not e1:
        continue
    if e1 & 0x3 == 0x1:  # L1 block, 2^36
        base = e1 & (~((1 << 36) - 1)) & 0x0000FFFFFFFFFFFF
        segments.append((va_base(l1), base, 1 << 36, 'L1blk'))
        continue
    if e1 & 0x3 != 0x3:
        print(f'L1[{l1:#x}] weird entry {e1:#x}')
        continue
    l2tab = e1 & OA
    for l2 in range(2048):
        e2 = d.u64_pa(l2tab + l2 * 8)
        if not e2:
            continue
        if e2 & 0x3 == 0x1:  # L2 block, 2^25
            base = e2 & (~((1 << 25) - 1)) & 0x0000FFFFFFFFFFFF
            segments.append((va_base(l1, l2), base, 1 << 25, 'L2blk'))
            continue
        if e2 & 0x3 != 0x3:
            print(f'L2[{l1:#x},{l2:#x}] weird entry {e2:#x}')
            continue
        l3tab = e2 & OA
        for l3 in range(2048):
            e3 = d.u64_pa(l3tab + l3 * 8)
            if not e3:
                continue
            if e3 & 0x3 != 0x3:
                print(f'L3[{l1:#x},{l2:#x},{l3:#x}] weird entry {e3:#x}')
                continue
            segments.append((va_base(l1, l2, l3), e3 & OA, 1 << 14, 'page'))

print(f'total segments: {len(segments)}')
kinds = {}
for _, _, _, k in segments:
    kinds[k] = kinds.get(k, 0) + 1
print('kinds:', kinds)


def by_pa(pa):
    for va, p, sz, k in segments:
        if p <= pa < p + sz:
            return (va + (pa - p), k)
    return None


def by_va(va):
    for v, p, sz, k in segments:
        if v <= va < v + sz:
            return (p + (va - v), k)
    return None


print('\n-- anchor lookups --')
for name, pa in [('msgbuf PA', 0x76A22484), ('cpu_data physmap PA', 0x73C66000),
                 ('walk-claimed cpu_data PA', 0x739C6000),
                 ('pmap struct physmap PA', 0x76A04060)]:
    print(f'{name} {pa:#x} -> VA {by_pa(pa)}')
for name, va in [('msgbuf VA (sym)', 0xFFFFFE0026A22484),
                 ('cpu_data VA (x20)', 0xFFFFFE001F9C6000),
                 ('pmap struct VA', 0xFFFFFE0022A04060),
                 ('kernel_task VA', 0xFFFFFE249E0FC0A8),
                 ('thread ptr VA (tag23)', 0xFFFFFE239BF5F920),
                 ('stack VA sample (tag 8F space?)', 0xFFFFFE8F414E0000)]:
    print(f'{name} {va:#x} -> PA {by_va(va)}')

# VA-space summary: which L1 slots have what
print('\n-- segments per L1 slot (first 40 segments) --')
for va, p, sz, k in segments[:40]:
    print(f'  VA {va:#018x} -> PA {p:#x} size {sz:#x} {k}')
