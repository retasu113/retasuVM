"""Phase 4 step 7: dump the IOConfigThread name-record array (phase 3:
0x80-byte stride at dump_off ~0x8B68000, inline name + timestamp).
Look for a thread-pointer field per record.
"""
import re
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


# locate the array precisely: search for the pattern bytes of a known name
f = open(DUMP, 'rb')
data = f.read()
f.close()
i = data.find(b"IOConfigThread_'Container'")
print(f"first 'IOConfigThread_'Container'' at dump_off {i:#x}")
j = data.find(b"IOConfigThread_'", i + 1)
print(f"next IOConfigThread_ at {j:#x} (delta {j - i:#x})")

# dump 6 records of 0x80 starting a bit before the first name
base = (i - 0x40)
for r in range(6):
    off = base + r * 0x80
    raw = data[off:off + 0x80]
    txt = re.findall(rb'[\x20-\x7e]{4,}', raw)
    print(f'\n-- record {r} at dump_off {off:#x} strings: {txt}')
    for qo in range(0, 0x80, 8):
        v = struct.unpack_from('<Q', raw, qo)[0]
        if v:
            extra = ''
            if 0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF:
                pa = W(v)
                if pa is not None:
                    first = d.u64_pa(pa)
                    extra = f' -> PA {pa:#x} [target+0]={first:#x}' + \
                        (' == TASK_VA' if first == TASK_VA else '')
            print(f'   +{qo:#04x}: {v:#018x}{extra}')
