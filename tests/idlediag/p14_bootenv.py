"""Phase 14: extract boot-environment inputs from the dump.

(1) Every 'boot-args' occurrence interpreted as an ADT property
    (name[32], size u32 @+32, value @+36): print the value.
(2) Locate the ADT /chosen node and dump all its properties.
(3) Dump the region around each 'boot-args' hit as strings for
    manual context.

Usage: python3 p14_bootenv.py <dump>
"""
import struct
import sys

DRAM = 0x70000000


def props_at(data, off):
    """Try to read an ADT property whose name starts at off."""
    if off + 36 > len(data):
        return None
    size = struct.unpack_from('<I', data, off + 32)[0]
    if size & 0x7FFFFFFF > 8192:
        return None
    val = data[off + 36: off + 36 + (size & 0x7FFFFFFF)]
    return size, val


def show(off, size, val):
    txt = val.split(b'\x00')[0]
    try:
        s = txt.decode('ascii')
        printable = all(32 <= ord(c) < 127 for c in s)
    except UnicodeDecodeError:
        printable = False
    print(f'  @{off:#x} size={size:#x} value='
          f'{s!r}' if printable else
          f'  @{off:#x} size={size:#x} value(hex)={val[:48].hex()}')


def main():
    data = open(sys.argv[1], 'rb').read()
    print('== boot-args occurrences as ADT properties ==')
    i = data.find(b'boot-args\x00')
    hits = []
    while i != -1:
        hits.append(i)
        i = data.find(b'boot-args\x00', i + 1)
    for h in hits:
        r = props_at(data, h)
        print(f'hit fileoff {h:#x}: {r if r is None else ""}')
        if r:
            show(h, r[0], r[1])

    print()
    print('== /chosen node hunt ==')
    # A node's 'name' property: 'name' name-field, size, 'chosen'.
    # Scan for 'chosen\x00' and test the ADT node structure backwards:
    # node header is 8 bytes (nprops, nchildren) before its first
    # property; the first property is conventionally 'name'.
    i = data.find(b'chosen\x00')
    nodes = []
    while i != -1:
        # value of 'name' prop: prop at i-36 (name field 32 + size 4)
        pstart = i - 36
        if pstart >= 8 and data[pstart:pstart + 4] == b'name':
            nodes.append(pstart - 8)
        i = data.find(b'chosen\x00', i + 1)
    print(f'candidate /chosen nodes: {[hex(n) for n in nodes]}')
    for nstart in nodes:
        nprops, nchild = struct.unpack_from('<II', data, nstart)
        print(f'node @{nstart:#x}: nprops={nprops} nchildren={nchild}')
        if nprops > 64:
            continue
        off = nstart + 8
        for _ in range(nprops):
            name = data[off:off + 32].split(b'\x00')[0]
            size = struct.unpack_from('<I', data, off + 32)[0]
            val = data[off + 36: off + 36 + (size & 0x7FFFFFFF)]
            try:
                nm = name.decode('ascii')
            except UnicodeDecodeError:
                break
            txt = val.split(b'\x00')[0]
            try:
                s = txt.decode('ascii')
                ok = all(32 <= ord(c) < 127 for c in s) and s
            except UnicodeDecodeError:
                ok = False
            print(f'  prop {nm!r} size={size & 0x7FFFFFFF}: '
                  f'{s!r}' if ok else
                  f'  prop {nm!r} size={size & 0x7FFFFFFF}: '
                  f'hex={val[:32].hex()}')
            off += 36 + ((size & 0x7FFFFFFF) + 3 & ~3)


if __name__ == '__main__':
    main()
