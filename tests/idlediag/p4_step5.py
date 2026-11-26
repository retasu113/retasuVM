"""Phase 4 step 5: find task->threads linkage empirically.

For every pointer-valued field in kernel_task, translate it, then scan a
window around the target for the kernel_task VA (thread->task back-pointer
test). A hit identifies: the list offset in task, the thread base VA, the
linkage offset inside struct thread, and the task-field offset in thread.
"""
import struct
import sys

sys.path.insert(0, '.')
from p4_lib import Dump, walk

DUMP = '/home/retasu/retasuvm/inst/imagetest/home_idlediag/dram_idlediag1.bin'
d = Dump(DUMP)
ROOT = 0x77B98000
TASK_VA = 0xFFFFFE249E0FC0A8


def W(va):
    return walk(d, ROOT, va, 14, 1)


task_pa = W(TASK_VA)
raw = d.read_pa(task_pa, 0x800)
needle = struct.pack('<Q', TASK_VA)

print('candidate list/linkage fields in kernel_task:')
for off in range(0, 0x800, 8):
    v = struct.unpack_from('<Q', raw, off)[0]
    if v >> 40 != 0xFFFFFE and not (0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF):
        continue
    if v == TASK_VA:
        continue
    pa = W(v)
    if pa is None:
        continue
    # scan window around target for TASK_VA
    lo = pa - 0x300
    if lo < 0x70000000:
        continue
    win = d.read_pa(lo, 0x600)
    idx = win.find(needle)
    while idx != -1:
        thread_base = v - (idx - 0x300)
        print(f'  task+{off:#x} -> {v:#x}: TASK_VA found at target{idx - 0x300:+#x} '
              f'=> thread base {thread_base:#x}, task field at thread+{idx:#x} '
              f'(if target is the linkage)')
        idx = win.find(needle, idx + 1)
