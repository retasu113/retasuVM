"""Phase 17: parse the ADT at a known file offset in a DRAM dump and
print the /chosen node's properties verbatim (esp. boot-objects-path).

Usage: python3 p17_adt.py <dump> <root_fileoff_hex>
"""
import struct
import sys


def read_prop(data, off):
    name = data[off:off + 32].split(b'\x00')[0].decode('ascii', 'replace')
    size = struct.unpack_from('<I', data, off + 32)[0] & 0x7FFFFFFF
    val = data[off + 36: off + 36 + size]
    return name, size, val, off + 36 + ((size + 3) & ~3)


def parse_node(data, off):
    nprops, nchild = struct.unpack_from('<II', data, off)
    if nprops > 300 or nchild > 300:
        raise ValueError(f'implausible node hdr at {off:#x}: {nprops} {nchild}')
    off += 8
    props = []
    for _ in range(nprops):
        nm, size, val, off = read_prop(data, off)
        props.append((nm, size, val))
    children = []
    for _ in range(nchild):
        child, off = parse_node(data, off)
        children.append(child)
    return (props, children), off


def node_name(props):
    for nm, size, val in props:
        if nm == 'name':
            return val.split(b'\x00')[0].decode('ascii', 'replace')
    return '?'


def show(props, label):
    print(f'--- {label}: {len(props)} props ---')
    for nm, size, val in props:
        txt = val.split(b'\x00')[0]
        try:
            s = txt.decode('ascii')
            ok = all(32 <= ord(c) < 127 for c in s)
        except UnicodeDecodeError:
            ok = False
        if ok and s:
            print(f'  {nm!r} [{size}] = {s!r}')
        else:
            print(f'  {nm!r} [{size}] = hex:{val[:64].hex()}')


def main():
    data = open(sys.argv[1], 'rb').read()
    root_off = int(sys.argv[2], 0)
    (props, children), _ = parse_node(data, root_off)
    print(f'root name={node_name(props)!r} props={len(props)} children={len(children)}')
    for cprops, cchildren in children:
        nm = node_name(cprops)
        if nm == 'chosen':
            show(cprops, '/chosen')
            for gprops, _ in cchildren:
                show(gprops, f'/chosen/{node_name(gprops)}')


if __name__ == '__main__':
    main()
