#!/usr/bin/env python3
"""Patch src_firstpark/main.swift (a copy of src_termpark/main.swift) for the
phase-7 capture: catch the IOKit config wedge AS IT FORMS.

Phase 6 showed the terminal dumps are too late: the gfx config thread [9c]
and the shared-wait's turnstile owner have both EXITED by then. This variant
dumps at the FIRST counted park episode (the earliest quiesced state, gated
only on >3.0B instr + kernel PC, NOT on fcvtHits — phase 4/5 proved the
shared wait already exists pre-display), again at episode #8, and at
park +600s as the formed-state reference. A failsafe dump fires at 3.6B
instructions if the guest never parks. Engine files untouched."""
import sys

path = sys.argv[1]
src = open(path).read()

# 1. Add firstpark dump state next to the observe state declarations.
old_decl = """var idlediagParkStart: Date? = nil
var observeDumpCount = 0
"""
new_decl = """var idlediagParkStart: Date? = nil
var observeDumpCount = 0
// [firstpark] wedge 形成中のダンプ管理
var fpDumped1 = false
var fpDumped2 = false
var fpDumped3 = false
"""
assert src.count(old_decl) == 1, "decl anchor not unique"
src = src.replace(old_decl, new_decl)

# 2. Replace the termpark dump block with the firstpark triggers.
old_block = """                    // [termpark] park clock starts at the first park episode AFTER
                    // display init (fcvtHits > 0); dumps at +120s / +720s (10 min apart).
                    if idlediagParkStart == nil && cpu.diagFcvtHits > 0 { idlediagParkStart = Date() }
                    if let parkStart = idlediagParkStart {
                        let parkElapsed = Date().timeIntervalSince(parkStart)
                        let observeMarks: [Double] = [120, 720]
                        if observeDumpCount < 2 && parkElapsed >= observeMarks[observeDumpCount] {
                            observeDumpCount += 1
                            stderr.write(Data("[termpark] post-display park elapsed \\(Int(parkElapsed))s, taking dump #\\(observeDumpCount) at episode \\(idlediagEpisodes) instr \\(totalNow) fcvtHits=\\(cpu.diagFcvtHits)\\n".utf8))
                            idlediagDumpDRAM(cpu, "dram_termpark\\(observeDumpCount).bin")
                        }
                    }
"""
new_block = """                    // [firstpark] capture the wedge AS IT FORMS: the park clock
                    // starts at the first counted park episode regardless of
                    // fcvtHits (the shared wait already exists pre-display, and
                    // [9c] + the shared-wait owner exit before the terminal
                    // park, so the earliest quiesced state is the only place
                    // both are still alive). Dumps: episode #1, episode #8,
                    // park +600s (formed-state reference).
                    if idlediagParkStart == nil { idlediagParkStart = Date() }
                    let fpElapsed = Date().timeIntervalSince(idlediagParkStart!)
                    if idlediagEpisodes == 1 && !fpDumped1 {
                        fpDumped1 = true
                        stderr.write(Data("[firstpark] dump #1 at FIRST park episode: instr \\(totalNow) fcvtHits=\\(cpu.diagFcvtHits)\\n".utf8))
                        idlediagDumpDRAM(cpu, "dram_fp1.bin")
                    } else if idlediagEpisodes >= 8 && fpDumped1 && !fpDumped2 {
                        fpDumped2 = true
                        stderr.write(Data("[firstpark] dump #2 at park episode \\(idlediagEpisodes) (park +\\(Int(fpElapsed))s): instr \\(totalNow) fcvtHits=\\(cpu.diagFcvtHits)\\n".utf8))
                        idlediagDumpDRAM(cpu, "dram_fp2.bin")
                    } else if fpDumped1 && !fpDumped3 && fpElapsed >= 600 {
                        fpDumped3 = true
                        stderr.write(Data("[firstpark] dump #3 at park +\\(Int(fpElapsed))s, episode \\(idlediagEpisodes): instr \\(totalNow) fcvtHits=\\(cpu.diagFcvtHits)\\n".utf8))
                        idlediagDumpDRAM(cpu, "dram_fp3.bin")
                    }
"""
assert src.count(old_block) == 1, "dump block anchor not unique"
src = src.replace(old_block, new_block)

# 3. Failsafe: if the guest never parks, capture the late-matching state.
old_status = """        // [stalldiag] idle 忍耐: 進展がなければ wall-clock で待ち、起床を観測する
"""
new_status = """        // [firstpark] failsafe: park が来ない場合も 3.6B 命令時点の状態を残す
        if !fpDumped1 && totalNow >= 3_600_000_000 {
            fpDumped1 = true
            stderr.write(Data("[firstpark] FAILSAFE dump (no park episode by 3.6B): instr \\(totalNow) fcvtHits=\\(cpu.diagFcvtHits)\\n".utf8))
            idlediagDumpDRAM(cpu, "dram_fp1.bin")
        }
        // [stalldiag] idle 忍耐: 進展がなければ wall-clock で待ち、起床を観測する
"""
assert src.count(old_status) == 1, "status anchor not unique"
src = src.replace(old_status, new_status)

open(path, "w").write(src)
print("patched OK")
