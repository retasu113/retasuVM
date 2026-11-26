#!/usr/bin/env python3
# Phase 19: read-only APFS walker for the golden image (milestone 1:
# GPT -> container checkpoint -> newest NXSB -> container omap ->
# volume list). Empirical field validation at every layer.
import struct, sys, uuid

IMG = sys.argv[1] if len(sys.argv) > 1 else '/home/retasu/retasuvm/inst/imagetest/images/disk.raw'
f = open(IMG, 'rb')

def rd(off, n):
    f.seek(off)
    return f.read(n)

def cksum_ok(blk):
    # APFS object checksum: fletcher64 over block with first 8 bytes zeroed
    data = bytearray(blk)
    stored = struct.unpack_from('<Q', data, 0)[0]
    data[0:8] = b'\0' * 8
    s1 = s2 = 0
    for (w,) in struct.iter_unpack('<I', bytes(data)):
        s1 = (s1 + w) % 0xFFFFFFFF
        s2 = (s2 + s1) % 0xFFFFFFFF
    calc = ((s2 << 32) | s1)
    # APFS uses a variant: cksum = ((sum2 ^ 0xFFFFFFFF) ... ) -- report both
    return stored, calc

# ---------- GPT ----------
hdr = rd(512, 512)
assert hdr[:8] == b'EFI PART', hdr[:8]
part_lba, part_cnt, part_sz = struct.unpack_from('<QII', hdr, 72)
parts = []
for i in range(part_cnt):
    e = rd(part_lba * 512 + i * part_sz, part_sz)
    if e[:16] == b'\0' * 16:
        continue
    first, last = struct.unpack_from('<QQ', e, 32)
    name = e[56:128].decode('utf-16-le', 'replace').rstrip('\0')
    parts.append((name, first * 512, (last - first + 1) * 512,
                  uuid.UUID(bytes_le=e[:16])))
    print(f"GPT[{i}] {name!r} off={first*512} size={(last-first+1)*512} type={uuid.UUID(bytes_le=e[:16])}")

# main container = largest APFS container partition
APFS_GUID = uuid.UUID('7c3457ef-0000-11aa-aa11-00306543ecac')
cands = [p for p in parts if p[3] == APFS_GUID]
main = max(cands, key=lambda p: p[2])
print('main container:', main[0], 'off', main[1], 'size', main[2])
COFF, CSIZE = main[1], main[2]

def blk(n, bs=4096):
    return rd(COFF + n * bs, bs)

# ---------- block 0 NXSB ----------
b0 = blk(0)
oid0, xid0, typ0 = struct.unpack_from('<QQI', b0, 8)
magic0 = b0[0x20:0x24]
print(f"block0: oid={oid0} xid={xid0} type={typ0 & 0xffff} magic={magic0}")
BS = struct.unpack_from('<I', b0, 0x24)[0]
print('block size', BS)
desc_base, data_base = struct.unpack_from('<QQ', b0, 0x68)
desc_blocks, data_blocks = struct.unpack_from('<II', b0, 0x78)
print(f"checkpoint desc_base={desc_base} desc_blocks={desc_blocks} data_base={data_base} data_blocks={data_blocks}")

# ---------- scan checkpoint area for NXSB copies + checkpoint maps ----------
nxsb = {}   # xid -> (block, raw)
cpmaps = [] # (xid, entries[(oid, paddr, type, subtype, size, fs_oid)])
for area_base, area_blocks, tag in ((desc_base, desc_blocks, 'desc'), (data_base, data_blocks, 'data')):
    for i in range(area_blocks):
        b = blk(area_base + i)
        o_oid, o_xid, o_type = struct.unpack_from('<QQI', b, 8)
        t = o_type & 0xffff
        if b[0x20:0x24] == b'NXSB' and t == 1:
            nxsb[o_xid] = (area_base + i, b)
        elif t == 11:  # checkpoint map
            cnt = struct.unpack_from('<I', b, 32)[0]
            ents = []
            for j in range(cnt):
                et, esub, esz = struct.unpack_from('<III', b, 40 + j * 40)
                efs, eoid, epad = struct.unpack_from('<QQQ', b, 40 + j * 40 + 12)
                ents.append((eoid, epad, et, esub, esz, efs))
            cpmaps.append((o_xid, ents))
print(f"NXSB copies: xids {sorted(nxsb)}")
print(f"checkpoint maps: {[(x, len(e)) for x, e in cpmaps]}")
newest_xid = max(nxsb)
nx_blkno, nx = nxsb[newest_xid]
print(f"newest NXSB xid={newest_xid} at container block {nx_blkno}")
st, ca = cksum_ok(nx)
print(f"NXSB stored cksum {st:#x} fletcher-calc {ca:#x}")

# newest checkpoint map entries: oid -> paddr (max xid map)
best = {}
for mxid, ents in cpmaps:
    for (eoid, epad, et, esub, esz, efs) in ents:
        if eoid not in best or mxid >= best[eoid][0]:
            best[eoid] = (mxid, epad, et, esub)
print('checkpoint map oids:', {k: (hex(v[1]), v[2]) for k, v in sorted(best.items())})

# ---------- dump NXSB u64 fields to locate omap_oid / fs_oid[] ----------
print('NXSB u64 fields 0x90..0x130:')
for off in range(0x90, 0x130, 8):
    v = struct.unpack_from('<Q', nx, off)[0]
    mark = ''
    if v in best:
        mark = f'  <- in cpmap -> block {best[v][1]} type {best[v][2]}'
    print(f'  +{off:#05x}: {v:#x}{mark}')
