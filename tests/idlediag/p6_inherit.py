"""Phase 6: whose thread turnstiles are CD840 / CFF40 (the inheritor
chain of the shared wait W)? Scan every census thread's +0x30
(turnstile pointer). Also dump [cd] VirtIO thread's wait target object.
Usage: python3 p6_inherit.py <dump>
"""
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, census_threads, thread_info, load_syms, SLIDE  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva
syms = {a: n for a, n in load_syms()['syms']}

TARGETS = {0xFFFFFE1DF00CD2A0: 'W (shared wait turnstile)',
           0xFFFFFE1DF00CD840: 'chain ts #2',
           0xFFFFFE1DF00CFF40: 'chain ts #3'}
threads = census_threads(ctx)
for tva in threads:
    ts = Q(tva + 0x30)
    if ts in TARGETS:
        ti = thread_info(ctx, tva)
        print(f'{TARGETS[ts]} {ts:#x} is the turnstile of thread '
              f'{tva:#x} id={ti["id"]:#x} name={ti["name"]!r} '
              f'wait={ti["wait_event"]:#x} waitq={Q(tva + 0x28):#x} '
              f'state=0x{ti["state_byte"]:02x}')

# [cd] AppleVirtIOPCITransport config thread: wait on heap event
CD = 0xFFFFFE184A482020
ti = thread_info(ctx, CD)
print(f'\n[cd] wait_event={ti["wait_event"]:#x}')
ev = ti['wait_event']
for off in range(-0x20, 0x40, 8):
    v = Q(ev + off)
    c = syms.get(v - 0x10 - SLIDE) if v else None
    print(f'  ev{off:+#x}: {v:#x}{" class=" + c if c else ""}')
