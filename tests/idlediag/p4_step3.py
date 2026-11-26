"""Phase 4 step 3: hex anchor results + first struct dumps via the walk."""
import struct
import sys

sys.path.insert(0, '.')
from p4_lib import Dump, walk

DUMP = '/home/retasu/retasuvm/inst/imagetest/home_idlediag/dram_idlediag1.bin'
d = Dump(DUMP)
ROOT = 0x77B98000


def W(va):
    return walk(d, ROOT, va, 14, 1)


def show(name, va):
    pa = W(va)
    print(f'{name}: VA {va:#018x} -> PA {pa if pa is None else hex(pa)}')
    return pa


print('== anchor walks (16K, L1 root, idx bits[46:36]) ==')
show('msgbuf (real VA)', 0xFFFFFE0022A22484)
show('cpu_data (x20)', 0xFFFFFE001F9C6000)
show('pmap struct', 0xFFFFFE0022A04060)
show('_kernel_pmap var', 0xFFFFFE001FA92C80)
show('kernel_task', 0xFFFFFE249E0FC0A8)
show('thread ptr tag23', 0xFFFFFE239BF5F920)
show('park PC', 0xFFFFFE00201D5E68)

# reverse: which VA maps the msgbuf PA? scan segments via walk of candidate:
# brute force is expensive; instead walk the tables for the L1/L2/L3 that
# contain PA 0x76A20000 page by re-enumerating only L1 slot of physmap area
OA = 0x0000FFFFFFFFC000
target_page = 0x76A20000
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
            if e3 and (e3 & OA) == target_page:
                va = (0xFFFF << 48) | (1 << 47) | (l1 << 36) | (l2 << 25) | (l3 << 14)
                print(f'\nmsgbuf page PA {target_page:#x} is mapped at VA {va:#018x} '
                      f'(l1={l1:#x} l2={l2:#x} l3={l3:#x})')

print('\n== kernel_task struct head (via walk) ==')
task_pa = W(0xFFFFFE249E0FC0A8)
raw = d.read_pa(task_pa, 0x200)
for off in range(0, 0x200, 8):
    v = struct.unpack_from('<Q', raw, off)[0]
    print(f'  +{off:#05x}: {v:#018x}')

print('\n== cpu_data REAL page head (x20 walk) ==')
cd_pa = W(0xFFFFFE001F9C6000)
raw = d.read_pa(cd_pa, 0x500)
for off in range(0, 0x500, 8):
    v = struct.unpack_from('<Q', raw, off)[0]
    if v:
        print(f'  +{off:#05x}: {v:#018x}')

print('\n== thread struct head (tag23 ptr from cpu_data/pmap) ==')
th_pa = W(0xFFFFFE239BF5F920)
raw = d.read_pa(th_pa, 0x300)
for off in range(0, 0x300, 8):
    v = struct.unpack_from('<Q', raw, off)[0]
    print(f'  +{off:#05x}: {v:#018x}')
