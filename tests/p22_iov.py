#!/usr/bin/env python3
"""Phase 22: find the iovec entry (ptr=0x16d0cf4a0, len=0x800000000) in the
p23 dump, and the code page containing the spin-loop bytes.
Also read the surrounding iovec entries to see the full (ptr,len) list."""
import struct

D = "/home/retasu/retasuvm/inst/imagetest/home_p23/dram_fpend_cycle1.bin"
data = open(D, "rb").read()
print(f"dump size {len(data)}")

# iovec entry: [ptr=0x16d0cf4a0][len=0x800000000] (16 bytes, LE)
pat = struct.pack("<QQ", 0x16d0cf4a0, 0x800000000)
hits = []
pos = 0
while True:
    i = data.find(pat, pos)
    if i < 0:
        break
    hits.append(i)
    pos = i + 1
print(f"iovec pattern hits: {len(hits)}")
for h in hits:
    pa = h + 0x70000000
    print(f"  file off {h:#x} -> PA {pa:#x}")
    # dump the surrounding 5 entries (16 B each) as (ptr,len)
    for k in range(-2, 4):
        o = h + k * 16
        if 0 <= o < len(data) - 16:
            ptr, ln = struct.unpack_from("<QQ", data, o)
            print(f"    entry[{k:+d}] @file {o:#x}: ptr={ptr:#x} len={ln:#x} ({ln})")

# code bytes at the PC: file offset 0x3089ec in the cache.
# Take 32 bytes from the decoded chunk 48 at offset 0x89ec as the needle.
# (We read it from the chunk file directly.)
chunk48 = open("/tmp/p22_pc_48.bin", "rb").read()
needle = chunk48[0x89ec:0x89ec + 32]
print(f"\ncode needle (32 B at cache file off 0x3089ec): {needle.hex()}")
hits2 = []
pos = 0
while True:
    i = data.find(needle, pos)
    if i < 0:
        break
    hits2.append(i)
    pos = i + 1
print(f"code-page needle hits: {len(hits2)}")
for h in hits2:
    print(f"  file off {h:#x} -> PA {h + 0x70000000:#x} (page base PA {(h + 0x70000000) & ~0x3FFF:#x})")
