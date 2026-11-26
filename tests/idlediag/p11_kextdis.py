#!/usr/bin/env python3
"""Phase 11: disassemble a function from any kernelcache fileset kext by symbol name.
Usage: p11_kextdis.py <symbol-substring> [maxinsns]
Link addresses: fileoff = link - 0xFFFFFE0007004000."""
import struct, sys
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

# fileset entries
entries = []
for cmd, p in load_commands(0):
    if cmd == 0x80000035:
        vmaddr, fileoff, eoff = struct.unpack_from("<QQQ", data, p + 8)
        end = data.index(b"\x00", p + eoff)
        entries.append((data[p + eoff:end].decode(), vmaddr, fileoff))

syms = {}
for name, vmaddr, fileoff in entries:
    for cmd, p in load_commands(fileoff):
        if cmd == 0x2:
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", data, p + 8)
            for i in range(nsyms):
                n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", data, symoff + i * 16)
                if n_strx == 0 or n_value == 0:
                    continue
                end = data.index(b"\x00", stroff + n_strx)
                s = data[stroff + n_strx:end].decode("utf-8", "replace")
                syms.setdefault(n_value, s)

def cstr_at(link):
    off = link - BASE
    if off < 0 or off >= len(data):
        return None
    end = data.index(b"\x00", off)
    s = data[off:end]
    try:
        t = s.decode("utf-8")
        return t if all(32 <= ord(c) < 127 or c in "\n\t" for c in t) else None
    except Exception:
        return None

target = sys.argv[1]
maxn = int(sys.argv[2]) if len(sys.argv) > 2 else 400
cands = [(v, s) for v, s in syms.items() if target in s and not s.endswith("_fmt") and "os_log" not in s]
cands.sort()
if not cands:
    print("no symbol match"); sys.exit(1)
start, name = cands[0]
# function end = next symbol above start (same kext region, within 0x20000)
above = sorted(v for v in syms if v > start)
end = min([v for v in above if v - start < 0x30000], default=start + 0x2000)
print(f"=== {name} link={start:#x} len={end-start:#x}")
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = False
code = data[start - BASE:end - BASE]
count = 0
for ins in md.disasm(code, start):
    ann = ""
    if ins.mnemonic in ("bl", "b") and ins.op_str.startswith("#"):
        t = int(ins.op_str[1:], 16)
        if t in syms:
            ann = f"   ; {syms[t]}"
    if ins.mnemonic == "adrp":
        pass
    print(f"{ins.address:#x}: {ins.mnemonic:8s} {ins.op_str}{ann}")
    count += 1
    if count >= maxn:
        print("... (truncated)")
        break
