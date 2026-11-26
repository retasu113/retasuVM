#!/usr/bin/env python3
"""Enlarge libirecovery's recovery-mode USB packet size for the emulated link.

Upstream sends recovery components and the streamed ramdisk in 0x8000-byte
bulk transfers. On our socket-bridged vusb link every transfer costs a guest
round trip dominated by fixed per-transfer work in the guest's USB stack, so
32 KiB packets cap throughput at ~1 MB/min. The guest's bdif descriptor chain
has ~1 MiB of room, so 0x40000-byte packets are safe (verified by the fit log
and by a live restore run). DFU-mode packet size (0x800) is dictated by the
ROM's DFU descriptor and is NOT touched.

Usage: apply_libirecovery_patch.py <path-to-libirecovery.c>
The file is patched in place; anchors are exact strings and asserted.
"""
import sys

path = sys.argv[1]
src = open(path).read()

# 1. Ramdisk streaming buffer in irecv_send_recovery_stream: 0x8000 -> 0x40000.
#    Made static so the larger buffer does not sit on a worker thread's stack.
old1 = "\tunsigned char packet[0x8000];\n"
new1 = "\tstatic unsigned char packet[0x40000]; /* retasuVM: enlarged stream packet (see header) */\n"
assert src.count(old1) == 1, f"anchor 1 count = {src.count(old1)}"
src = src.replace(old1, new1)

# 2. Component send packet size in irecv_send_buffer (recovery mode only).
old2 = "\tint packet_size = recovery_mode ? 0x8000 : 0x800;\n"
new2 = "\tint packet_size = recovery_mode ? 0x40000 : 0x800; /* retasuVM: enlarged recovery packet (see header) */\n"
assert src.count(old2) == 1, f"anchor 2 count = {src.count(old2)}"
src = src.replace(old2, new2)

open(path, "w").write(src)
print("libirecovery packet-size patch applied")
