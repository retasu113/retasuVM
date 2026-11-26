"""Phase 4 step 6: verify the task->threads chain and deep-dive one thread.

Chain hypothesis: kernel_task+0xD8 = queue head {next, prev} of the
task_threads list; entries are &thread->task_threads linkage; a thread's
t_task sits at linkage+0x48 (from the step-5 window scan).
"""
import struct
import sys

sys.path.insert(0, '.')
from p4_lib import Dump, walk

DUMP = '/home/retasu/retasuvm/inst/imagetest/home_idlediag/dram_idlediag1.bin'
d = Dump(DUMP)
ROOT = 0x77B98000
TASK_VA = 0xFFFFFE249E0FC0A8
HEAD_VA = TASK_VA + 0xD8


def W(va):
    return walk(d, ROOT, va, 14, 1)


def Q(va):
    pa = W(va)
    return None if pa is None else d.u64_pa(pa)


head_next = Q(HEAD_VA)
head_prev = Q(HEAD_VA + 8)
print(f'task threads head @{HEAD_VA:#x}: next={head_next:#x} prev={head_prev:#x}')

for name, link in [('first', head_next), ('last', head_prev)]:
    n = Q(link)
    p = Q(link + 8)
    t = Q(link + 0x48)
    print(f'{name} linkage {link:#x}: next={n:#x} prev={p:#x} '
          f'linkage+0x48={t if t is None else hex(t)} '
          f'(== TASK_VA: {t == TASK_VA})')

# walk the chain
links = []
cur = head_next
guard = 0
while cur != HEAD_VA and cur and guard < 5000:
    links.append(cur)
    cur = Q(cur)
    guard += 1
print(f'\nchain length: {len(links)} (closed: {cur == HEAD_VA})')

# deep-dive: window around the first linkage
if links:
    link = links[0]
    base_va = link - 0x300
    pa = W(base_va)
    raw = d.read_pa(pa, 0x300 + 0x300)
    print(f'\nwindow around first linkage {link:#x} '
          f'(offsets relative to linkage):')
    for off in range(0, len(raw), 8):
        v = struct.unpack_from('<Q', raw, off)[0]
        if v:
            rel = off - 0x300
            note = ''
            if v == TASK_VA:
                note = ' <== TASK_VA'
            if rel == 0:
                note += ' <== linkage.next'
            if rel == 8:
                note += ' <== linkage.prev'
            print(f'  {rel:+#06x}: {v:#018x}{note}')
