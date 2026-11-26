"""Phase 6: (a) heap IOConfigThread_ name roster -> threads (fixed
segment handling); (b) vtable scan for the display/gfx subtree
instances; dump the first 0xC0 bytes of each with field annotations.
Usage: python3 p6_gfx2.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import (Ctx, census_threads, thread_info, load_syms,  # noqa: E402
                       link_of, SLIDE)

ctx = Ctx(sys.argv[1])
Q = ctx.Qva
syms = {a: n for a, n in load_syms()['syms']}


def class_of(obj):
    vt = Q(obj)
    if vt is None:
        return '?'
    return syms.get(vt - 0x10 - SLIDE, '?')


print('===== IOConfigThread_ heap name roster =====')
pat = b"IOConfigThread_'"
names = {}
for sva, spa, ln in ctx.segs:
    if ln > (1 << 28) or sva < 0xFFFFFE2000000000:
        continue
    try:
        raw = ctx.d.read_pa(spa, ln)
    except ValueError:
        continue
    idx = 0
    while True:
        j = raw.find(pat, idx)
        if j < 0:
            break
        idx = j + 1
        s = ctx.read_cstr(sva + j, 64)
        if s:
            names[sva + j] = s
threads = census_threads(ctx)
by_name_ptr = {}
for tva in threads:
    np = Q(tva + 0x7D8)
    if np:
        by_name_ptr[np] = tva
for nva, s in sorted(names.items(), key=lambda kv: kv[1]):
    tva = by_name_ptr.get(nva)
    extra = '  (no live thread)'
    if tva:
        ti = thread_info(ctx, tva)
        extra = (f'  -> thread {tva:#x} id={ti["id"]:#x} '
                 f'wait={ti["wait_event"]:#x}')
    print(f'  {s!r}{extra}')

print('\n===== display/gfx subtree instances =====')
CLASSES = ('__ZTV17AppleParavirtGPU', '__ZTV20AppleParavirtDisplay',
           '__ZTV25IOMobileFramebufferLegacy', '__ZTV19IOMobileFramebuffer',
           '__ZTV30IOSurfaceParavirtMapperService',
           '__ZTV29IOSurfaceParavirtMapperDevice')
for cname in CLASSES:
    link = link_of(cname)
    if link is None:
        print(f'{cname}: no vtable in sym table')
        continue
    vt = link + SLIDE + 0x10
    pat = struct.pack('<Q', vt)
    hits = []
    for sva, spa, ln in ctx.segs:
        if ln > (1 << 28):
            continue
        try:
            raw = ctx.d.read_pa(spa, ln)
        except ValueError:
            continue
        idx = 0
        while True:
            j = raw.find(pat, idx)
            if j < 0:
                break
            idx = j + 8
            if j % 8 == 0:
                hits.append(sva + j)
    print(f'{cname}: {len(hits)} instance(s): '
          + ', '.join(f'{h:#x}' for h in hits))
    for h in hits[:2]:
        for off in range(0, 0xC0, 8):
            v = Q(h + off)
            if v and v > 0xFFFFFE0000000000:
                c = class_of(v)
                print(f'    +{off:#05x}: {v:#x}'
                      + (f'  [{c}]' if c != '?' else ''))
