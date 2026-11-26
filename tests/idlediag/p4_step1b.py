"""Phase 4 step 1b: debug the root-table geometry directly."""
import struct
import sys

sys.path.insert(0, '.')
from p4_lib import Dump, SLIDE, OFF

DUMP = '/home/retasu/retasuvm/inst/imagetest/home_idlediag/dram_idlediag1.bin'
d = Dump(DUMP)
ROOT = 0x77B98000

vas = {
    'msgbuf': 0xFFFFFE0026A22484,
    'cpu_data': 0xFFFFFE001F9C6000,
    'kpmap_var': 0xFFFFFE001FA92C80,
    'park_pc': 0xFFFFFE00201D5E68,
    'kernel_task': 0xFFFFFE249E0FC0A8,
}
for name, va in vas.items():
    print(f'{name}: VA {va:#x} L1idx12={(va >> 36) & 0xFFF:#x} '
          f'L1idx11={(va >> 36) & 0x7FF:#x} L2idx={(va >> 25) & 0x7FF:#x} '
          f'L3idx={(va >> 14) & 0x7FF:#x}')

print('\nroot page entries at idx 0x7E0 and 0xFE0 (and neighbours):')
for idx in (0x7DE, 0x7DF, 0x7E0, 0x7E1, 0x7E2, 0xFDE, 0xFDF, 0xFE0, 0xFE1, 0xFE2):
    e = d.u64_pa(ROOT + idx * 8)
    print(f'  [{idx:#05x}] {e:#018x}')

# count nonzero entries in first page vs second page of root
nz1 = nz2 = 0
for i in range(2048):
    if d.u64_pa(ROOT + i * 8):
        nz1 += 1
    if d.u64_pa(ROOT + 0x4000 + i * 8):
        nz2 += 1
print(f'\nnonzero entries: page0 (idx 0..2047 as 8B slots in 16K) = {nz1}, '
      f'page1 = {nz2}')
# nonzero index ranges in the 32K span (4096 slots)
nz_idx = [i for i in range(4096) if d.u64_pa(ROOT + i * 8)]
if nz_idx:
    print(f'nonzero slot range over 4096 slots: {nz_idx[0]:#x} .. {nz_idx[-1]:#x} '
          f'count={len(nz_idx)}')

# trace: follow idx 0xFE0 chain manually for msgbuf
print('\nmanual chain for msgbuf via L1 idx 0xFE0:')
e = d.u64_pa(ROOT + 0xFE0 * 8)
print(f'  L1 entry = {e:#018x}')
if e & 3 == 3:
    l2 = e & 0x0000FFFFFFFFC000
    va = vas['msgbuf']
    e2 = d.u64_pa(l2 + ((va >> 25) & 0x7FF) * 8)
    print(f'  L2 table {l2:#x} entry idx {(va >> 25) & 0x7FF:#x} = {e2:#018x}')
    if e2 & 3 == 3:
        l3 = e2 & 0x0000FFFFFFFFC000
        e3 = d.u64_pa(l3 + ((va >> 14) & 0x7FF) * 8)
        print(f'  L3 table {l3:#x} entry idx {(va >> 14) & 0x7FF:#x} = {e3:#018x}')
        print(f'  => PA = {(e3 & 0x0000FFFFFFFFC000) + (va & 0x3FFF):#x} (expect 0x76a22484)')
    elif e2 & 3 == 1:
        base = e2 & 0x0000FFFFFFFE00000 if False else e2 & (~0 & ~((1 << 25) - 1)) & 0x0000FFFFFFFFFFFF
        print(f'  L2 BLOCK => PA = {base + (va & ((1 << 25) - 1)):#x} (expect 0x76a22484)')

print('\nmanual chain for msgbuf via L1 idx 0x7E0:')
e = d.u64_pa(ROOT + 0x7E0 * 8)
print(f'  L1 entry = {e:#018x}')
if e & 3 == 3:
    l2 = e & 0x0000FFFFFFFFC000
    va = vas['msgbuf']
    e2 = d.u64_pa(l2 + ((va >> 25) & 0x7FF) * 8)
    print(f'  L2 table {l2:#x} entry idx {(va >> 25) & 0x7FF:#x} = {e2:#018x}')
    if e2 & 3 == 3:
        l3 = e2 & 0x0000FFFFFFFFC000
        e3 = d.u64_pa(l3 + ((va >> 14) & 0x7FF) * 8)
        print(f'  L3 table {l3:#x} entry idx {(va >> 14) & 0x7FF:#x} = {e3:#018x}')
        print(f'  => PA = {(e3 & 0x0000FFFFFFFFC000) + (va & 0x3FFF):#x} (expect 0x76a22484)')
    elif e2 & 3 == 1:
        base = e2 & (~0 & ~((1 << 25) - 1)) & 0x0000FFFFFFFFFFFF
        print(f'  L2 BLOCK => PA = {base + (va & ((1 << 25) - 1)):#x} (expect 0x76a22484)')
