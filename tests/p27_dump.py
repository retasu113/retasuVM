#!/usr/bin/env python3
"""Phase 27: dump-side empirical checks (own code; 16K granule VA->PA walk).
Mode A (exec frame): parse fsck's exec stack frame from the p25 dump.
  TTBR0 root 0x85b70000 (fsck), stack [0x16e9f8000, 0x16f1f4000),
  SP 0x16f1f3cf8. Expect: [SP]=dyld mh ptr, [SP+8]=argc, argv/env/apple
  pointer arrays, string area; total frame 0x308.
Mode B (pthread struct): find the launchd spinner's stack region in the
  p24 dump (TTBR0 root 0x85bcc000), locate its top, scan for the pthread_s
  struct (sig 0x54485244 'THRD' at +0x00, tsd[0]==self at +0xE0), and read
  stackaddr@+0xB0, stackbottom@+0xB8, freeaddr@+0xC0, freesize@+0xC8,
  guardsize@+0xD0, wqthread bit (u16@+0x4E bit 10).
Usage: p27_dump.py A|B
Run on the PC in ~/retasuvm/inst/imagetest (dumps under home_p2*/).
"""
import struct
import sys

DRAM_BASE = 0x70000000
PAGE = 0x4000


class Dump:
    def __init__(self, path):
        self.d = open(path, 'rb').read()
        self.n = len(self.d)
        print(f"dump {path}: {self.n} B")

    def pa(self, pa, n):
        off = pa - DRAM_BASE
        if off < 0 or off + n > self.n:
            return None
        return self.d[off:off + n]

    def u64pa(self, pa):
        b = self.pa(pa, 8)
        return struct.unpack('<Q', b)[0] if b else None


def walk(d, root_pa, va, root_level=1):
    """16K granule walk. Returns PA or None."""
    table_pa = root_pa
    for level in range(root_level, 4):
        shift = 14 + (3 - level) * 11
        if level == root_level and root_level == 0:
            idx = (va >> 47) & 0x1
            shift = 47
        else:
            idx = (va >> shift) & 0x7FF
        off = table_pa - DRAM_BASE + idx * 8
        if off < 0 or off + 8 > d.n:
            return None
        entry = struct.unpack_from('<Q', d.d, off)[0]
        if entry & 0x1 == 0:
            return None
        typ = entry & 0x3
        if level == 3:
            if typ != 0x3:
                return None
            return (entry & 0x0000FFFFFFFFC000) + (va & 0x3FFF)
        if typ == 0x3:
            table_pa = entry & 0x0000FFFFFFFFC000
            continue
        if typ == 0x1:
            mask = (~((1 << shift) - 1)) & 0x0000FFFFFFFFFFFF
            return (entry & mask) + (va & ((1 << shift) - 1))
        return None
    return None


def read_uva(d, root, va, n):
    out = b''
    while n > 0:
        chunk = min(n, PAGE - (va & 0x3FFF))
        pa = walk(d, root, va)
        if pa is None:
            return None
        b = d.pa(pa, chunk)
        if b is None:
            return None
        out += b
        va += chunk
        n -= chunk
    return out


def u64(b, off):
    return struct.unpack_from('<Q', b, off)[0]


