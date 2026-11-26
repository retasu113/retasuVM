"""Phase 14: walk the kernel's ADT copy in the dump; dump the root
node and /chosen fully, and every boot-args/boot-uuid property.

ADT node: u32 nprops, u32 nchildren, then properties
(name[32], size u32, value[size] padded to 4), then child nodes.

Usage: python3 p14_adt.py <dump>
"""
import struct
import sys

MAXDEPTH = 4


def read_prop(data, off):
    name = data[off:off + 32].split(b'\x00')[0]
    size = struct.unpack_from('<I', data, off + 32)[0] & 0x7FFFFFFF
    val = data[off + 36: off + 36 + size]
    return name, size, val, off + 36 + ((size + 3) & ~3)


def walk(data, off, depth, path, want):
    nprops, nchild = struct.unpack_from('<II', data, off)
    if nprops > 200 or nchild > 200:
        return None
    off += 8
    props = []
    name = '?'
    for _ in range(nprops):
        try:
            nm, size, val, off = read_prop(data, off)
        except Exception:
            return None
        nm = nm.decode('ascii', 'replace')
        props.append((nm, size, val))
        if nm == 'name':
            name = val.split(b'\x00')[0].decode('ascii', 'replace')
    p = path + '/' + name
    if any(w in p for w in want) or depth == 0:
        print(f'NODE {p} (@{off:#x} hdr) props={len(props)} '
              f'children={nchild}')
        for nm, size, val in props:
            txt = val.split(b'\x00')[0]
            try:
                s = txt.decode('ascii')
                ok = all(32 <= ord(c) < 127 for c in s)
            except UnicodeDecodeError:
                ok = False
            print(f'   {nm!r} [{size}] = '
                  f'{s!r}' if ok and s else
                  f'   {nm!r} [{size}] = hex:{val[:40].hex()}')
    for _ in range(nchild):
        r = walk(data, off, depth + 1, p, want)
        if r is None:
            return off
        off = r
    return off


def main():
    data = open(sys.argv[1], 'rb').read()
    # find ADT roots: a node whose 'name' property value is
    # 'device-tree' or '' — search for the string and back up.
    roots = []
    for needle in (b'device-tree\x00',):
        i = data.find(needle)
        while i != -1:
            # value starts at i; prop header at i-36; node hdr at i-44
            cand = i - 44
            if cand >= 0 and data[i - 36:i - 32] == b'name':
                nprops, nchild = struct.unpack_from('<II', data, cand)
                if 0 < nprops < 200 and nchild < 200:
                    roots.append(cand)
            i = data.find(needle, i + 1)
    print(f'ADT root candidates: {[hex(r) for r in roots]}')
    for r in roots:
        print(f'===== ADT @ {r:#x} =====')
        walk(data, r, 0, '', ('chosen',))
        print()


if __name__ == '__main__':
    main()
