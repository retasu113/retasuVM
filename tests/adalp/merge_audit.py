#!/usr/bin/env python3
# Classify our engine's audit behaviour against the oracle:
#   oracle valid   + THROW        -> MISSING
#   oracle valid   + wrong value  -> MISROUTE
#   oracle valid   + right value  -> OK
#   oracle invalid + executed     -> EXEC-UNDEF
#   oracle invalid + THROW        -> CONSISTENT
import sys

oracle = {}
for l in open("audit_expected.txt"):
    p = l.split()
    oracle[p[0]] = None if p[1] == "INVALID" else (int(p[1], 16), int(p[2], 16))

engine = {}
for l in open(sys.argv[1] if len(sys.argv) > 1 else "audit_engine_prefix.txt"):
    p = l.split()
    if p[1] == "THROW":
        engine[p[0]] = None
    else:
        engine[p[0]] = (int(p[2], 16), int(p[3], 16))

cats = {"OK": [], "MISSING": [], "MISROUTE": [], "EXEC-UNDEF": [], "CONSISTENT": []}
for name, ov in sorted(oracle.items()):
    ev = engine.get(name, "ABSENT")
    if ov is not None:
        if ev is None:
            cats["MISSING"].append(name)
        elif ev == ov:
            cats["OK"].append(name)
        else:
            cats["MISROUTE"].append(name)
    else:
        cats["CONSISTENT" if ev is None else "EXEC-UNDEF"].append(name)
for k, v in cats.items():
    print(f"{k}: {len(v)}")
    for name in v:
        print(f"  {name}")
