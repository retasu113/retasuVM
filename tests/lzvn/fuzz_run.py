#!/usr/bin/env python3
"""Drive the decode-cache fuzz differential: for each generated
instruction word, build the guest, run h_fuzz with DECODE_CACHE
on (default) and off, compare the records."""
import os, random, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fuzz_guest import build_guest

HERE = os.path.dirname(os.path.abspath(__file__))
HFUZZ = os.path.expanduser('~/workspace/retasuvm/tests/h_fuzz')
TMPD = os.path.join(HERE, 'fuzz_tmp')
os.makedirs(TMPD, exist_ok=True)

def run(word, cache):
    path = os.path.join(TMPD, 'g%08x.bin' % word)
    build_guest(word, path)
    env = dict(os.environ)
    if not cache:
        env['DECODE_CACHE'] = '0'
    r = subprocess.run([HFUZZ, path], capture_output=True, text=True, env=env, timeout=30)
    return r.stdout.strip()

def gen_words(seed, n):
    rng = random.Random(seed)
    words = []
    def R(a, b): return rng.randrange(a, b)
    for _ in range(n):
        cls = rng.randrange(20)
        rd, rn, rm, ra = R(0, 29), R(0, 29), R(0, 29), R(0, 29)
        if cls == 0:    # ADD/SUB shifted reg
            w = 0x0B000000 | (R(0, 2) << 30) | (R(0, 2) << 29) | (R(0, 4) << 22) | (rm << 16) | (R(0, 64) << 10) | (rn << 5) | rd
        elif cls == 1:  # ADD/SUB extended reg
            w = 0x0B200000 | (R(0, 2) << 30) | (R(0, 2) << 29) | (rm << 16) | (R(0, 8) << 13) | (R(0, 8) << 10) | (rn << 5) | rd
        elif cls == 2:  # logic shifted reg
            w = 0x0A000000 | (R(0, 2) << 30) | (R(0, 4) << 29) | (R(0, 4) << 22) | (rm << 16) | (R(0, 64) << 10) | (rn << 5) | rd
        elif cls == 3:  # ADC/SBC
            w = 0x1A000000 | (R(0, 2) << 30) | (R(0, 2) << 29) | (rm << 16) | (rn << 5) | rd
        elif cls == 4:  # CSEL family
            w = 0x1A800000 | (R(0, 2) << 30) | (R(0, 4) << 29) | (rm << 16) | (R(0, 16) << 12) | (rn << 5) | rd
        elif cls == 5:  # CCMP/CCMN (reg + imm forms)
            if R(0, 2):
                w = 0x3A400000 | (R(0, 2) << 30) | (R(0, 2) << 29) | (rm << 16) | (R(0, 16) << 12) | (rn << 5) | R(0, 16)
            else:
                w = 0x3A400800 | (R(0, 2) << 30) | (R(0, 2) << 29) | (R(0, 32) << 16) | (R(0, 16) << 12) | (rn << 5) | R(0, 16)
        elif cls == 6:  # DP2SRC (udiv/sdiv/shifts/ror/crc excluded by opcode choice)
            opc = [0, 1, 2, 8, 9, 10, 11][R(0, 7)]
            w = 0x1AC00000 | (R(0, 2) << 30) | (rm << 16) | (opc << 10) | (rn << 5) | rd
        elif cls == 7:  # DP3SRC (madd/msub family)
            w = 0x1B000000 | (R(0, 2) << 30) | (R(0, 4) << 29) | (rm << 16) | (R(0, 2) << 15) | (ra << 10) | (rn << 5) | rd
        elif cls == 8:  # bitfield
            w = 0x13000000 | (R(0, 2) << 30) | (R(0, 4) << 29) | (R(0, 2) << 22) | (R(0, 64) << 16) | (R(0, 64) << 10) | (rn << 5) | rd
        elif cls == 9:  # EXTR
            w = 0x13800000 | (R(0, 2) << 30) | (R(0, 2) << 22) | (rm << 16) | (R(0, 64) << 10) | (rn << 5) | rd
        elif cls == 10: # LDR/STR unsigned imm
            w = 0x39000000 | (R(0, 4) << 30) | (R(0, 4) << 22) | (R(0, 256) << 10) | (rn << 5) | rd
        elif cls == 11: # LDR/STR reg offset
            w = 0x38200800 | (R(0, 4) << 30) | (R(0, 4) << 22) | (rm << 16) | (R(0, 8) << 13) | (R(0, 2) << 12) | (rn << 5) | rd
        elif cls == 12: # LDR/STR imm9 (unscaled/pre/post)
            w = 0x38000000 | (R(0, 4) << 30) | (R(0, 4) << 22) | (R(0, 512) << 12) | (R(0, 4) << 10) | (rn << 5) | rd
        elif cls == 13: # LDP/STP
            w = 0x28000000 | (R(0, 4) << 30) | (R(0, 2) << 26) | ([1, 2, 3][R(0, 3)] << 23) | (R(0, 2) << 22) | (rm << 10) | (R(0, 128) << 15) | (rn << 5) | rd
            w = (w & ~(0x7F << 15)) | (R(0, 128) << 15)
        elif cls == 14: # MOV wide (MOVN/MOVZ/MOVK)
            w = 0x12800000 | (R(0, 2) << 30) | (R(0, 4) << 29) | (R(0, 4) << 21) | (R(0, 65536) << 5) | rd
        elif cls == 15: # logic immediate
            sf = R(0, 2)
            w = 0x12000000 | (sf << 31) | (R(0, 4) << 29) | (R(0, 2) << 22) | (R(0, 64) << 16) | (R(0, 64) << 10) | (rn << 5) | rd
        elif cls == 16: # ADD/SUB immediate
            w = 0x11000000 | (R(0, 2) << 30) | (R(0, 2) << 29) | (R(0, 2) << 22) | (R(0, 4096) << 10) | (rn << 5) | rd
        elif cls == 17: # LDXR/STXR/LDAR/STLR space
            w = 0x08000000 | (R(0, 4) << 30) | (R(0, 2) << 23) | (R(0, 2) << 21) | (rm << 16) | (R(0, 2) << 15) | (rn << 5) | rd
        elif cls == 18: # LDR literal (offset small +/- around pc: scratch not near; use imm 0..31 -> may fault identically)
            w = 0x18000000 | (R(0, 3) << 30) | (R(0, 1024) << 5) | rd
        else:           # ADR (immlo/immhi random small)
            w = 0x10000000 | (R(0, 2) << 31) | (R(0, 4) << 29) | (R(0, 2**19) << 5) | rd
        words.append(w & 0xFFFFFFFF)
    return words

def main():
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 200
    bad = 0
    for i, w in enumerate(gen_words(seed, n)):
        try:
            on = run(w, True)
            off = run(w, False)
        except subprocess.TimeoutExpired:
            print('TIMEOUT 0x%08x' % w); continue
        if on != off:
            bad += 1
            print('DIVERGE word=0x%08x' % w)
            print('  cache-on :', on[:200])
            print('  cache-off:', off[:200])
            if bad >= 5:
                print('stopping after 5 divergences'); break
    print('done: %d words, %d divergences' % (n, bad))

if __name__ == '__main__':
    main()
