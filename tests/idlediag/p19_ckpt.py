#!/usr/bin/env python3
# Phase 19: scan the checkpoint descriptor ring (container blocks
# 1..237) of the golden main container; list every object found
# (checkpoint maps, NXSB copies) with xid/type, and dump the newest
# checkpoint map's entries.
import struct, sys

IMG = '/home/retasu/retasuvm/inst/imagetest/images/disk.raw'
COFF = 524308480
BS = 4096
f = open(IMG, 'rb')

def blk(n):
    f.seek(COFF + n * BS)
    return f.read(BS)

maps = []
nxsbs = []
others = []
for n in range(1, 238):
    b = blk(n)
    oid, xid, typ = struct.unpack_from('<QQI', b, 8)
    t, sub = typ & 0xffff, (typ >> 16) & 0xffff
    if b[0x20:0x24] == b'NXSB':
        nxsbs.append((xid, n))
    elif t == 11:
        cnt = struct.unpack_from('<I', b, 32)[0]
        maps.append((xid, n, cnt))
    elif t != 0 or oid != 0:
        others.append((n, oid, xid, t, sub))
print('NXSB copies (xid, block):', nxsbs)
print('checkpoint maps (xid, block, count):', maps)
print('other nonzero blocks:', others[:20])

# parse the newest checkpoint map fully
if maps:
    mxid, mblk, mcnt = max(maps)
    b = blk(mblk)
    print(f'--- newest checkpoint map xid={mxid} block={mblk} count={mcnt}')
    for j in range(mcnt):
        base = 40 + j * 40
        et, esub, esz = struct.unpack_from('<III', b, base)
        efs, eoid, epad = struct.unpack_from('<QQQ', b, base + 12)
        print(f'  [{j}] type={et} sub={esub} size={esz} fs_oid={efs} oid={eoid} paddr={epad}')
