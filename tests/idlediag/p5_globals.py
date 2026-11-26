"""Phase 5 globals: recover the addresses of IOService.cpp's static job
globals (gJobs, gJobsSemaphore, gJobsLock, gOutstandingJobs,
gNumConfigThreads, gHighNumConfigThreads, gMaxConfigThreads,
gNumWaitingThreads, gIOResources) by decoding ADRP+ADD/LDR pairs in
pingConfig / waitMatchIdle / startJob / doServiceMatch / startMatching
inside kernelcache.macho, then read their values from a DRAM dump.

Usage: python3 p5_globals.py <kernelcache.macho> <dump>
"""
import json
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, link_of, load_syms, SLIDE  # noqa: E402

KC = sys.argv[1]
DUMP = sys.argv[2]

kc = open(KC, 'rb').read()
segs = load_syms()['segs']


def file_off(va):
    for s in segs:
        if s['vmaddr'] <= va < s['vmaddr'] + s['filesize']:
            return s['fileoff'] + (va - s['vmaddr'])
    return None


syms = sorted(load_syms()['syms'])
saddrs = [s[0] for s in syms]


def func_range(name):
    a = link_of(name)
    i = saddrs.index(a)
    end = syms[i + 1][0] if i + 1 < len(syms) else a + 0x2000
    return a, end


def decode_refs(name):
    """All absolute addresses materialised by ADRP+ADD (address-of) or
    ADRP+LDR/STR (load/store through a pointer global) in the function."""
    start, end = func_range(name)
    off = file_off(start)
    words = struct.unpack_from(f'<{(end - start) // 4}I', kc, off)
    refs = {}   # addr -> list of (kind, pc)
    adrp = {}   # reg -> page addr
    for i, w in enumerate(words):
        pc = start + i * 4
        if w & 0x9F000000 == 0x90000000:  # ADRP
            rd = w & 0x1F
            immlo = (w >> 29) & 0x3
            immhi = (w >> 5) & 0x7FFFF
            imm = (immhi << 2) | immlo
            if imm & (1 << 20):
                imm -= (1 << 21)
            adrp[rd] = (pc & ~0xFFF) + (imm << 12)
            continue
        if w & 0xFF800000 == 0x91000000:  # ADD imm64
            rn = (w >> 5) & 0x1F
            rd = w & 0x1F
            if rn in adrp:
                imm = (w >> 10) & 0xFFF
                if (w >> 22) & 0x1:
                    imm <<= 12
                refs.setdefault(adrp[rn] + imm, []).append(('add', pc))
                adrp[rd] = adrp[rn] + imm
            continue
        if w & 0xFFC00000 == 0xF9400000:  # LDR imm64
            rn = (w >> 5) & 0x1F
            if rn in adrp:
                imm = ((w >> 10) & 0xFFF) << 3
                refs.setdefault(adrp[rn] + imm, []).append(('ldr', pc))
            continue
        if w & 0xFFC00000 == 0xF9000000:  # STR imm64
            rn = (w >> 5) & 0x1F
            if rn in adrp:
                imm = ((w >> 10) & 0xFFF) << 3
                refs.setdefault(adrp[rn] + imm, []).append(('str', pc))
            continue
        if w & 0xFFC00000 == 0xB9400000:  # LDR imm32
            rn = (w >> 5) & 0x1F
            if rn in adrp:
                imm = ((w >> 10) & 0xFFF) << 2
                refs.setdefault(adrp[rn] + imm, []).append(('ldr32', pc))
            continue
        if w & 0xFFC00000 == 0xB9000000:  # STR imm32
            rn = (w >> 5) & 0x1F
            if rn in adrp:
                imm = ((w >> 10) & 0xFFF) << 2
                refs.setdefault(adrp[rn] + imm, []).append(('str32', pc))
            continue
    return refs


FUNCS = ['__ZN13_IOServiceJob10pingConfigEPS_',
         '__ZN9IOService13waitMatchIdleEj',
         '__ZN13_IOServiceJob8startJobEP9IOServiceij',
         '__ZN9IOService14doServiceMatchEj',
         '__ZN9IOService13startMatchingEj']

all_refs = {}
for fn in FUNCS:
    r = decode_refs(fn)
    print(f'== {fn}: {len(r)} refs')
    for a, uses in sorted(r.items()):
        kinds = ','.join(sorted({k for k, _ in uses}))
        all_refs.setdefault(a, []).append((fn, kinds))
        print(f'   {a:#x} [{kinds}]')

ctx = Ctx(DUMP)
print('\n--- values in dump (statics cluster) ---')
for a, users in sorted(all_refs.items()):
    rt = a + SLIDE
    # statics live in the static physmap range
    try:
        v64 = ctx.d.u64_phys(rt)
        v32 = ctx.d.u32_pa(rt - 0xFFFFFDFFAC000000)
    except Exception as e:
        print(f'  {a:#x} (rt {rt:#x}): unreadable {e}')
        continue
    who = '; '.join(f'{f} [{k}]' for f, k in users)
    print(f'  link {a:#x} rt {rt:#x}: u64={v64:#018x} u32={v32}   <- {who}')
