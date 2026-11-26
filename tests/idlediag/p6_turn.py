"""Phase 6: walk the turnstile inheritor chain from the shared waitq W;
identify the lock owner thread and the proprietor (lock) consistency.
Also classify [fa]'s waitq and [fa]'s own turnstile.

Usage: python3 p6_turn.py <dump>
"""
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, thread_info  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva

W = 0xFFFFFE1DF00CD2A0


def dump_ts(ts, label):
    print(f'--- turnstile {label} {ts:#x} ---')
    for off in range(0, 0x70, 8):
        v = Q(ts + off)
        note = ''
        if off == 0x00 and v is not None:
            note = f' (wq flags/type: low32={v & 0xFFFFFFFF:#x})'
        if off == 0x18:
            note = ' (ts_inheritor)'
        if off == 0x48:
            note = ' (ts_proprietor?)'
        print(f'  +{off:#04x}: {v if v is None else hex(v)}{note}')


print('===== inheritor chain from shared waitq W =====')
cur = W
for hop in range(8):
    inh = Q(cur + 0x18)
    prop = Q(cur + 0x48)
    print(f'hop {hop}: ts={cur:#x} inheritor={inh if inh is None else hex(inh)} '
          f'proprietor={prop if prop is None else hex(prop)} '
          f'queue_first={Q(cur + 8) if Q(cur + 8) is None else hex(Q(cur + 8))}')
    if inh is None or inh == 0:
        print('  chain ends (null inheritor)')
        break
    # is the inheritor a thread? thread structs have a name ptr at
    # +0x7D8 and id at +0x498; turnstiles have wq flags at +0.
    ti = thread_info(ctx, inh)
    if ti and ti['name']:
        print(f'  INHERITOR IS THREAD: id={ti["id"]:#x} '
              f'name={ti["name"]!r} wait={ti["wait_event"]:#x} '
              f'waitq={Q(inh + 0x28):#x} state=0x{ti["state_byte"]:02x}')
        break
    cur = inh
else:
    print('  chain too long')

dump_ts(W, 'W (shared)')
for sib in (0xFFFFFE1DF00CD840, 0xFFFFFE1DF00CFF40):
    dump_ts(sib, 'chain')

print()
FA = 0xFFFFFE184A48F010
fa_wq = Q(FA + 0x28)
fa_ts = Q(FA + 0x30)
print(f'[fa] waitq={fa_wq:#x} flags64={Q(fa_wq) if Q(fa_wq) is None else hex(Q(fa_wq))}')
print(f'[fa] own turnstile (+0x30) = {fa_ts:#x}')
if fa_ts:
    dump_ts(fa_ts, '[fa] turnstile')
if fa_wq:
    print(f'--- [fa] waitq {fa_wq:#x} raw ---')
    for off in range(0, 0x60, 8):
        v = Q(fa_wq + off)
        print(f'  +{off:#04x}: {v if v is None else hex(v)}')
