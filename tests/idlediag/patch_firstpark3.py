#!/usr/bin/env python3
"""Patch src_firstpark3/main.swift (a copy of src_firstpark2/main.swift) for
the phase-10 TIMESCALE probes (0.1 / 0.05).

Rationale: TIMESCALE<1 stretches guest-time-gated phases over many more
instructions, so the wedge window may sit well past the firstpark2 ladder
(3.05/3.20/3.35 B) and its 3.6 B failsafe. firstpark3 therefore:
- extends the milestone ladder to 3.05/3.20/3.35/3.80/4.40/5.20 B
  (dram_fpms1..6.bin) — the wedge state is frozen once formed, so any
  post-formation milestone captures the phase-8 signature;
- decouples the failsafe from the park-dump flag fpDumped1 and moves it
  to 5.6 B (dram_fpfs.bin), so a late snapshot exists even if the park
  dumps were consumed by a transient park;
- keeps the park-episode dumps (#1/#8/+600 s) and the final dump.
Engine files untouched."""
import sys

path = sys.argv[1]
src = open(path).read()

# 1. Extended milestone ladder + failsafe flag.
old_decl = """// [firstpark2] wedge 形成区間のマイルストーン・ダンプ
let fpMilestones: [UInt64] = [3_050_000_000, 3_200_000_000, 3_350_000_000]
var fpMilestoneIdx = 0
"""
new_decl = """// [firstpark3] phase-10 TIMESCALE probe: extended milestone ladder for a
// displaced trajectory + decoupled late failsafe.
let fpMilestones: [UInt64] = [3_050_000_000, 3_200_000_000, 3_350_000_000, 3_800_000_000, 4_400_000_000, 5_200_000_000]
var fpMilestoneIdx = 0
var fpFailsafeDumped = false
"""
assert src.count(old_decl) == 1, "decl anchor not unique"
src = src.replace(old_decl, new_decl)

# 2. Milestone log tag.
old_ms = """            stderr.write(Data("[firstpark2] MILESTONE dump #\\(fpMilestoneIdx) at instr \\(totalNow) fcvtHits=\\(cpu.diagFcvtHits)\\n".utf8))"""
new_ms = """            stderr.write(Data("[firstpark3] MILESTONE dump #\\(fpMilestoneIdx) at instr \\(totalNow) fcvtHits=\\(cpu.diagFcvtHits)\\n".utf8))"""
assert src.count(old_ms) == 1, "milestone anchor not unique"
src = src.replace(old_ms, new_ms)

# 3. Decoupled late failsafe at 5.6 B.
old_fail = """        // [firstpark] failsafe: park が来ない場合も 3.6B 命令時点の状態を残す
        if !fpDumped1 && totalNow >= 3_600_000_000 {
            fpDumped1 = true
            stderr.write(Data("[firstpark] FAILSAFE dump (no park episode by 3.6B): instr \\(totalNow) fcvtHits=\\(cpu.diagFcvtHits)\\n".utf8))
            idlediagDumpDRAM(cpu, "dram_fp1.bin")
        }
"""
new_fail = """        // [firstpark3] late failsafe: snapshot at 5.6B regardless of park
        // state (decoupled from the park-dump flags).
        if !fpFailsafeDumped && totalNow >= 5_600_000_000 {
            fpFailsafeDumped = true
            stderr.write(Data("[firstpark3] FAILSAFE dump at 5.6B: instr \\(totalNow) fcvtHits=\\(cpu.diagFcvtHits)\\n".utf8))
            idlediagDumpDRAM(cpu, "dram_fpfs.bin")
        }
"""
assert src.count(old_fail) == 1, "failsafe anchor not unique"
src = src.replace(old_fail, new_fail)

open(path, "w").write(src)
print("patched OK")
