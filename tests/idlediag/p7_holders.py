"""Phase 7: whole-dump holder scan for given qword values (the shared
event E, its object base E-8, the waitq W): classify each hit as
inside a known thread's kernel stack / thread struct / elsewhere
(with surrounding qwords for context). Finds the lock owner, whose
stack or struct references the object it holds.
Usage: python3 p7_holders.py <dump> <val> [val...]
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, census_threads, thread_info  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva

threads = census_threads(ctx)
stacks = {}
structs = {}
for tva in threads:
    ti = thread_info(ctx, tva)
    if ti and ti['stack_va']:
        stacks[ti['stack_va']] = (tva, ti)
        structs[tva] = ti


def classify(va):
    for base, (tva, ti) in stacks.items():
        if base <= va < base + 0x4000:
            return (f'STACK of thread {tva:#x} id={ti["id"]:#x} '
                    f'name={ti["name"]!r} at +{va - base:#x}')
    for tva, ti in structs.items():
        if tva <= va < tva + 0x900:
            return (f'THREAD STRUCT {tva:#x} id={ti["id"]:#x} '
                    f'name={ti["name"]!r} at +{va - tva:#x}')
    return None


for arg in sys.argv[2:]:
    target = int(arg, 0)
    pat = struct.pack('<Q', target)
    print(f'===== holders of {target:#x} =====')
    hits = 0
    for sva, spa, ln in ctx.segs:
        if not (0x70000000 <= spa and spa + ln <= 0xB0000000):
            continue
        raw = ctx.d.read_pa(spa, ln)
        idx = 0
        while True:
            j = raw.find(pat, idx)
            if j < 0:
                break
            idx = j + 8
            va = sva + j
            hits += 1
            c = classify(va)
            print(f'  {va:#x}: {c if c else "elsewhere"}')
    print(f'  ({hits} hits)')
