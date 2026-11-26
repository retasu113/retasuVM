#!/usr/bin/env python3
"""Phase 27: kernelcache Mach-O segment map (VA -> file offset) + read the
_pthread_internal_functions table. Local run against kernelcache.macho.
Usage: p27_kc.py
"""
import struct

KC = '/home/hatch/workspace/retasuvm/ipsw15/kernelcache.macho'
data = open(KC, 'rb').read()
print(f"kernelcache {len(data)} B")

magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from('<8I', data, 0)
print(f"magic={magic:#x} ncmds={ncmds}")
assert magic == 0xfeedfacf, "not arm64 mach-o"

segs = []
off = 32
for i in range(ncmds):
    cmd, cmdsize = struct.unpack_from('<2I', data, off)
    if cmd == 0x19:  # LC_SEGMENT_64
        name = data[off + 8:off + 24].split(b'\x00')[0].decode()
        vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects, segflags = struct.unpack_from('<8Q', data, off + 24)
        segs.append((name, vmaddr, vmsize, fileoff, filesize))
        print(f"SEG {name:16s} vmaddr={vmaddr:#x} vmsize={vmsize:#x} fileoff={fileoff:#x} filesize={filesize:#x}")
    off += cmdsize

def va_to_off(va):
    for name, vmaddr, vmsize, fileoff, filesize in segs:
        if vmaddr <= va < vmaddr + vmsize:
            return fileoff + (va - vmaddr), name
    return None, None

def u64(va):
    o, seg = va_to_off(va)
    assert o is not None, f"VA {va:#x} not in any segment"
    return struct.unpack_from('<Q', data, o)[0]

# sanity: _bzero and _Switch_context from kc_syms (unslid VAs)
import pickle
syms, secs = pickle.load(open('/home/hatch/workspace/retasuvm/tests/logs/kc_syms.pkl', 'rb'))
by_name = {n: a for a, n in syms}
for nm in ['_bzero', '_Switch_context', '_pthread_internal_functions', '__bsdthread_create']:
    a = by_name.get(nm)
    if a is None:
        print(f"{nm}: NOT IN SYMS")
        continue
    o, seg = va_to_off(a)
    print(f"{nm} = {a:#x} -> fileoff {o:#x} ({seg}) first8={data[o:o+8].hex()}")

# _pthread_internal_functions table: version@+0x00, pthread_init@+0x08,
# bsdthread_create@+0x50 (per bsd/sys/pthread_shims.h struct pthread_functions_s)
tbl = by_name['_pthread_internal_functions']
print(f"\n_pthread_internal_functions table at {tbl:#x}:")
for field_off, fname in [(0x00, 'version(int)'), (0x08, 'pthread_init'), (0x10, 'unused_fill_procworkqueue'),
                          (0x18, 'unused1'), (0x20, 'unused2'), (0x28, 'unused_wq_exit'),
                          (0x30, 'unused_wq_mark_exiting'), (0x38, 'unused_wq_thread_yielded'),
                          (0x40, 'pth_proc_hashinit'), (0x48, 'pth_proc_hashdelete'),
                          (0x50, 'bsdthread_create'), (0x58, 'bsdthread_register'),
                          (0x60, 'bsdthread_terminate'), (0x68, 'thread_selfid')]:
    v = u64(tbl + field_off)
    print(f"  +{field_off:#04x} {fname:28s} = {v:#x}")
