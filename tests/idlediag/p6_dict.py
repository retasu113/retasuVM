"""Phase 6: (A) decode [fa]'s matching OSDictionary (what resource /
service it waits for); (C) signature-scan the thread zone for a thread
struct with id 0x9c (the 'gfx' config thread).

Usage: python3 p6_dict.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, thread_info, load_syms, SLIDE  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva
syms = {a: n for a, n in load_syms()['syms']}


def class_of(obj):
    vt = Q(obj)
    if vt is None:
        return '?'
    return syms.get(vt - 0x10 - SLIDE, f'vt@{vt - 0x10 - SLIDE:#x}')


def osstr(obj):
    """OSString/OSSymbol: try inline string at +0x10 and +0x18."""
    for off in (0x10, 0x18, 0x08):
        s = ctx.read_cstr(obj + off, 64)
        if s and all(32 <= ord(c) < 127 for c in s) and len(s) >= 2:
            return s
    return None


DICT = 0xFFFFFE2839DC2840
print(f'===== matching dictionary {DICT:#x} class={class_of(DICT)} =====')
raw = ctx.read_va(DICT, 0x40)
for off in range(0, 0x40, 8):
    print(f'  +{off:#04x}: {struct.unpack_from("<Q", raw, off)[0]:#018x}')
# OSDictionary: after OSObject hdr (0x10): capacity u32 @+0x10,
# count u32 @+0x14, entries ptr @+0x18 (empirical; verify by shape)
count = struct.unpack_from('<I', raw, 0x14)[0]
entries = struct.unpack_from('<Q', raw, 0x18)[0]
print(f'  count={count} entries={entries:#x}')
if entries and count < 64:
    eraw = ctx.read_va(entries, count * 16)
    for i in range(count):
        k, v = struct.unpack_from('<QQ', eraw, i * 16)
        print(f'  [{i}] key {k:#x} class={class_of(k)} str={osstr(k)!r}')
        print(f'      val {v:#x} class={class_of(v)} str={osstr(v)!r}')

print('\n===== scan thread zone for id 0x9c =====')
found = []
for sva, spa, ln in ctx.segs:
    if not (0xFFFFFE1840000000 <= sva < 0xFFFFFE1850000000):
        continue
    raw = ctx.d.read_pa(spa, ln)
    for off in range(0, ln - 0x7E0, 8):
        if struct.unpack_from('<Q', raw, off + 0x498)[0] != 0x9c:
            continue
        tva = sva + off
        ti = thread_info(ctx, tva)
        if ti and ti['stack_va']:
            found.append((tva, ti))
            print(f'  CANDIDATE {tva:#x} id=0x9c name={ti["name"]!r} '
                  f'wait={ti["wait_event"]:#x} waitq={Q(tva + 0x28):#x} '
                  f'stack={ti["stack_va"]:#x} '
                  f'state=0x{ti["state_byte"]:02x}')
if not found:
    print('  no validated thread struct with id 0x9c in the thread zone')
