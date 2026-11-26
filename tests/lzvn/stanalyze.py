#!/usr/bin/env python3
"""Phase 20: analyze storetrace.bin from the src_p20 boot.

Usage: stanalyze.py <storetrace.bin> <dump.bin> [page_pa_hex]
1. Find the corrupted block-1 page in the dump (GOT hash).
2. List every store to that page (in trace order) with symbolized PC.
3. Show the stores covering the first 8 bytes in detail.
"""
import hashlib, pickle, struct, sys, bisect

GOT = '002c0ae7a8372504b094c9596d568512770dca087b1d4281bf636425f27360ff'
RAMBASE = 0x70000000

def main():
    trace_path, dump_path = sys.argv[1], sys.argv[2]
    d = open(dump_path, 'rb').read()
    page_pa = None
    if len(sys.argv) > 3:
        page_pa = int(sys.argv[3], 16)
    else:
        for off in range(0, len(d) - 16384, 4096):
            if hashlib.sha256(d[off:off + 16384]).hexdigest() == GOT:
                page_pa = off + RAMBASE
                break
    print('corrupted page PA:', hex(page_pa) if page_pa else 'NOT FOUND')
    if page_pa is None:
        return
    syms, _ = pickle.load(open('/home/retasu/retasuvm/tests/logs/kc_syms.pkl', 'rb')) \
        if False else (None, None)
    # symbol table is on the analyst machine; load if present
    import os
    symlist = []
    for cand in (os.path.expanduser('~/retasuvm/tests/logs/kc_syms.pkl'),
                 '/home/hatch/workspace/retasuvm/tests/logs/kc_syms.pkl'):
        if os.path.exists(cand):
            syms, _ = pickle.load(open(cand, 'rb'))
            symlist = sorted(syms)
            break
    addrs = [a for a, n in symlist]
    def sym(pc):
        if not symlist:
            return '?'
        i = bisect.bisect_right(addrs, pc) - 1
        if i < 0:
            return '?'
        a, n = symlist[i]
        return '%s+0x%x' % (n, pc - a)
    raw = open(trace_path, 'rb').read()
    n = len(raw) // 32
    print('trace records:', n)
    hits = []
    for i in range(n):
        pc, pa, val, misc = struct.unpack_from('<QQQQ', raw, i * 32)
        kind = misc & 1
        size = (misc >> 8) & 0xFF
        instr = misc >> 16
        if kind == 0 and page_pa <= pa < page_pa + 16384:
            hits.append((i, pc, pa, val, size, instr))
    print('stores to corrupted page:', len(hits))
    for i, pc, pa, val, size, instr in hits:
        print('rec %d instr %d pc 0x%x (%s) pa 0x%x +%04x size %d val 0x%016x' %
              (i, instr, pc, sym(pc), pa, pa - page_pa, size, val))
    # loads of the page (verify reads)
    print('--- first loads of page start ---')
    shown = 0
    for i in range(n):
        pc, pa, val, misc = struct.unpack_from('<QQQQ', raw, i * 32)
        kind = misc & 1
        size = (misc >> 8) & 0xFF
        instr = misc >> 16
        if kind == 1 and pa == page_pa and shown < 10:
            print('rec %d instr %d pc 0x%x (%s) size %d val 0x%016x' %
                  (i, instr, pc, sym(pc), size, val))
            shown += 1

if __name__ == '__main__':
    main()
