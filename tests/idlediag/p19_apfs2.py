#!/usr/bin/env python3
# Phase 19: full read-only APFS walker for the golden image.
# Conventions (empirically validated, see phase-19 report):
#  - TOC at 56+table_space.off; fixed-KV entry={u16 key_off,u16 val_off},
#    variable entry={u16 key_off,u16 key_len,u16 val_off,u16 val_len}.
#  - key bytes at 56+table_space.len+key_off.
#  - value bytes at (data_end - val_off), data_end = node_size-40 if
#    btn_flags&ROOT else node_size.
#  - omap value = {u32 flags, u32 size, u64 paddr}; omap key = (oid,xid).
#  - fs keys: 8-byte header = oid | type<<60; extent keys append u64
#    logical_addr; xattr keys append u16 name_len + name.
import struct, sys, uuid

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

class Tree:
    def __init__(self, root_paddr):
        self.root = Node(root_paddr)
        self.fks = self.root.bt_key_size if self.root.fixed else None
        self.fvs = self.root.bt_val_size if self.root.fixed else None

    def node(self, paddr):
        return Node(paddr, self.fks, self.fvs)

    def lookup(self, key):
        """Return value bytes for exact key, or None. Descends internal nodes."""
        node = self.root
        while True:
            ents = node.entries()
            if node.leaf:
                for k, v in ents:
                    if k == key:
                        return v
                return None
            # internal: choose last entry with entry_key <= key
            child = None
            for k, v in ents:
                if k <= key:
                    child = struct.unpack('<Q', v)[0]
                else:
                    break
            if child is None:
                return None
            node = self.node(child)

    def range_from(self, key_prefix_hdr):
        """Yield (key, val) for all entries in the tree (full walk)."""
        stack = [self.root]
        while stack:
            node = stack.pop()
            ents = node.entries()
            if node.leaf:
                for k, v in ents:
                    yield k, v
            else:
                for k, v in ents:
                    stack.append(self.node(struct.unpack('<Q', v)[0]))

class Omap:
    def __init__(self, phys_paddr):
        b = blk(phys_paddr)
        oid, xid, t, s = hdr(b)
        assert t == 11, f'omap_phys type {t}'
        self.tree_oid, self.snap_tree_oid = struct.unpack_from('<QQ', b, 48)
        self.tree = Tree(self.tree_oid)

    def lookup(self, oid, xid):
        """Greatest (oid,xid') with xid'<=xid -> paddr, or None."""
        node = self.tree.root
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
            node = self.tree.node(child)

# ---------- container omap ----------
comap = Omap(170944)
print(f'container omap tree root {comap.tree_oid}')
for fs_oid in (1026, 1030, 1032, 1034, 33230, 113919):
    print(f'  fs_oid {fs_oid} -> APSB paddr {comap.lookup(fs_oid, 1768)}')

# ---------- Macintosh HD APSB ----------
apsb_blk = comap.lookup(1026, 1768)
apsb = blk(apsb_blk)
a_oid, a_xid, a_t, _ = hdr(apsb)
print(f'System APSB at {apsb_blk}: oid={a_oid} xid={a_xid}')
vol_omap_paddr, vol_root_oid, vol_extref_oid, vol_snapmeta_paddr = struct.unpack_from('<QQQQ', apsb, 0x80)
next_obj_id = struct.unpack_from('<Q', apsb, 0xB0)[0]
print(f'  vol omap_phys paddr={vol_omap_paddr} root_tree_oid={vol_root_oid} extentref_oid={vol_extref_oid} snapmeta root={vol_snapmeta_paddr}')
print(f'  next_obj_id={next_obj_id:#x} vol_uuid={uuid.UUID(bytes=apsb[0xF0:0x100])}')

vomap = Omap(vol_omap_paddr)
print(f'volume omap tree root {vomap.tree_oid}')

# ---------- snapshot metadata (xid 36) ----------
smtree = Tree(vol_snapmeta_paddr)
for k, v in smtree.range_from(b''):
    kh = struct.unpack('<Q', k[:8])[0]
    print(f'  snapmeta key hdr={kh:#x} keylen={len(k)} vallen={len(v)} val[:24]={v[:24].hex()}')
    if (kh >> 60) == 1:
        snap_xid = kh & 0xFFFFFFFFFFFFFFF
        sblock_oid = None
        # scan value for the guest-printed sblock oid 0x4651b
        for off in range(0, len(v) - 7, 8):
            if struct.unpack_from('<Q', v, off)[0] == 0x4651b:
                sblock_oid = 0x4651b
                print(f'    sblock_oid 0x4651b found at val+{off}')
        print(f'    snap_xid={snap_xid}')
        if snap_xid == 36:
            snap_apsb_paddr = vomap.lookup(0x4651b, 36)
            print(f'    snapshot APSB paddr (omap@36) = {snap_apsb_paddr}')
            sb = blk(snap_apsb_paddr)
            s_oid, s_xid, s_t, _ = hdr(sb)
            print(f'    snapshot APSB: oid={s_oid:#x} xid={s_xid} type={s_t} magic={sb[0x20:0x24]}')
            s_omap, s_root, s_ext, s_snap = struct.unpack_from('<QQQQ', sb, 0x80)
            print(f'    snap omap={s_omap} root_tree_oid={s_root} extentref={s_ext} snapmeta={s_snap}')
            print(f'    snap root tree paddr (omap@36) = {vomap.lookup(s_root, 36)}')
            print(f'    snap next_obj_id={struct.unpack_from("<Q", sb, 0xB0)[0]:#x}')
