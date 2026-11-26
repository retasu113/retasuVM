#!/usr/bin/env python3
"""Patch src_firstpark2/main.swift (a copy of src_firstpark/main.swift) for
the phase-7 second attempt.

Run 1 of firstpark never parked: the guest ran to instr 3,474,667,246 and
requested a PSCI SYSTEM_RESET (exit 0x52535431 'RST1'); with installer=0
the harness preserved nothing and exited — no dump, guest state lost.
The park is therefore not a guaranteed outcome; the wedge-forming window
(~3.0-3.35B in every prior run) must be captured DURING the approach:

- milestone dumps at instr 3.05B / 3.20B / 3.35B (chunk-boundary snapshots;
  the interpreter is single-threaded so each snapshot is consistent;
  blocked threads — everything this diagnosis reads — are exact);
- the firstpark park-episode dumps (#1 / #8 / +600s) are kept;
- a final dump is taken after the main loop exits for ANY reason
  (halt/reset/wall cap), before the panic-string scan.
Engine files untouched."""
import sys

path = sys.argv[1]
src = open(path).read()

# 1. Milestone state next to the firstpark dump state.
old_decl = """var fpDumped1 = false
var fpDumped2 = false
var fpDumped3 = false
"""
new_decl = """var fpDumped1 = false
var fpDumped2 = false
var fpDumped3 = false
// [firstpark2] wedge 形成区間のマイルストーン・ダンプ
let fpMilestones: [UInt64] = [3_050_000_000, 3_200_000_000, 3_350_000_000]
var fpMilestoneIdx = 0
"""
assert src.count(old_decl) == 1, "decl anchor not unique"
src = src.replace(old_decl, new_decl)

# 2. Milestone trigger, checked every loop iteration before the failsafe.
old_fail = """        // [firstpark] failsafe: park が来ない場合も 3.6B 命令時点の状態を残す
"""
new_fail = """        // [firstpark2] milestone dumps: capture the wedge-forming window
        // during the approach, park or no park.
        if fpMilestoneIdx < fpMilestones.count && totalNow >= fpMilestones[fpMilestoneIdx] {
            fpMilestoneIdx += 1
            stderr.write(Data("[firstpark2] MILESTONE dump #\\(fpMilestoneIdx) at instr \\(totalNow) fcvtHits=\\(cpu.diagFcvtHits)\\n".utf8))
            idlediagDumpDRAM(cpu, "dram_fpms\\(fpMilestoneIdx).bin")
        }
        // [firstpark] failsafe: park が来ない場合も 3.6B 命令時点の状態を残す
"""
assert src.count(old_fail) == 1, "failsafe anchor not unique"
src = src.replace(old_fail, new_fail)

# 3. Final dump after the main loop, whatever the exit reason.
old_final = """scanPanicLog(cpu.memory, tag: "final")"""
new_final = """// [firstpark2] 終了理由 (halt/reset/wall cap) によらず最終状態を保存する
idlediagDumpDRAM(cpu, "dram_fpend.bin")
scanPanicLog(cpu.memory, tag: "final")"""
assert src.count(old_final) == 1, "final anchor not unique"
src = src.replace(old_final, new_final)

open(path, "w").write(src)
print("patched OK")
