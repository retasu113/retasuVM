"""Phase 4 step 1: locate kernel_pmap -> ttbr, validate page-table walk.

Run on the PC: python3 p4_step1.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p4_lib import Dump, SLIDE, OFF, walk, try_configs

DUMP = sys.argv[1] if len(sys.argv) > 1 else \
    '/home/retasu/retasuvm/inst/imagetest/home_idlediag/dram_idlediag1.bin'

KERNEL_PMAP_LINK = 0xFFFFFE00077DEC80
KERNEL_TASK_LINK = 0xFFFFFE0007821438

d = Dump(DUMP)

kpmap_va = KERNEL_PMAP_LINK + SLIDE
pmap_va = d.u64_phys(kpmap_va)
print(f'_kernel_pmap var VA {kpmap_va:#x} -> pmap struct VA {pmap_va:#x}')

ktask_va = KERNEL_TASK_LINK + SLIDE
task_va = d.u64_phys(ktask_va)
print(f'_kernel_task var VA {ktask_va:#x} -> task VA {task_va:#x}')
print(f'  (phase 3 recorded task VA 0xFFFFFE249E0FC0A8)')

# pmap struct lives in static space? try physmap read of first 0x120 bytes
try:
    raw = d.read_phys(pmap_va, 0x120)
    src = 'physmap'
except Exception:
    raw = None
    src = None
if raw is None:
    print('pmap struct NOT in physmap range; will need walk first (chicken/egg)')
    sys.exit(0)

print(f'pmap struct head (via {src}):')
cands = []
for off in range(0, 0x120, 8):
    v = struct.unpack_from('<Q', raw, off)[0]
    pa_part = v & 0x0000FFFFFFFFFFFF
    note = ''
    if pa_part % 0x4000 == 0 and 0x70000000 <= pa_part < 0x170000000:
        note = ' <-- TTBR candidate (16K-aligned PA in DRAM)'
        cands.append((off, pa_part))
    elif pa_part % 0x1000 == 0 and 0x70000000 <= pa_part < 0x170000000:
        note = ' <-- pa-like (4K-aligned)'
    print(f'  +{off:#05x}: {v:#018x}{note}')

# anchors: (va, expected_pa, name)
anchors = [
    (0xFFFFFE0026A22484, 0x76A22484, 'msgbuf'),
    (0xFFFFFE001F9C6000, 0x73C66000, 'cpu_data park x20'),
    (KERNEL_PMAP_LINK + SLIDE, 0x73A92C80, '_kernel_pmap var'),
    (task_va, None, 'kernel_task (zone-tagged)'),
    (0xFFFFFE00201D5E68, 0x741D5E68, 'park PC (kernel text)'),
    (0xFFFFFE239BF5F920, None, 'cpu_data thread ptr (tag 0x23)'),
]

for off, root in cands:
    print(f'\n== ttbr candidate pmap+{off:#x} root_pa={root:#x} ==')
    # sanity: show first entries of root page
    ents = [d.u64_pa(root + i * 8) for i in range(4)]
    print('  root[0..3]:', [f'{e:#x}' for e in ents])
    res = try_configs(d, root, anchors)
    for cfg, (ok, detail) in res.items():
        line = ', '.join(
            f'{n}={"OK" if g else "got " + (hex(gt) if gt is not None else "None")}'
            for n, gt, exp, g in detail)
        print(f'  cfg granule=2^{cfg[0]} root_level={cfg[1]} all_anchor_match={ok}: {line}')
