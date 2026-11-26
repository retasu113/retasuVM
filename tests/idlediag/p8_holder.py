"""Phase 8: find the moduleResourceLock HOLDER in a dump.

For every censused thread, scan its 16 KiB kernel stack for marker
values that a thread inside the APFS module-resources path would hold:
  - return address into _external_module_resources (esp. the ret after
    the waitForMatchingService BL: slid 0xFFFFFE0022285A4C)
  - return addresses into _internal_module_resources / AppleAPFSContainer
    ::start / AppleAPFSContainerScheme::start
  - the APFS __DATA page value (saved x21 in external_module_resources)
Also dumps the APFS module-resources statics (mutex ptr, flags, refcount)
and the mutex object's two words.
Usage: python3 p8_holder.py <dump>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, census_threads, thread_info, make_sym, SLIDE  # noqa: E402

ctx = Ctx(sys.argv[1])
Q = ctx.Qva
bracket = make_sym()

PAGE = 0xFFFFFE000A999000 + SLIDE          # APFS __DATA page (slid)
MUTEX_PTR_VA = PAGE + 0xB88                # moduleResourceLock static
EXT_FLAG = PAGE + 0xB98                    # external resources done (byte)
INT_FLAG = PAGE + 0xB9C                    # internal init done (byte)
REFCOUNT = PAGE + 0xBA0                    # internal refcount (word)
ROOTHASH_FLAG = PAGE + 0xBD8               # roothash imported (byte)
STATIC_MTX = PAGE + 0xD68                  # embedded lck_mtx (init path)

EXT_FN = (0xFFFFFE0009FD19FC + SLIDE, 0xFFFFFE0009FD1B08 + SLIDE)
INT_FN = (0xFFFFFE0009FD27B8 + SLIDE, 0xFFFFFE0009FD2C54 + SLIDE)
CONT_START = (0xFFFFFE0009FD18DC + SLIDE, 0xFFFFFE0009FD19FC + SLIDE)
SCHEME_START = (0xFFFFFE0009FDD3C0 + SLIDE, 0xFFFFFE0009FDE600 + SLIDE)
WAIT_RET = 0xFFFFFE0009FD1A4C + SLIDE      # ret after waitForMatchingService BL


def in_rng(v, r):
    return r[0] <= v < r[1]


mutex_ptr = Q(MUTEX_PTR_VA)
print(f'APFS statics (page {PAGE:#x}):')
print(f'  moduleResourceLock ptr @ {MUTEX_PTR_VA:#x} = {mutex_ptr:#x}')
if mutex_ptr:
    print(f'    mutex[+0] = {Q(mutex_ptr):#018x}')
    print(f'    mutex[+8] = {Q(mutex_ptr + 8):#018x}')
print(f'  external-done flag @ {EXT_FLAG:#x} = {ctx.read_va(EXT_FLAG, 1)[0]}')
print(f'  internal-init flag @ {INT_FLAG:#x} = {ctx.read_va(INT_FLAG, 1)[0]}')
print(f'  internal refcount  @ {REFCOUNT:#x} = {struct.unpack("<I", ctx.read_va(REFCOUNT, 4))[0]}')
print(f'  roothash flag      @ {ROOTHASH_FLAG:#x} = {ctx.read_va(ROOTHASH_FLAG, 1)[0]}')
print(f'  static mtx @ {STATIC_MTX:#x}: [+0]={Q(STATIC_MTX):#018x} [+8]={Q(STATIC_MTX + 8):#018x}')

threads = census_threads(ctx)
print(f'\ncensus: {len(threads)} threads; scanning stacks for holder markers...')
for tva in sorted(threads):
    ti = thread_info(ctx, tva)
    if ti is None or not ti['stack_va']:
        continue
    raw = ctx.read_va(ti['stack_va'], 0x4000)
    hits = []
    for off in range(0, 0x4000, 8):
        v = struct.unpack_from('<Q', raw, off)[0]
        if v == WAIT_RET:
            hits.append(f'WAIT_RET @stack+{off:#x}')
        elif in_rng(v, EXT_FN):
            hits.append(f'EXT_FN ret {v:#x} ({bracket(v)}) @stack+{off:#x}')
        elif in_rng(v, INT_FN):
            hits.append(f'INT_FN ret {v:#x} ({bracket(v)}) @stack+{off:#x}')
        elif in_rng(v, CONT_START):
            hits.append(f'CONT_START ret {v:#x} ({bracket(v)}) @stack+{off:#x}')
        elif v == PAGE:
            hits.append(f'APFS_PAGE @stack+{off:#x}')
    if hits:
        print(f'\nthread {tva:#x} id={ti["id"]:#x} name={ti["name"]!r} '
              f'wait={ti["wait_event"]:#x}')
        for h in hits:
            print(f'    {h}')
