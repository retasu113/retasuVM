#!/usr/bin/env python3
"""Phase 29: nearest-symbol lookup for raw VAs in kc_syms.pkl."""
import pickle, sys, bisect

syms, secs = pickle.load(open('/home/hatch/workspace/retasuvm/tests/logs/kc_syms.pkl', 'rb'))
addrs = sorted(a for a, n in syms)
by_addr = {}
for a, n in syms:
    by_addr.setdefault(a, n)

for q in sys.argv[1:]:
    va = int(q, 0)
    i = bisect.bisect_right(addrs, va) - 1
    if i >= 0:
        a = addrs[i]
        print(f"{va:#x}: {by_addr[a]} + {va - a:#x}  (sym {a:#x})")
    else:
        print(f"{va:#x}: <before first sym>")
