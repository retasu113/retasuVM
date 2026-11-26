#!/usr/bin/env python3
"""Phase 28c: for each of the 3 inlined check_monotonic_time copies, find the
containing function boundaries (pacibsp prologue .. retab) and resolve key
call targets to identify which XNU call site each copy belongs to.
"""
import struct, sys, pickle, bisect
sys.path.insert(0, '/home/hatch/workspace/retasuvm/tests/pytools')
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

KC = '/home/hatch/workspace/retasuvm/ipsw15/kernelcache.macho'
data = open(KC, 'rb').read()
magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from('<8I', data, 0)
segs = []
off = 32
for i in range(ncmds):
    cmd, cmdsize = struct.unpack_from('<2I', data, off)
    if cmd == 0x19:
        name = data[off + 8:off + 24].split(b'\x00')[0].decode()
        vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects, segflags = struct.unpack_from('<8Q', data, off + 24)
        segs.append((name, vmaddr, vmsize, fileoff, filesize))
    off += cmdsize

def va_to_off(va):
    for name, vmaddr, vmsize, fileoff, filesize in segs:
        if vmaddr <= va < vmaddr + vmsize:
            return fileoff + (va - vmaddr), name
    return None, None

def word(va):
    o, _ = va_to_off(va)
    return struct.unpack_from('<I', data, o)[0]

syms, secs = pickle.load(open('/home/hatch/workspace/retasuvm/tests/logs/kc_syms.pkl', 'rb'))
addrs = [a for a, _ in syms]
by_name = {n: a for a, n in syms}
def resolve(va):
    i = bisect.bisect_right(addrs, va) - 1
    a, n = syms[i]
    return f"{n}+0x{va-a:x}" if va - a < 0x10000 else f"{n}+0x{va-a:x} (FAR)"
def resolve_exact(va):
    i = bisect.bisect_right(addrs, va) - 1
    a, n = syms[i]
    return n if a == va else None

for nm in ['_mach_approximate_time', '_recount_snapshot', '_commpage_update_mach_approximate_time',
           '_sched_update_pset_avg_execution_time', '_panic', '_timer_start', '_thread_go',
           '_recount_switch_thread', '_recount_log_switch_thread']:
    print(nm, hex(by_name[nm]) if nm in by_name else 'NOT IN SYMS')

md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)

def find_fn_bounds(va):
    # scan backwards instruction-aligned for 'pacibsp' (0xd503237f) that starts
    # a function: the word before it should be ret/retab/b or padding.
    a = va & ~3
    start = None
    for p in range(a, a - 0x8000, -4):
        if word(p) == 0xd503237f:  # pacibsp
            start = p
            break
    # scan forwards for retab (0xd65f0fff) at same level (first one after va)
    end = None
    for p in range(a, a + 0x8000, 4):
        if word(p) == 0xd65f0fff:
            end = p
            break
    return start, end

REFS = [0xfffffe0007df9830, 0xfffffe0007e0236c, 0xfffffe0007e060e4]
for r in REFS:
    s, e = find_fn_bounds(r)
    print(f"\n=== ref {r:#x}: fn start {s:#x} ({resolve(s)}), first retab after ref {e:#x}")
    # dump all bl targets within [s, e] resolved
    if s and e:
        o, _ = va_to_off(s)
        calls = {}
        for insn in md.disasm(data[o:o + (e - s) + 4], s):
            if insn.mnemonic in ('bl', 'b') and insn.op_str.startswith('#'):
                tgt = int(insn.op_str[1:], 16)
                nm = resolve_exact(tgt)
                if nm:
                    calls.setdefault(nm, []).append(insn.address)
        for nm, sites in sorted(calls.items()):
            print(f"    calls {nm} x{len(sites)}")
