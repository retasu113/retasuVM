#!/usr/bin/env python3
"""Phase 22: resolve libsystem_c symbol names for the symbols near PC.
n_strx -> file offset = stroff(0x86d876e0) + n_strx -> chunk + offset."""
import struct

PC = 0x1803089EC
STROFF = 0x86d876e0
SYM_CHUNK = "/tmp/p22_sym_32329.bin"
SYM_OFF = 0x52c0
NSYMS = 2513
CHUNKS = {}
for c in (34522, 34527, 40754):
    CHUNKS[c] = open(f"/tmp/p22_str_{c}.bin", "rb").read()

def name_at(n_strx):
    foff = STROFF + n_strx
    c = foff // 65536
    o = foff % 65536
    if c not in CHUNKS:
        return f"<chunk {c} not decoded>"
    buf = CHUNKS[c]
    end = buf.find(b"\x00", o)
    if end < 0:
        return f"<unterminated in chunk {c}@{o:#x}>"
    return buf[o:end].decode("utf-8", "replace")

sym_data = open(SYM_CHUNK, "rb").read()
syms = []
for i in range(NSYMS):
    n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", sym_data, SYM_OFF + i * 16)
    syms.append((n_value, n_type, n_sect, n_strx))
sect = [(v, t, s, x) for (v, t, s, x) in syms if (t & 0x0E) == 0x0E]
below = sorted([s for s in sect if s[0] <= PC])
above = sorted([s for s in sect if s[0] > PC])
print(f"--- nearest N_SECT symbols at/below PC {PC:#x} (slid 0x19B87C9EC) ---")
for v, t, s, x in below[-6:]:
    print(f"  {v:#x} (+{PC - v:#x}) sect={s} type={t:#x} n_strx={x} name={name_at(x)!r}")
print(f"--- next N_SECT symbols above PC ---")
for v, t, s, x in above[:4]:
    print(f"  {v:#x} (+{v - PC:#x}) sect={s} type={t:#x} n_strx={x} name={name_at(x)!r}")
print(f"--- LR (unslid 0x180307acc) nearest below ---")
LR = 0x180307ACC
bl = sorted([s for s in sect if s[0] <= LR])
for v, t, s, x in bl[-3:]:
    print(f"  {v:#x} (+{LR - v:#x}) sect={s} type={t:#x} name={name_at(x)!r}")
