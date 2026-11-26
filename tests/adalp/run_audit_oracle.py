#!/usr/bin/env python3
# Run the neighbour-audit oracle: batch per (hi, opc); if a batch dies
# (SIGILL on an unallocated encoding), fall back to per-case runs so
# every case is classified precisely. Writes audit_expected.txt with
# "name lo hi" or "name INVALID" per case.
import glob, os, struct, subprocess, sys

CLANG = os.path.expanduser(
    "~/workspace/swift-toolchain/swift-5.10.1-RELEASE-ubuntu24.04/usr/bin/clang-15")
os.chdir(os.path.dirname(os.path.abspath(__file__)) + "/audit_oracle")

def build_and_run(src):
    elf = src[:-2] + ".elf"
    r = subprocess.run([CLANG, "-target", "aarch64-linux-gnu", "-nostdlib",
                        "-static", "-fuse-ld=lld", "-o", elf, src],
                       capture_output=True)
    if r.returncode != 0:
        return None
    r = subprocess.run(["qemu-aarch64", elf], capture_output=True)
    if r.returncode != 0:
        return None
    return r.stdout.replace(b"\x00", b"").decode()

def parse(out, names):
    if out is None or len(out) != len(names) * 32:
        return None
    res = {}
    for i, name in enumerate(names):
        b = bytes.fromhex(out[i * 32:(i + 1) * 32])
        lo, hi = struct.unpack("<QQ", b)
        res[name] = (lo, hi)
    return res

results = {}
for txt in sorted(glob.glob("batch_*.txt")):
    names = [l.strip() for l in open(txt) if l.strip()]
    src = txt[:-4] + ".s"
    got = parse(build_and_run(src), names)
    if got is None:
        # batch died — classify case by case
        for name in names:
            one = parse(build_and_run(f"one_{name}.s"), [name])
            results[name] = one[name] if one else None
    else:
        results.update(got)

valid = sum(1 for v in results.values() if v is not None)
with open("../audit_expected.txt", "w") as f:
    for name in sorted(results):
        v = results[name]
        if v is None:
            f.write(f"{name} INVALID\n")
        else:
            f.write(f"{name} 0x{v[0]:016X} 0x{v[1]:016X}\n")
print(f"audit oracle: {valid} valid, {len(results) - valid} invalid of {len(results)}")
