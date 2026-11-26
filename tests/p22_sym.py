#!/usr/bin/env python3
"""Phase 22: symbolize unslid PC 0x1803089EC in libsystem_c.
symtab: chunk 32329 @ file 0x7e4952c0, 2513 entries.
strtab: chunk 34520 @ file 0x86d876e0 (+34521 for overflow)."""
import struct

PC = 0x1803089EC
SYM_CHUNK = "/tmp/p22_sym_32329.bin"
SYM_OFF_IN_CHUNK = 0x7e4952c0 - 32329 * 65536  # 0x52c0
NSYMS = 2513
STR_CHUNKS = ["/tmp/p22_sym_34520.bin", "/tmp/p22_sym_34521.bin"]
STR_OFF_IN_CHUNK0 = 0x86d876e0 - 34520 * 65536  # 0x76e0

sym_data = open(SYM_CHUNK, "rb").read()
str_data = b"".join(open(p, "rb").read() for p in STR_CHUNKS)
# strtab starts at STR_OFF_IN_CHUNK0 within str_data
strtab = str_data[STR_OFF_IN_CHUNK0:]

def name_at(n_strx):
    if n_strx == 0 or n_strx >= len(strtab):
        return None
    end = strtab.find(b"\x00", n_strx)
    if end < 0:
        return None
    return strtab[n_strx:end].decode("utf-8", "replace")

syms = []
for i in range(NSYMS):
    off = SYM_OFF_IN_CHUNK + i * 16
    n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", sym_data, off)
    syms.append((n_value, n_type, n_sect, n_strx))

sect = [(v, t, s, x) for (v, t, s, x) in syms if (t & 0x0E) == 0x0E]
print(f"total syms {len(syms)}, N_SECT syms {len(sect)}")
below = [s for s in sect if s[0] <= PC]
below.sort()
above = [s for s in sect if s[0] > PC]
above.sort()
print(f"--- nearest N_SECT symbols at/below PC {PC:#x} ---")
for v, t, s, x in below[-5:]:
    print(f"  {v:#x} (+{PC - v:#x}) sect={s} type={t:#x} name={name_at(x)!r}")
print(f"--- next N_SECT symbols above PC ---")
for v, t, s, x in above[:3]:
    print(f"  {v:#x} (+{v - PC:#x}) sect={s} type={t:#x} name={name_at(x)!r}")
# Also: any symbols (any type) very close below PC
print(f"--- all-type symbols within 0x2000 below PC ---")
for v, t, s, x in sorted([s for s in syms if PC - 0x2000 <= s[0] <= PC]):
    print(f"  {v:#x} (+{PC - v:#x}) type={t:#x} sect={s} name={name_at(x)!r}")