def mode_a():
    d = Dump('home_p25/dram_fpend_cycle1.bin')
    ROOT = 0x85B70000
    SP = 0x16F1F3CF8
    TOP = 0x16F1F4000
    frame = read_uva(d, ROOT, SP, TOP - SP)
    assert frame is not None, "stack frame not readable"
    print(f"frame {TOP - SP:#x} B from SP {SP:#x} to top {TOP:#x}")
    mh = u64(frame, 0)
    argc = u64(frame, 8)
    print(f"[SP+0x00] dyld mh ptr = {mh:#x}")
    print(f"[SP+0x08] argc = {argc}")
    # argv pointers at SP+0x10
    off = 0x10
    argv = []
    for i in range(argc):
        argv.append(u64(frame, off + 8 * i))
    print(f"argv ptrs: {[hex(a) for a in argv]}")
    off += 8 * argc
    null1 = u64(frame, off)
    print(f"NULL after argv = {null1}")
    off += 8
    env = []
    while True:
        v = u64(frame, off)
        if v == 0:
            break
        env.append(v)
        off += 8
    print(f"envc = {len(env)} ptrs: {[hex(a) for a in env]}")
    off += 8  # NULL after env
    apple = []
    while True:
        v = u64(frame, off)
        if v == 0:
            break
        apple.append(v)
        off += 8
    print(f"applec = {len(apple)} ptrs: {[hex(a) for a in apple]}")
    off += 8  # NULL after apple
    print(f"pointer area ends at SP+{off:#x}; string area SP+{off:#x}..TOP ({TOP - (SP + off):#x} B)")
    # string area: from SP+off to TOP; last 16 bytes per the diagram
    sarea = frame[off:]
    print(f"string area first 64 B: {sarea[:64]}")
    print(f"string area last 32 B: {sarea[-32:]}")
    # resolve argv[0], env strings
    for i, a in enumerate(argv):
        b = read_uva(d, ROOT, a, 256)
        s = b.split(b'\x00')[0] if b else b'?'
        print(f"argv[{i}] -> {s}")
    for i, a in enumerate(env):
        b = read_uva(d, ROOT, a, 256)
        s = b.split(b'\x00')[0] if b else b'?'
        print(f"env[{i}] -> {s}")
    for i, a in enumerate(apple):
        b = read_uva(d, ROOT, a, 256)
        s = b.split(b'\x00')[0] if b else b'?'
        print(f"apple[{i}] -> {s}")
    # arithmetic check: string_size + ptr_area_size should be 0x2F8
    # string area = TOP-16? or TOP? ptr_area_size = (argc+envc+applec+3)*8
    ptr_area_size = (argc + len(env) + len(apple) + 3) * 8
    print(f"ptr_area_size = {ptr_area_size:#x} ({ptr_area_size})")
    print(f"frame 0x308 = 8(mh) + 8(argc) + ptr_area_size {ptr_area_size:#x} + string_size ?")
    print(f"implied string_size = {0x308 - 16 - ptr_area_size:#x} ({0x308 - 16 - ptr_area_size})")
    print(f"actual string bytes SP+{off:#x}..TOP = {TOP - (SP + off):#x}")


def mode_b():
    d = Dump('home_p24/dram_fpend_cycle1.bin')
    ROOT = 0x85BCC000
    SPIN_SP = 0x16EFD2908
    # find the mapped region containing SPIN_SP by walking pages downward/upward
    # 16K pages; scan VA 0x16E000000..0x16F000000 for mapped pages
    mapped = []
    va = 0x16E000000
    while va < 0x16F000000:
        pa = walk(d, ROOT, va)
        if pa is not None:
            mapped.append(va)
        va += PAGE
    print(f"mapped 16K pages in [0x16e000000,0x16f000000): {len(mapped)}")
    # contiguous runs
    runs = []
    for v in mapped:
        if runs and v == runs[-1][1]:
            runs[-1] = (runs[-1][0], v + PAGE)
        else:
            runs.append((v, v + PAGE))
    for a, b in runs:
        mark = '  <-- contains spinner SP' if a <= SPIN_SP < b else ''
        print(f"  run [{a:#x}, {b:#x}) size {b - a:#x}{mark}")
    # the spinner's stack run: read its top pages and scan for pthread_s
    for a, b in runs:
        if a <= SPIN_SP < b:
            top = b
            print(f"spinner stack run top = {top:#x}")
            # read the whole mapped run and scan every 8-byte slot for the sig
            for page_va in range(a, b, PAGE):
                blob = read_uva(d, ROOT, page_va, PAGE)
                if blob is None:
                    print(f"  page {page_va:#x}: UNREADABLE")
                    continue
                for off in range(0, PAGE - 0x100, 8):
                    if u64(blob, off) == 0x54485244:
                        cand_va = page_va + off
                        tsd0 = u64(blob, off + 0xE0)
                        print(f"  sig match at VA {cand_va:#x} (page {page_va:#x}+{off:#x}) tsd[0]={tsd0:#x} self={tsd0 == cand_va}")
                        print(f"    stackaddr = {u64(blob, off + 0xB0):#x}")
                        print(f"    stackbottom = {u64(blob, off + 0xB8):#x}")
                        print(f"    freeaddr = {u64(blob, off + 0xC0):#x}")
                        print(f"    freesize = {u64(blob, off + 0xC8):#x}")
                        print(f"    guardsize = {u64(blob, off + 0xD0):#x}")
                        print(f"    thread_id = {u64(blob, off + 0xD8):#x}")
                        fl = struct.unpack_from('<H', blob, off + 0x4E)[0]
                        print(f"    flags u16@+0x4E = {fl:#x} wqthread={(fl >> 10) & 1} kernalloc={(fl >> 8) & 1}")
                        print(f"    fun = {u64(blob, off + 0x90):#x} arg = {u64(blob, off + 0x98):#x}")
                        print(f"    name = {blob[off + 0x50:off + 0x90].split(bytes(1))[0]}")
                        print(f"    cand_va % 16 = {cand_va % 16}")
            break


if __name__ == '__main__':
    if sys.argv[1] == 'A':
        mode_a()
    else:
        mode_b()
