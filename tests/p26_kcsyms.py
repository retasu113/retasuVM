#!/usr/bin/env python3
"""Phase 26: search kc_syms for pthread-kext / bsdthread symbols (to locate
the kernel code that sets a new thread's initial PC/SP), and list symbols
near any match. Run on the PC. Usage: p26_kcsyms.py
"""
import pickle
import sys

syms, secs = pickle.load(open("/home/retasu/retasuvm/tests/logs/kc_syms.pkl", "rb"))
print(f"total syms: {len(syms)}")
keys = ("pthread", "bsdthread", "threadstart", "wqthread", "thread_set_state")
for k in keys:
    hits = sorted([(a, n) for a, n in syms if k in n.lower()])
    print(f"\n--- {k}: {len(hits)} ---")
    for a, n in hits[:30]:
        print(f"  {a:#x} {n}")
