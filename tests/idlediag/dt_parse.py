#!/usr/bin/env python3
"""Parse an Apple-format device tree in a DRAM dump and print it.

Format (iBoot/XNU DeviceTree): node = u32 nProps, u32 nChildren,
then nProps properties, then nChildren child nodes (recursive).
Property = char name[32], u32 length (bit31 = flag), value padded
to a 4-byte boundary.

Usage: dt_parse.py <dump.bin> <scan_start_hex> <scan_end_hex>
Scans the window for a root node that parses cleanly, then prints
the tree (path, compatible, reg, interrupts).
"""
import re
import struct
import sys

data = open(sys.argv[1], "rb").read()
w0 = int(sys.argv[2], 0)
w1 = int(sys.argv[3], 0)

NAME_RE = re.compile(rb"^[\x20-\x7e]{1,31}\x00*$")


def prop_name_at(off):
    raw = data[off:off + 32]
    if len(raw) < 32 or not NAME_RE.match(raw):
        return None
    return raw.split(b"\x00")[0].decode("ascii", "replace")


def parse_node(off, depth, max_depth=8):
    """Return (end_offset, node_dict) or raise ValueError."""
    if depth > max_depth or off + 8 > len(data):
        raise ValueError("depth/bounds")
    nprops, nchild = struct.unpack_from("<II", data, off)
    if nprops > 64 or nchild > 64:
        raise ValueError(f"implausible counts {nprops}/{nchild} @0x{off:x}")
    p = off + 8
    props = []
    for _ in range(nprops):
        name = prop_name_at(p)
        if name is None:
            raise ValueError(f"bad prop name @0x{p:x}")
        ln = struct.unpack_from("<I", data, p + 32)[0]
        flag = bool(ln & 0x80000000)
        ln &= 0x7FFFFFFF
        if ln > 65536:
            raise ValueError(f"prop len {ln} @0x{p:x}")
        val = data[p + 36:p + 36 + ln]
        props.append((name, ln, flag, val))
        p += 36 + ((ln + 3) & ~3)
    children = []
    for _ in range(nchild):
        end, child = parse_node(p, depth + 1, max_depth)
        children.append(child)
        p = end
    return p, {"props": props, "children": children, "off": off}


def node_name(node):
    for name, ln, flag, val in node["props"]:
        if name == "name":
            return val.split(b"\x00")[0].decode("ascii", "replace")
    return "?"


def show(node, path, depth=0):
    nm = node_name(node)
    p = f"{path}/{nm}" if path else nm
    interesting = {}
    for name, ln, flag, val in node["props"]:
        if name == "compatible":
            interesting["compatible"] = val.split(b"\x00")[0].decode("ascii", "replace")
        elif name == "interrupts":
            cells = struct.unpack("<%dI" % (ln // 4), val[:ln // 4 * 4]) if ln % 4 == 0 else ()
            interesting["interrupts"] = cells
        elif name == "reg":
            cells = struct.unpack("<%dI" % (ln // 4), val[:ln // 4 * 4]) if ln % 4 == 0 else ()
            interesting["reg"] = cells
    print(f"{'  ' * depth}{p} @0x{node['off']:x} {interesting}")
    for c in node["children"]:
        show(c, p, depth + 1)


found = None
for cand in range(w0, w1, 4):
    if prop_name_at(cand + 8) is None:
        continue
    try:
        end, root = parse_node(cand, 0)
    except (ValueError, struct.error):
        continue
    # Root should have several children (cpus, arm-io, chosen, ...).
    if len(root["children"]) >= 3:
        print(f"ROOT @0x{cand:x}, tree size {end - cand} bytes")
        show(root, "")
        found = cand
        break
if found is None:
    print("no clean root parse in window")
