"""Phase 7: shared-wait forensics on an EARLY dump, fully generalized
(no per-boot hardcoded addresses):
- find the config threads' most-shared wait_event E and its waitq W;
- dump W and follow the turnstile inheritor chain (+0x18) hop by hop,
  testing each inheritor as a thread (the LIVE owner);
- scan every census thread's +0x30 for any chain turnstile;
- raw thread-zone holder scan for the chain turnstiles (owner may be
  missed by the record census);
- dump the event object E-8..E+0x10.
Usage: python3 p7_chain.py <dump>
"""
import struct
import sys
from collections import Counter

sys.path.insert(0, '.')
from p5_common import Ctx, census_threads, thread_info  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva
d = ctx.d

threads = census_threads(ctx)
infos = {}
for tva in threads:
    ti = thread_info(ctx, tva)
    if ti:
        infos[tva] = ti

cfgs = {t: i for t, i in infos.items()
        if i['name'] and 'IOConfigThread' in i['name']}
print(f'config threads in census: {len(cfgs)}')
cnt = Counter(i['wait_event'] for i in cfgs.values() if i['wait_event'])
E, n = cnt.most_common(1)[0]
print(f'shared wait_event E={E:#x} shared by {n} config threads:')
W = None
for t, i in cfgs.items():
    if i['wait_event'] == E:
        W = Q(t + 0x28)
        print(f'  waiter {t:#x} id={i["id"]:#x} name={i["name"]!r} '
              f'waitq={W:#x} ts={Q(t + 0x30):#x}')
print(f'\nevent object around E-8:')
for off in range(-0x10, 0x18, 8):
    print(f'  E{off:+#x}: {Q(E + off):#x}')


def dump_ts(ts, label):
    print(f'--- turnstile {label} {ts:#x} ---')
    for off in range(0, 0x70, 8):
        v = Q(ts + off)
        note = ''
        if off == 0x18:
            note = ' (ts_inheritor)'
        if off == 0x48:
            note = ' (ts_proprietor?)'
        print(f'  +{off:#04x}: {v if v is None else hex(v)}{note}')


def as_thread(va):
    ti = thread_info(ctx, va)
    if ti and ti['stack_va'] and ti['name']:
        return ti
    return None


print(f'\n===== inheritor chain from W={W:#x} =====')
chain = [W]
cur = W
owner = None
for hop in range(8):
    inh = Q(cur + 0x18)
    prop = Q(cur + 0x48)
    print(f'hop {hop}: ts={cur:#x} inheritor={inh if inh is None else hex(inh)} '
          f'proprietor={prop if prop is None else hex(prop)}')
    if not inh:
        print('  chain ends (null inheritor)')
        break
    ti = as_thread(inh)
    if ti:
        print(f'  *** INHERITOR IS LIVE THREAD {inh:#x} id={ti["id"]:#x} '
              f'name={ti["name"]!r} wait={ti["wait_event"]:#x} '
              f'waitq={Q(inh + 0x28):#x} state=0x{ti["state_byte"]:02x}')
        owner = inh
        break
    chain.append(inh)
    cur = inh

for ts in chain:
    dump_ts(ts, 'chain')

print('\n--- census threads whose +0x30 is a chain turnstile ---')
for tva, ti in infos.items():
    ts = Q(tva + 0x30)
    if ts in chain:
        print(f'  thread {tva:#x} id={ti["id"]:#x} name={ti["name"]!r} '
              f'owns {ts:#x} wait={ti["wait_event"]:#x} '
              f'waitq={Q(tva + 0x28):#x} state=0x{ti["state_byte"]:02x}')
        owner = owner or tva

print('\n--- raw thread-zone holder scan (+0x30) for chain turnstiles ---')
tvas = sorted(infos)
zone_lo = tvas[0] & ~0xFFFFFFF
zone_hi = (tvas[-1] | 0xFFFFFFF) + 1
for target in chain:
    pat = struct.pack('<Q', target)
    for sva, spa, ln in ctx.segs:
        if not (zone_lo <= sva < zone_hi):
            continue
        if not (0x70000000 <= spa and spa + ln <= 0xB0000000):
            continue
        raw = d.read_pa(spa, ln)
        idx = 0
        while True:
            j = raw.find(pat, idx)
            if j < 0:
                break
            idx = j + 8
            tva = sva + j - 0x30
            ti = thread_info(ctx, tva)
            ok = ti and ti['stack_va']
            print(f'  holder of {target:#x} at {sva + j:#x}: thread? {tva:#x} '
                  f'valid={bool(ok)}'
                  + (f' id={ti["id"]:#x} name={ti["name"]!r} '
                     f'wait={ti["wait_event"]:#x}' if ok else ''))

if owner:
    print(f'\nOWNER thread VA: {owner:#x} (feed to p7_stack.py)')
else:
    print('\nNo live owner found in this dump.')
