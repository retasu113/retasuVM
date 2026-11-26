#!/usr/bin/env python3
# Phase 19 stage 2: walk the snapshot fs tree (xid 36) and collect all
# records for the target inode / dstream ids.
import struct, sys

IMG = '/home/retasu/retasuvm/inst/imagetest/images/disk.raw'
COFF = 524308480
BS = 4096
f = open(IMG, 'rb')

def blk(n):
    f.seek(COFF + n * BS)
    return f.read(BS)

def hdr(b):
    oid, xid, typ, sub = struct.unpack_from('<QQII', b, 8)
    return oid, xid, typ & 0xffff, sub

class Node:
    def __init__(self, paddr, fixed_ks=None, fixed_vs=None):
        self.paddr = paddr
        b = blk(paddr)
        self.raw = b
        self.oid, self.xid, self.type, self.sub = hdr(b)
        self.flags, self.level, self.nkeys = struct.unpack_from('<HHI', b, 32)
        self.tso, self.tsl = struct.unpack_from('<HH', b, 40)
        self.fixed = bool(self.flags & 0x4)
        self.root = bool(self.flags & 0x1)
        self.leaf = bool(self.flags & 0x2)
        self.data_end = BS - 40 if self.root else BS
        if self.root:
            (self.bt_key_size, self.bt_val_size) = struct.unpack_from('<II', b, BS - 40 + 8)
        else:
            self.bt_key_size, self.bt_val_size = fixed_ks, fixed_vs

    def entries(self):
        b = self.raw
        out = []
        for i in range(self.nkeys):
            if self.fixed:
                ko, vo = struct.unpack_from('<HH', b, 56 + self.tso + i * 4)
                klen, vlen = self.bt_key_size, self.bt_val_size
            else:
                ko, kl, vo, vl = struct.unpack_from('<HHHH', b, 56 + self.tso + i * 8)
                klen, vlen = kl, vl
            key = b[56 + self.tsl + ko: 56 + self.tsl + ko + klen]
            if self.leaf:
                val = b[self.data_end - vo: self.data_end - vo + vlen]
            else:
                val = b[self.data_end - vo: self.data_end - vo + 8]
            out.append((key, val))
        return out

class Omap:
    def __init__(self, phys_paddr):
        b = blk(phys_paddr)
        self.tree_oid, self.snap_tree_oid = struct.unpack_from('<QQ', b, 48)
        r = Node(self.tree_oid)
        self.fks, self.fvs = r.bt_key_size, r.bt_val_size
        self.root = r

    def node(self, p):
        return Node(p, self.fks, self.fvs)

    def lookup(self, oid, xid):
        node = self.root
        best = None
        while True:
            ents = node.entries()
            if node.leaf:
                for k, v in ents:
                    koid, kxid = struct.unpack('<QQ', k)
                    if koid == oid and kxid <= xid:
                        best = v
                return struct.unpack_from('<Q', best, 8)[0] if best else None
            child = None
            for k, v in ents:
                koid, kxid = struct.unpack('<QQ', k)
                if (koid, kxid) <= (oid, xid):
                    child = struct.unpack('<Q', v)[0]
                else:
                    break
            if child is None:
                return None
            node = self.node(child)

class FrozenOmap:
    """Omap tree rooted directly at a btree root paddr (snapshot-frozen)."""
    def __init__(self, root_paddr):
        r = Node(root_paddr)
        self.fks, self.fvs = r.bt_key_size, r.bt_val_size
        self.root = r

    def node(self, p):
        return Node(p, self.fks, self.fvs)

    def lookup(self, oid, xid):
        node = self.root
        best = None
        while True:
            ents = node.entries()
            if node.leaf:
                for k, v in ents:
                    koid, kxid = struct.unpack('<QQ', k)
                    if koid == oid and kxid <= xid:
                        best = v
                return struct.unpack_from('<Q', best, 8)[0] if best else None
            child = None
            for k, v in ents:
                koid, kxid = struct.unpack('<QQ', k)
                if (koid, kxid) <= (oid, xid):
                    child = struct.unpack('<Q', v)[0]
                else:
                    break
            if child is None:
                return None
            node = self.node(child)

# Frozen omap root as of xid 36, found by container scan:
# block 290612 (type 2, sub 11, root, level 2, xid 36).
vomap = FrozenOmap(290612)
print(f'frozen omap: sblock 0x4651b -> {vomap.lookup(0x4651b, 36)}, '
      f'root_tree 66491 -> {vomap.lookup(66491, 36)}, '
      f'fs child 3465 -> {vomap.lookup(3465, 36)}')
root_paddr = vomap.lookup(66491, 36)
print(f'fs tree root (snapshot, xid<=36): paddr {root_paddr}')
root = Node(root_paddr)
print(f'  root: oid={root.oid} xid={root.xid} type={root.type} sub={root.sub} flags={root.flags:#x} level={root.level} nkeys={root.nkeys}')
info = root.raw[BS-40:BS]
print(f'  btree_info: {info.hex()}')
bt_flags, bt_ns, bt_ks, bt_vs = struct.unpack_from('<IIII', info, 0)
bt_lk, bt_lv, bt_kc, bt_nc = struct.unpack_from('<IIQQ', info, 16)
print(f'  bt_flags={bt_flags:#x} key_count={bt_kc} node_count={bt_nc}')

TARGETS = {0xFFFFFFF0009D039, 0xFFFFFFF0009D03A, 0x9D039, 0x9D03A}
found = []
nleaf = 0
nrec = 0

def walk(node):
    global nleaf, nrec
    ents = node.entries()
    if node.leaf:
        nleaf += 1
        for k, v in ents:
            nrec += 1
            if len(k) >= 8:
                kh = struct.unpack('<Q', k[:8])[0]
                if (kh & 0xFFFFFFFFFFFFFFF) in TARGETS:
                    found.append((k, v, node.paddr))
    else:
        for k, v in ents:
            # hashed-tree internal value: {u64 node_number, 32B hash};
            # child omap oid = root_tree_oid (66491) + node_number
            child_num = struct.unpack('<Q', v)[0]
            child_paddr = vomap.lookup(66491 + child_num, 36)
            if child_paddr is None:
                print(f'  !! unresolved child num {child_num} from node {node.paddr}')
                continue
            walk(Node(child_paddr))

walk(root)
print(f'walked {nleaf} leaves, {nrec} records; {len(found)} target records')
for k, v, lp in found:
    kh = struct.unpack('<Q', k[:8])[0]
    oid = kh & 0xFFFFFFFFFFFFFFF
    typ = kh >> 60
    print(f'--- leaf {lp}: oid={oid:#x} type={typ} keylen={len(k)} vallen={len(v)}')
    print(f'    key: {k.hex()}')
    print(f'    val: {v[:120].hex()}')
