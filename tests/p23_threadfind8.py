#!/usr/bin/env python3
"""Phase 23: kc_syms reverse lookup. kc_syms.pkl is a LIST OF LISTS of
(addr, name) tuples (UNSLID addresses; runtime slide 0x182B4000).

Usage: p23_threadfind8.py
"""
import pickle

SLIDE = 0x182B4000
TARGETS_SLID = [0xFFFFFE0024A3A770, 0xFFFFFE00249D4000]
NAMES = ['_threads', 'threads', '_allproc', 'allproc', '_kernel_task',
         'kernel_task', '_kernel_pmap', 'kernel_pmap', '_tasks', 'tasks',
         '_gNumConfigThreads', 'gNumConfigThreads', '_thread_list',
         '_processor_list', '_task_list']


def main():
    raw = pickle.load(open('kc_syms.pkl', 'rb'))
    print(f'kc_syms: outer len={len(raw)}; outer[0] type={type(raw[0]).__name__} '
          f'len={len(raw[0]) if hasattr(raw[0], "__len__") else "?"}')
    # flatten: outer list of inner lists of (addr, name)
    items = []
    for grp in raw:
        if isinstance(grp, (list, tuple)):
            for it in grp:
                if isinstance(it, (list, tuple)) and len(it) == 2:
                    items.append((it[0], it[1]))
                elif isinstance(it, (list, tuple)) and len(it) == 3:
                    items.append((it[0], it[2]))
    items.sort()
    print(f'flattened {len(items)} (addr, name) symbols')
    print('\n--- symbol search ---')
    byname = {}
    for a, n in items:
        byname.setdefault(n, []).append(a)
    for name in NAMES:
        hits = byname.get(name, [])
        for a in hits:
            print(f'  {name}: unslid {a:#x}  slid {a + SLIDE:#x}')
        if not hits:
            print(f'  {name}: NOT FOUND')
    print('\n--- reverse lookup (table VA) ---')
    for t in TARGETS_SLID:
        u = t - SLIDE
        below = None
        for a, n in items:
            if a <= u:
                below = (a, n)
            else:
                break
        print(f'  slid {t:#x} (unslid {u:#x}): nearest-below '
              f'{below[1]} at {below[0]:#x} (delta {u - below[0]:#x})')


if __name__ == '__main__':
    main()
