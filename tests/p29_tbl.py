#!/usr/bin/env python3
"""Phase 29: dump the full _pthread_internal_functions table from the
kernelcache and resolve workq_setup_thread / workq_create_threadstack.
Offsets per bsd/sys/pthread_shims.h struct pthread_functions_s:
  version@0x00, then pointers from 0x08, each +8.
  bsdthread_create idx9 @+0x50, workq_handle_stack_events idx38 @+0x138,
  workq_create_threadstack idx39 @+0x140, workq_destroy_threadstack idx40 @+0x148,
  workq_setup_thread idx41 @+0x150, workq_markfree_threadstack idx42 @+0x158.
"""
import struct, pickle

KC = '/home/hatch/workspace/retasuvm/ipsw15/kernelcache.macho'
data = open(KC, 'rb').read()
magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from('<8I', data, 0)
assert magic == 0xfeedfacf
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

def u64(va):
    o, seg = va_to_off(va)
    assert o is not None, f"VA {va:#x} not mapped"
    return struct.unpack_from('<Q', data, o)[0]

syms, secs = pickle.load(open('/home/hatch/workspace/retasuvm/tests/logs/kc_syms.pkl', 'rb'))
by_name = {n: a for a, n in syms}
tbl = by_name['_pthread_internal_functions']
print(f"table _pthread_internal_functions @ {tbl:#x}")

fields = [
    (0x50, 'bsdthread_create'), (0x58, 'bsdthread_register'),
    (0x60, 'bsdthread_terminate'), (0x68, 'thread_selfid'),
    (0xE0, 'bsdthread_register2'),
    (0x120, 'pthread_find_owner'), (0x128, 'pthread_get_thread_kwq'),
    (0x138, 'workq_handle_stack_events'),
    (0x140, 'workq_create_threadstack'),
    (0x148, 'workq_destroy_threadstack'),
    (0x150, 'workq_setup_thread'),
    (0x158, 'workq_markfree_threadstack'),
]
for fo, nm in fields:
    v = u64(tbl + fo)
    o, seg = va_to_off(v) if v else (None, None)
    print(f"  +{fo:#05x} {nm:28s} = {v:#x}  fileoff={o if o is None else hex(o)} seg={seg}")
print(f"  version = {u64(tbl) & 0xffffffff:#x}")
