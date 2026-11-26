"""Phase 6: IOService arbitration-lock queues from the dump.

Decode ADRP refs in IOService::lockForArbitration/unlockForArbitration
(kernelcache.macho) to locate gArbitrationLockQueue{Active,Waiting,
Free} + gArbitrationLockQueueLock, read the queue heads from the dump,
walk the element queues (ArbitrationLockQueueElement: link +0x00,
thread +0x10, service +0x18, count +0x20, required +0x24, aborted
+0x25), identify each service by its vtable's ZTV symbol, and each
thread by the phase-4 field map.

Usage: python3 p6_arb.py <kernelcache.macho> <dump> [shared_event_va]
"""
import bisect
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, thread_info, link_of, load_syms, SLIDE  # noqa: E402

KC = sys.argv[1]
DUMP = sys.argv[2]
SHARED_EVENT = int(sys.argv[3], 16) if len(sys.argv) > 3 else None

kc = open(KC, 'rb').read()
segs = load_syms()['segs']
syms = sorted(load_syms()['syms'])
saddrs = [s[0] for s in syms]
names = {a: n for a, n in syms}


def file_off(va):
    for s in segs:
        if s['vmaddr'] <= va < s['vmaddr'] + s['filesize']:
            return s['fileoff'] + (va - s['vmaddr'])
    return None


def func_range(name):
    a = link_of(name)
    i = saddrs.index(a)
    end = syms[i + 1][0] if i + 1 < len(syms) else a + 0x2000
    return a, end


def decode_refs(name):
    start, end = func_range(name)
    off = file_off(start)
    words = struct.unpack_from(f'<{(end - start) // 4}I', kc, off)
    refs = {}
    adrp = {}
    for i, w in enumerate(words):
        pc = start + i * 4
        if w & 0x9F000000 == 0x90000000:
            rd = w & 0x1F
            immlo = (w >> 29) & 0x3
            immhi = (w >> 5) & 0x7FFFF
            imm = (immhi << 2) | immlo
            if imm & (1 << 20):
                imm -= (1 << 21)
            adrp[rd] = (pc & ~0xFFF) + (imm << 12)
            continue
        if w & 0xFF800000 == 0x91000000:
            rn = (w >> 5) & 0x1F
            rd = w & 0x1F
            if rn in adrp:
                imm = (w >> 10) & 0xFFF
                if (w >> 22) & 0x1:
                    imm <<= 12
                refs.setdefault(adrp[rn] + imm, []).append(('add', pc))
                adrp[rd] = adrp[rn] + imm
            continue
        for mask, op, sh in ((0xF9400000, 'ldr', 3), (0xF9000000, 'str', 3),
                             (0xB9400000, 'ldr32', 2), (0xB9000000, 'str32', 2)):
            if w & 0xFFC00000 == mask:
                rn = (w >> 5) & 0x1F
                if rn in adrp:
                    imm = ((w >> 10) & 0xFFF) << sh
                    refs.setdefault(adrp[rn] + imm, []).append((op, pc))
                break
    return refs


refs = {}
for fn in ('__ZN9IOService18lockForArbitrationEb',
           '__ZN9IOService20unlockForArbitrationEv'):
    for a, uses in decode_refs(fn).items():
        refs.setdefault(a, []).extend((fn, k) for k, _ in uses)
print('--- statics referenced by lock/unlockForArbitration ---')
for a in sorted(refs):
    kinds = ','.join(sorted({k for _, k in refs[a]}))
    print(f'  link {a:#x} rt {a + SLIDE:#x} [{kinds}]')

ctx = Ctx(DUMP)


def class_of(obj):
    vt = ctx.Qva(obj)
    if vt is None:
        return '?'
    link = vt - 0x10 - SLIDE
    return names.get(link, f'vt@{link:#x}')


def describe_thread(tva):
    ti = thread_info(ctx, tva)
    if ti is None:
        return f'thread {tva:#x} <unreadable>'
    return (f"thread {tva:#x} id={ti['id']:#x} name={ti['name']!r} "
            f"wait={ti['wait_event']:#x} waitq={ctx.Qva(tva + 0x28):#x}")


def walk_queue(head_rt, label):
    print(f'\n--- {label} (head rt {head_rt:#x}) ---')
    first = ctx.d.u64_phys(head_rt)
    last = ctx.d.u64_phys(head_rt + 8)
    print(f'  head: first={first:#x} last={last:#x}')
    cur = first
    seen = set()
    n = 0
    while cur and cur != head_rt and cur not in seen and n < 64:
        seen.add(cur)
        n += 1
        raw = ctx.read_va(cur, 0x28)
        if raw is None:
            print(f'  elem {cur:#x}: unreadable')
            break
        nxt, thread, service = struct.unpack_from('<QQQ', raw, 0)
        # NOTE: +0x10 thread, +0x18 service per struct def (link is 16B)
        thread = struct.unpack_from('<Q', raw, 0x10)[0]
        service = struct.unpack_from('<Q', raw, 0x18)[0]
        count = struct.unpack_from('<I', raw, 0x20)[0]
        req = raw[0x24]
        ab = raw[0x25]
        ev_note = ''
        if SHARED_EVENT and service:
            ev_note = (f'  shared_event - service = '
                       f'{SHARED_EVENT - service:#x}')
        print(f'  elem {cur:#x}: count={count} required={req} '
              f'aborted={ab}')
        print(f'    {describe_thread(thread)}')
        print(f'    service {service:#x} class={class_of(service)}'
              f'{ev_note}')
        cur = nxt
    print(f'  ({n} elements)')


# The three queue heads are consecutive statics (Active, Waiting, Free
# in declaration order). Find a run of 3 'add'-referenced statics spaced
# 16 bytes apart whose dump values look like queue heads.
adds = sorted(a for a, u in refs.items()
              if any(k == 'add' for _, k in u))
print(f'\naddress-of statics: {[hex(a) for a in adds]}')
done = False
for a in adds:
    if a + 0x10 in adds and a + 0x20 in adds:
        for i, label in enumerate(('ACTIVE', 'WAITING', 'FREE')):
            walk_queue(a + SLIDE + i * 0x10, f'gArbitrationLockQueue{label}'
                         f' (link {a + i * 0x10:#x})')
        done = True
        break
if not done:
    print('no consecutive triple of queue-head statics found; '
          'dump all add-refs values:')
    for a in adds:
        rt = a + SLIDE
        print(f'  link {a:#x}: [{ctx.d.u64_phys(rt):#x}, '
              f'{ctx.d.u64_phys(rt + 8):#x}]')
