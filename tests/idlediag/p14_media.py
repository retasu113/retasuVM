"""Phase 14: find IOMedia property tables in a DRAM dump and decode
them (Writable? Whole? BSD Name?) — decides whether the IOStorage
layer marks the root media non-writable.

Method: enumerate OSDictionary objects by vtable pointer; decode
every table's keys by string (cached per key-object); select tables
containing 'BSD Name' or 'Writable'; fully decode those.
OSDictionary (xnu-11417): entries ptr @+0x20, entries
{key OSSymbol*, value OSObject*}[16 B]. Count offset CALIBRATED
on this dump (p14_media_dbg4): u32 @+0x14 — three discriminating
samples matched exactly (2/2/10 entries), capacity @+0x18.
String objects: char* @+0x10 (read via segment map, physmap
fallback). OSNumber: value u64 @+0x10. OSBoolean: singleton object
addresses are calibrated from the tables themselves ('Whole' on a
whole-disk table is true by construction).

Usage: python3 p14_media.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, link_of, load_syms, SLIDE  # noqa: E402
from p4_lib import OFF as PHYSOFF  # noqa: E402

DRAM = 0x70000000
HEAP_MIN = 0xFFFFFE1000000000

_syms = {a: n for a, n in load_syms()['syms']}


def clsname(vt_link):
    n = _syms.get(vt_link)
    if not n or not n.startswith('__ZTV'):
        return n or '?'
    rest = n[5:]
    i = 0
    while i < len(rest) and rest[i].isdigit():
        i += 1
    return rest[i:] if i else rest


class Dec:
    def __init__(self, ctx):
        self.ctx = ctx
        self._strcache = {}
        self._clscache = {}

    def cls(self, obj):
        if obj not in self._clscache:
            vt = self.ctx.Qva(obj)
            self._clscache[obj] = '?' if vt is None else \
                clsname(vt - 0x10 - SLIDE)
        return self._clscache[obj]

    def read_any(self, va, size):
        raw = self.ctx.read_va(va, size)
        if raw is not None:
            return raw
        pa = va - PHYSOFF
        if DRAM <= pa < DRAM + (1 << 32):
            return self.ctx.d.read_pa(pa, size)
        return None

    def cstr_any(self, va, maxlen=256):
        raw = self.read_any(va, maxlen)
        if raw is None:
            return None
        end = raw.find(b'\x00')
        if end < 0:
            return None
        try:
            s = raw[:end].decode('ascii')
        except UnicodeDecodeError:
            return None
        return s if all(32 <= ord(c) < 127 for c in s) else None

    def string(self, obj):
        if obj in self._strcache:
            return self._strcache[obj]
        s = None
        p = self.ctx.Qva(obj + 0x10)
        if p and p > 0xFFFFFE0000000000:
            s = self.cstr_any(p, 256)
        if s is None:
            s = self.cstr_any(obj + 0x10, 64)
        self._strcache[obj] = s
        return s

    def count(self, dobj):
        pa = self.ctx.pa_of(dobj + 0x14)
        return self.ctx.d.u32_pa(pa) if pa else None

    def entries(self, dobj):
        cnt = self.count(dobj)
        arr = self.ctx.Qva(dobj + 0x20)
        if not cnt or cnt > 4096 or not arr:
            return None
        raw = self.ctx.read_va(arr, cnt * 16)
        if raw is None:
            return None
        return [struct.unpack_from('<QQ', raw, i * 16)
                for i in range(cnt)]

    def value(self, obj, boolnames):
        c = self.cls(obj)
        if c in ('OSString', 'OSSymbol'):
            return repr(self.string(obj))
        if c == 'OSBoolean':
            return boolnames.get(obj, f'OSBoolean@{obj:#x}?')
        if c == 'OSNumber':
            return f'{self.ctx.Qva(obj + 0x10)}'
        if c == 'OSData':
            return f'OSData len={self.ctx.Qva(obj + 0x10)}'
        if c == 'OSDictionary':
            return f'OSDictionary@{obj:#x} count={self.count(obj)}'
        if c == 'OSArray':
            cnt = self.ctx.Qva(obj + 0x10)
            return f'OSArray@{obj:#x} count={cnt}'
        return f'{c}@{obj:#x}'


def main():
    ctx = Ctx(sys.argv[1])
    dec = Dec(ctx)
    data = open(sys.argv[1], 'rb').read()

    vt = link_of('__ZTV12OSDictionary') + SLIDE + 0x10
    pat = struct.pack('<Q', vt)
    dicts = set()
    i = data.find(pat)
    while i != -1:
        for va in ctx.va_cands(i + DRAM):
            if va >= HEAP_MIN:
                dicts.add(va)
        i = data.find(pat, i + 1)
    print(f'OSDictionary objects in heap: {len(dicts)}')

    selected = []
    ndec = 0
    for dobj in sorted(dicts):
        ents = dec.entries(dobj)
        if not ents:
            continue
        keys = {}
        ok = True
        for k, v in ents:
            ks = dec.string(k) if dec.cls(k) in ('OSSymbol', 'OSString') \
                else None
            if ks is None:
                ok = False
                break
            keys[ks] = v
        if not ok:
            continue
        ndec += 1
        if 'BSD Name' in keys or 'Writable' in keys:
            selected.append((dobj, keys))
    print(f'dicts with fully decodable keys: {ndec}; '
          f'selected (BSD Name/Writable): {len(selected)}')

    # calibrate OSBoolean singletons: 'Whole' on a table whose
    # BSD Name has no partition suffix (or Content=GUID scheme)
    boolnames = {}
    for dobj, keys in selected:
        if 'Whole' in keys and 'BSD Name' in keys:
            nm = dec.string(keys['BSD Name'])
            if nm and 's' not in nm[4:]:
                boolnames[keys['Whole']] = 'true(Whole)'
    others = set()
    for dobj, keys in selected:
        for kk in ('Whole', 'Writable', 'Removable', 'Ejectable'):
            if kk in keys and dec.cls(keys[kk]) == 'OSBoolean':
                others.add(keys[kk])
    for o in others:
        if o not in boolnames:
            boolnames[o] = 'false(other-bool)'
    print(f'OSBoolean calibration: '
          f'{ {hex(k): v for k, v in boolnames.items()} }')
    print()
    for dobj, keys in selected:
        print(f'===== dict {dobj:#x} ({len(keys)} entries) =====')
        for ks in sorted(keys):
            print(f'  {ks!r}: {dec.value(keys[ks], boolnames)}')
        print()


if __name__ == '__main__':
    main()
