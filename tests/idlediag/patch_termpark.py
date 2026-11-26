#!/usr/bin/env python3
"""Patch src_termpark/main.swift (a copy of src_observe/main.swift) for the
phase-5 terminal-park capture: start the park clock only at the first park
episode AFTER display init (diagFcvtHits > 0), and take two DRAM dumps at
park +120s and park +720s (10 host-minutes apart). Engine files untouched."""
import sys

path = sys.argv[1]
src = open(path).read()

old_block = """                    if idlediagParkStart == nil { idlediagParkStart = Date() }
                    let parkElapsed = Date().timeIntervalSince(idlediagParkStart!)
                    let observeMarks: [Double] = [1800, 3600, 5400]
                    if observeDumpCount < 3 && parkElapsed >= observeMarks[observeDumpCount] {
                        observeDumpCount += 1
                        stderr.write(Data("[observe] park elapsed \\(Int(parkElapsed))s, taking dump #\\(observeDumpCount) at episode \\(idlediagEpisodes) instr \\(totalNow)\\n".utf8))
                        idlediagDumpDRAM(cpu, "dram_observe\\(observeDumpCount).bin")
                    }
"""
new_block = """                    // [termpark] park clock starts at the first park episode AFTER
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
assert src.count(old_block) == 1, "dump block anchor not unique"
src = src.replace(old_block, new_block)

open(path, "w").write(src)
print("patched OK")
