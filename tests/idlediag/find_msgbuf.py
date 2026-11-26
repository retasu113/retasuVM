#!/usr/bin/env python3
"""Locate the real XNU msgbuf inside a guest DRAM dump.

The msgbuf's written region is continuous log text with essentially no
NUL bytes, unlike kernel rodata (NUL-separated format strings). So:
1. Find maximal NUL-free printable spans >= 1024 bytes; rank by length.
2. Probe for output-only strings (digits/values where rodata has %fmt)
   and print context for hits whose neighbourhood has low NUL density
   (i.e. real log text, not the string table).

Usage: find_msgbuf.py <dump.bin>
"""
import re
import sys

PROBES = [
    rb"vm_page_bootstrap: \d+ free pages",
    rb"BSD root: [A-Za-z0-9]+, major \d+, minor \d+",
    rb"Got boot device = \S+",
    rb"VM Swap Subsystem is ON",
    rb"Waiting for DSMOS",
    rb"DSMOS has arrived",
    rb"Previous shutdown cause: -?\d+",
    rb"rooting via boot-uuid",
    rb"boot-uuid: [0-9A-Fa-f-]{8,}",
    rb"hibernate image",
    rb"Sleep failure",
    rb"Still waiting for root device",
    rb"Waiting for root device",
    rb"from path: ",
    rb"IOConsoleUsers",
    rb"gIOScreenLockState",
    rb"AppleVirtIO",
    rb"virtio-blk",
    rb"Couldn't allocate",
    rb"failed to mount",
    rb"mount of root",
    rb"LoadExec",
    rb"exec of /sbin/launchd",
    rb"launchd\[1\]",
    rb"com\.apple\.launchd",
    rb"spaceman_metazone_init",
    rb"apfs_vfs_mount",
    rb"nx_mount",
    rb"Mounting local volumes",
    rb"fsevents",
    rb"kern\.bootargs",
    rb"Boot args: ",
    rb"Kernel boot args: ",
    rb" Darwin Kernel Version ",
    rb"Kernel version changed",
    rb"ml at interrupt context",
    rb"longjmp",
    rb"zone_init",
    rb"PE_consistent_debug",
    rb"calling mpo_policy_init",
    rb"sandbox: ",
    rb"AMFI: ",
    rb"CoreAnalytics",
    rb"AppleParavirtGPU::",
    rb"AppleParavirtDisplay::",
    rb"IOFB: ",
    rb"IG: ",
    rb"AIC: ",
    rb"cpu \d+ failed to start",
    rb"secondary CPU",
    rb"skywalk",
]


def nul_free_spans(data, minlen=1024):
    pat = re.compile(rb"[\x09\x0a\x0d\x20-\x7e]{%d,}" % minlen)
    return [(m.start(), len(m.group())) for m in pat.finditer(data)]


def main():
    data = open(sys.argv[1], "rb").read()
    print(f"dump size {len(data)}")

    spans = nul_free_spans(data)
    spans.sort(key=lambda t: -t[1])
    print(f"--- top NUL-free printable spans (>=1024 B): {len(spans)} total ---")
    for off, ln in spans[:20]:
        head = data[off:off + 90].decode("ascii", "replace").replace("\n", "\\n")
        print(f"  @0x{off:x} len={ln}: {head!r}")

    print("--- output probes (context shown when neighbourhood NUL density is low) ---")
    for probe in PROBES:
        for m in re.finditer(probe, data):
            s = m.start()
            nb = data[max(0, s - 256):s + 512]
            nul_density = nb.count(0) / max(1, len(nb))
            if nul_density < 0.02:
                ctx = data[max(0, s - 120):s + 200].decode("ascii", "replace")
                ctx = ctx.replace("\n", "\\n")
                print(f"  HIT @0x{s:x} {probe!r} (nul_dens={nul_density:.3f}): ...{ctx}...")
            else:
                print(f"  (rodata?) @0x{s:x} {probe!r} nul_dens={nul_density:.3f}")


if __name__ == "__main__":
    main()
