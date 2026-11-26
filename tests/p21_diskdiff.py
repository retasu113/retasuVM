import sys
GOLD = '/home/retasu/retasuvm/inst/imagetest/images/disk.raw'
P23 = '/home/retasu/retasuvm/inst/imagetest/home_p23/workspace/retasuvm/disks/root.img'
BS = 4096
CH = 1024 * 1024  # 1MB chunk
diff_blocks = []
total_blocks = 0
n_diff = 0
per_gb = {}
with open(GOLD, 'rb') as fg, open(P23, 'rb') as fp:
    off = 0
    while True:
        cg = fg.read(CH)
        cp = fp.read(CH)
        if not cg and not cp:
            break
        if cg != cp:
            for b in range(0, len(cg), BS):
                gb = cg[b:b+BS]
                pb = cp[b:b+BS]
                if gb != pb:
                    blk = (off + b) // BS
                    diff_blocks.append(blk)
                    n_diff += 1
                    g = blk * BS // (1 << 30)
                    per_gb[g] = per_gb.get(g, 0) + 1
        total_blocks += len(cg) // BS
        off += len(cg)
        if off % (1 << 30) == 0:
            print('  ...%d GB scanned, diff blocks so far: %d' % (off >> 30, n_diff), flush=True)
print('total 4KiB blocks:', total_blocks)
print('differing blocks:', n_diff)
print('differing bytes:', n_diff * BS)
print('per-GB distribution:', dict(sorted(per_gb.items())))
if diff_blocks:
    print('first 20 diff block idx:', diff_blocks[:20])
    print('last 20 diff block idx:', diff_blocks[-20:])
    ranges = []
    s = p = diff_blocks[0]
    for blk in diff_blocks[1:]:
        if blk == p + 1:
            p = blk
        else:
            ranges.append((s, p))
            s = p = blk
    ranges.append((s, p))
    print('num ranges:', len(ranges))
    for a, b in ranges[:40]:
        print('  blocks %d..%d (bytes %#x..%#x, len %d B)' % (a, b, a*BS, (b+1)*BS, (b-a+1)*BS))
