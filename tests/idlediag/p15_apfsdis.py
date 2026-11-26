#!/usr/bin/env python3
"""Phase 15: annotated disassembly of APFS kext functions in the 15.6.1 kernelcache.
Usage: p15_apfsdis.py <symbol-substring> [maxinsns] [startoff_hex]
Resolves BL/B targets to symbols and ADRP+ADD/LDR pairs to cstrings/symbols.
Also: p15_apfsdis.py --xref <symbol-substring>  (direct BL/B callers within apfs kext)
       p15_apfsdis.py --str <substring>         (find cstring VAs in apfs kext range)
"""
import struct, sys, pickle
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

KC = "/home/hatch/workspace/retasuvm/ipsw15/kernelcache.macho"
BASE = 0xFFFFFE0007004000
data = open(KC, "rb").read()

def load_commands(off):
    ncmds, = struct.unpack_from("<I", data, off + 16)
    p = off + 32
    out = []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, p)
        out.append((cmd, p))
        p += size
    return out

entries = []
for cmd, p in load_commands(0):
    if cmd == 0x80000035:
        vmaddr, fileoff, eoff = struct.unpack_from("<QQQ", data, p + 8)
        end = data.index(b"\x00", p + eoff)
        entries.append((data[p + eoff:end].decode(), vmaddr, fileoff))

APFS_LO, APFS_HI = None, None
syms = {}
for name, vmaddr, fileoff in entries:
    if name == 'com.apple.filesystems.apfs':
        APFS_LO = vmaddr
    for cmd, p in load_commands(fileoff):
        if cmd == 0x2:
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", data, p + 8)
            for i in range(nsyms):
                n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", data, symoff + i * 16)
                if n_strx == 0 or n_value == 0:
                    continue
                end = data.index(b"\x00", stroff + n_strx)
                s = data[stroff + n_strx:end].decode("utf-8", "replace")
                if name == 'com.apple.filesystems.apfs':
                    syms.setdefault(n_value, s)
# APFS kext approximate VA range: from its fileset vmaddr to next entry
vms = sorted(v for _, v, _ in entries)
idx = vms.index(APFS_LO)
APFS_HI = vms[idx + 1] if idx + 1 < len(vms) else APFS_LO + 0x400000

# also load the big kc symbol table for cross-kext names
try:
    kcsyms, _ = pickle.load(open('/home/hatch/workspace/retasuvm/tests/logs/kc_syms.pkl', 'rb'))
    for va, s in kcsyms:
        syms.setdefault(va, s)
except Exception:
    pass

sorted_syms = sorted(syms.items())

def sym_near(va):
    import bisect
    vals = [v for v, _ in sorted_syms]
    i = bisect.bisect_right(vals, va) - 1
    if i < 0:
        return None, None
    return sorted_syms[i], va - sorted_syms[i][0]

def cstr_at(link, maxlen=120):
    off = link - BASE
    if off < 0 or off >= len(data):
        return None
    end = data.find(b"\x00", off, off + maxlen)
    if end < 0:
        return None
    s = data[off:end]
    try:
        t = s.decode("utf-8")
        return t if all(32 <= ord(c) < 127 or c in "\n\t" for c in t) and len(t) >= 3 else None
    except Exception:
        return None

def disas(start, maxn, skip=0):
    above = [v for v, _ in sorted_syms if v > start]
    end = min([v for v in above if v - start < 0x40000], default=start + 0x4000)
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    md.detail = True
    code = data[start - BASE:end - BASE]
    adrp = {}
    count = 0
    for ins in md.disasm(code, start):
        if count < skip:
            count += 1
            continue
        ann = ""
        if ins.mnemonic == "adrp":
            try:
                adrp[ins.operands[0].reg] = ins.operands[1].imm
            except Exception:
                pass
        if ins.mnemonic in ("add", "ldr", "ldrb", "ldrsw") and len(ins.operands) >= 2:
            op = ins.operands[1]
            if op.type == 3:  # mem via reg in adrp map handled below via detail
                pass
            # capstone ARM64: operand types: 1=reg 2=imm 3=mem
            try:
                if op.type == 3 and op.mem.base in adrp:
                    tgt = adrp[op.mem.base] + op.mem.disp
                    s = cstr_at(tgt)
                    sy, off = sym_near(tgt)
                    if s:
                        ann = f"   ; str {tgt:#x} {s!r}"
                    elif sy and off < 0x40:
                        ann = f"   ; {tgt:#x} -> {sy[1]}+{off:#x}"
            except Exception:
                pass
            try:
                if ins.mnemonic == "add" and op.type == 2 and ins.operands[0].type == 1:
                    base_reg = ins.operands[1].reg if len(ins.operands) > 1 else None
            except Exception:
                pass
        if ins.mnemonic in ("bl", "b", "b.eq", "b.ne", "b.hi", "b.lo", "b.hs", "b.ls", "b.ge", "b.lt", "b.gt", "b.le", "cbz", "cbnz", "tbz", "tbnz") and ins.op_str.startswith("#"):
            try:
                t = int(ins.op_str.split(",")[-1].strip()[1:], 16)
                sy, off = sym_near(t)
                if sy:
                    ann = f"   ; {sy[1]}+{off:#x}"
            except Exception:
                pass
        print(f"{ins.address:#x}: {ins.mnemonic:8s} {ins.op_str}{ann}")
        count += 1
        if count - skip >= maxn:
            print("... (truncated)")
            break
    return end

def main():
    if sys.argv[1] == "--xref":
        target_sub = sys.argv[2]
        cands = [(v, s) for v, s in syms.items() if target_sub in s]
        cands.sort()
        if not cands:
            print("no symbol match"); return 1
        target = cands[0][0]
        print(f"xref target {cands[0][1]} @ {target:#x}")
        # scan apfs exec range for BL/B
        chunk = data[APFS_LO - BASE:APFS_HI - BASE]
        hits = []
        for off in range(0, len(chunk) - 3, 4):
            (w,) = struct.unpack_from("<I", chunk, off)
            if (w >> 26) in (0b100101, 0b000101):
                imm = w & 0x3FFFFFF
                if imm & 0x2000000:
                    imm -= 0x4000000
                if APFS_LO + off + imm * 4 == target:
                    hits.append(APFS_LO + off)
        for h in hits:
            sy, off = sym_near(h)
            print(f"  caller {h:#x} in {sy[1] if sy else '?'} +{off:#x}")
        print(f"{len(hits)} call sites")
        return 0
    if sys.argv[1] == "--str":
        sub = sys.argv[2].encode()
        chunk = data[APFS_LO - BASE:APFS_HI - BASE]
        pos = 0
        while True:
            i = chunk.find(sub, pos)
            if i < 0:
                break
            va = APFS_LO + i
            # string start: back up to previous NUL
            st = chunk.rfind(b"\x00", 0, i) + 1
            en = chunk.find(b"\x00", i)
            print(f"  str {APFS_LO + st:#x}: {chunk[st:en].decode('utf-8','replace')!r}")
            pos = i + 1
        return 0
    target = sys.argv[1]
    maxn = int(sys.argv[2]) if len(sys.argv) > 2 else 800
    skip = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0
    cands = [(v, s) for v, s in syms.items() if target in s and "kalloc_type_view" not in s and "os_log" not in s]
    cands.sort()
    if not cands:
        print("no symbol match"); return 1
    start, name = cands[0]
    print(f"=== {name} link={start:#x}")
    disas(start, maxn, skip)
    return 0

if __name__ == "__main__":
    sys.exit(main())
