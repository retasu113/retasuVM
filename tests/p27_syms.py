#!/usr/bin/env python3
"""Phase 27: exact symbol lookup in kc_syms.pkl (list of (addr, name))."""
import pickle, sys

syms = pickle.load(open('/home/hatch/workspace/retasuvm/tests/logs/kc_syms.pkl', 'rb'))
# tuple: (symbols_list, segments_list); symbols are (addr, name) tuples
syms = syms[0]
print(f"total {len(syms)}")
by_name = {}
for addr, name in syms:
    by_name.setdefault(name, []).append(addr)

for q in sys.argv[1:]:
    hits = [(n, a) for n, a in by_name.items() if q in n]
    print(f"== {q}: {len(hits)} hits")
    for n, addrs in sorted(hits)[:20]:
        for a in addrs:
            print(f"   {n} = 0x{a:x}")
