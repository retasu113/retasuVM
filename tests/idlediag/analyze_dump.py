#!/usr/bin/env python3
"""Analyze a guest DRAM dump from the idlediag boot.

Usage: analyze_dump.py <dump.bin> [dump2.bin]
DRAM base PA = 0x70000000; file offset i <-> PA 0x70000000+i.

Finds kernel log (msgbuf) content and late-boot markers, printing the
last kernel messages in address order, plus marker hit contexts.
"""
import re
import sys

MARKERS = [
    b"Darwin Kernel Version",
    b"BSD root",
    b"launchd",
    b"Still waiting",
    b"Waiting for",
    b"waiting for",
    b"AppleParavirtDisplay",
    b"AppleParavirtGPU",
    b"IOConsole",
    b"timeout",
    b"Timed out",
    b"failed",
    b"not found",
    b"root device",
    b"mount",
    b"hibernate",
    b"Power",
    b"AES",
    b"GPIO",
    b"SMC",
    b"display",
    b"Display",
    b"vsync",
    b"framebuffer",
    b"IOFB",
    b"init ",
    b"exec",
]


def printable_runs(data, minlen=6):
    """Yield (offset, bytes) for printable ASCII runs."""
    pat = re.compile(rb"[\x20-\x7e\n\r\t]{%d,}" % minlen)
    for m in pat.finditer(data):
        yield m.start(), m.group()


def main():
    data = open(sys.argv[1], "rb").read()
    print(f"dump size {len(data)} bytes")

    # 1. Locate the Darwin banner: the msgbuf holds the boot log from the start.
    hits = [m.start() for m in re.finditer(re.escape(b"Darwin Kernel Version"), data)]
    print(f"'Darwin Kernel Version' hits: {[hex(h) for h in hits]}")

    # 2. Marker census with last-hit context.
    for mk in MARKERS:
        hs = [m.start() for m in re.finditer(re.escape(mk), data)]
        if hs:
            last = hs[-1]
            ctx = data[max(0, last - 60):last + 120]
            ctx = ctx.decode("ascii", "replace").replace("\n", "\\n")
            print(f"marker {mk!r}: {len(hs)} hits, last @0x{last:x}: ...{ctx}...")

    # 3. If a banner was found, print the printable text of the 256 KiB
    #    region starting at the LAST banner (msgbuf is a ring; the tail of
    #    the log is what matters — print the final 120 lines of text found
    #    in the 512 KiB after the banner start).
    if hits:
        start = hits[-1]
        region = data[start:start + 512 * 1024]
        lines = []
        for off, run in printable_runs(region, 4):
            for ln in run.split(b"\n"):
                ln = ln.strip()
                if len(ln) >= 4:
                    lines.append((start + off, ln.decode("ascii", "replace")))
        print(f"--- {len(lines)} text lines in msgbuf region; last 120: ---")
        for off, ln in lines[-120:]:
            print(f"  @0x{off:x}: {ln}")


if __name__ == "__main__":
    main()
