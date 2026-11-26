#!/bin/bash
# Root cause #24 regression corpus: LLB adler32 by-element multiply path.
#
#   drv.S    — the extracted Sequoia 15.6.1 LLB adler32 core (core.bin, LLB
#              file offset 0x24CC0 = VA 0x70090CC0; consts.bin at +0x170 =
#              VA 0x70090E30) run over 9 vectors, incl. the real Cirrus aux
#              NVRAM bank payload (bankdata.bin = bank1[0x20:0x80000] of
#              images/aux.img, bank header at aux offset 0xA00000).
#              Expected: expected.txt (bank must be 3D58137C).
#   micro2.S — the modulo-65521 reduction staged instruction by instruction
#              (umull/ushr/mov/mls by element) against consts.bin.
#   sweep.S  — 52 by-element multiply cases (MULL/MLAL/MLSL/MUL/MLA/MLS,
#              SQDMULL/SQDMLAL/SQDMLSL, SQDMULH/SQRDMULH/SQRDMLAH/SQRDMLSH;
#              vector S/H + scalar) diffed engine vs qemu-aarch64.
#
# Regenerating core.bin/consts.bin: unzip LLB.vma2.RELEASE.im4p from the
# 15.6.1 IPSW, DER-walk the IM4P payload (element 3), lzfse_decode it;
# core = raw[0x24CC0:+364], consts = raw[0x24E30:+40].
# Regenerating bankdata.bin: from the stripped Cirrus aux (md5
# 6be363a954a3083e10b87311eaf657f4), bank1 header at 0xA00000
# (5A 82 02 00 "nvram"); bankdata = bank[0x20:0x80000]; self-check:
# zlib.adler32(bank[0x14:0x80000]) == u32 at bank+0x10 == 0x3D58137C.
set -e
cd "$(dirname "$0")"
TC=${TC:-$HOME/workspace/swift-toolchain/swift-5.10.1-RELEASE-ubuntu24.04/usr/bin}
H=${H:-$HOME/workspace/retasuvm/tests/h_arm64}
CLANG=$TC/clang-15
[ -x "$CLANG" ] || CLANG=$(command -v clang || true)
LD=$TC/ld.lld
[ -x "$LD" ] || LD=$(command -v ld.lld || true)

for t in drv micro2 sweep; do
  $CLANG --target=aarch64-linux-gnu -march=armv8.1-a -DENGINE -c $t.S -o ${t}_engine.o
  $LD -T link.ld ${t}_engine.o -o ${t}_engine.elf
  $CLANG --target=aarch64-linux-gnu -march=armv8.1-a -c $t.S -o ${t}_qemu.o
  $LD -T link.ld ${t}_qemu.o -o ${t}_qemu.elf
  $H ${t}_engine.elf > ${t}_engine_out.txt 2>&1 || true
  qemu-aarch64 ${t}_qemu.elf > ${t}_qemu_out.txt 2>&1 || true
done

grep -E "^(bank|seq|zeros|ff)" drv_engine_out.txt > drv_engine_vals.txt || true
grep -E "^(bank|seq|zeros|ff)" drv_qemu_out.txt > drv_qemu_vals.txt || true
fail=0
diff drv_engine_vals.txt drv_qemu_vals.txt >/dev/null && echo "drv: engine == qemu" || { echo "drv: ENGINE != QEMU"; fail=1; }
python3 - <<'EOF' || fail=1
exp = dict(l.split() for l in open('expected.txt'))
got = dict(l.strip().split('=') for l in open('drv_engine_vals.txt'))
bad = [k for k, v in exp.items() if got.get(k, '').lower() != v.replace('0x', '').lower()]
print('drv vs expected.txt:', 'ALL 9 MATCH' if not bad else 'MISMATCH %s' % bad)
raise SystemExit(1 if bad else 0)
EOF
diff <(grep -E "^[0-9A-F]{8} " sweep_engine_out.txt) <(grep -E "^[0-9A-F]{8} " sweep_qemu_out.txt) >/dev/null && echo "sweep: engine == qemu (52 cases)" || { echo "sweep: ENGINE != QEMU"; fail=1; }
diff <(grep -E "^(B[0-9]|U) " micro2_engine_out.txt) <(grep -E "^(B[0-9]|U) " micro2_qemu_out.txt) >/dev/null && echo "micro2: engine == qemu" || { echo "micro2: ENGINE != QEMU"; fail=1; }
[ $fail -eq 0 ] && echo "ADLER CORPUS: PASS" || echo "ADLER CORPUS: FAIL"
exit $fail
