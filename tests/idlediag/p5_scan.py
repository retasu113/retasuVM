#!/usr/bin/env python3
"""Phase-5 scan: for every censused thread in a dump, report which of its
kernel-stack qwords land in key IOKit function regions (doServiceMatch,
startMatching, semaphore_wait area) -- finds any thread stuck INSIDE
matching (the upstream blocker candidate).

argv: dump census_json
"""
import json
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, make_sym

ctx = Ctx(sys.argv[1])
sym = make_sym()
data = open(sys.argv[1], 'rb').read()
DRAM = 0x70000000
census = json.load(open(sys.argv[2]))

# regions of interest: (label, runtime lo, hi) -- anchors from the sym
# table via known runtime addresses observed in stacks/globals.
REGIONS = [
    ('pingConfig region', 0xFFFFFE00207C4F00, 0xFFFFFE00207C6000),
    ('assert_wait region', 0xFFFFFE00200B8000, 0xFFFFFE00200BD000),
    ('doServiceMatch/startMatching area', 0xFFFFFE00207BF000,
     0xFFFFFE00207C4F00),
]

threads = census['threads'] if 'threads' in census else census
if isinstance(threads, dict):
    threads = list(threads.values())
for t in threads:
    stack = t.get('stack_va') or t.get('stackVA') or t.get('stack')
    if not stack:
        continue
    pa = ctx.pa_of(stack)
    if pa is None:
        continue
    raw = data[pa - DRAM: pa - DRAM + 0x4000]
    hits = {}
    for off in range(0, len(raw) - 8, 8):
        v = struct.unpack_from('<Q', raw, off)[0]
        for label, lo, hi in REGIONS:
            if lo <= v < hi:
                hits.setdefault(label, []).append((off, v))
    name = t.get('name')
    tid = t.get('id')
    if hits:
        print(f"thread id={tid} name={name} stack={stack:#x} "
              f"wait={t.get('wait_event') or t.get('wait')}")
        for label, lst in hits.items():
            ex = ', '.join(f'+{o:#x}:{sym(v)}' for o, v in lst[:4])
            print(f'    {label}: {len(lst)} hits [{ex}]')
