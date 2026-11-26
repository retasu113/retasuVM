#!/usr/bin/env python3
"""Patch src_observe/main.swift (a copy of src_idlediag/main.swift) for the
observation boot: replace the episode-count DRAM dump triggers with
wall-clock marks relative to the first park episode (+30/+60/+90 min),
and raise the harness wall cap 4.5h -> 6.5h. Engine files untouched."""
import sys

path = sys.argv[1]
src = open(path).read()

# 1. Add observation state next to the idlediag state declarations.
old_decl = """var idlediagDumped1 = false
var idlediagDumped2 = false
"""
new_decl = """var idlediagDumped1 = false
var idlediagDumped2 = false
// [observe] park開始時刻と wall-clock ダンプ節目
var idlediagParkStart: Date? = nil
var observeDumpCount = 0
"""
assert src.count(old_decl) == 1, "decl anchor not unique"
src = src.replace(old_decl, new_decl)

# 2. Replace the dump triggers inside the episode-counting block.
old_block = """                    if idlediagEpisodes >= 12 && !idlediagDumped1 && (cpu.diagFcvtHits > 0 || idlediagEpisodes >= 60) {
                        idlediagDumped1 = true
                        idlediagDumpDRAM(cpu, "dram_idlediag1.bin")
                    }
                    if idlediagEpisodes >= 80 && !idlediagDumped2 && idlediagDumped1 {
                        idlediagDumped2 = true
                        idlediagDumpDRAM(cpu, "dram_idlediag2.bin")
                    }
"""
new_block = """                    if idlediagParkStart == nil { idlediagParkStart = Date() }
                    let parkElapsed = Date().timeIntervalSince(idlediagParkStart!)
                    let observeMarks: [Double] = [1800, 3600, 5400]
                    if observeDumpCount < 3 && parkElapsed >= observeMarks[observeDumpCount] {
                        observeDumpCount += 1
                        stderr.write(Data("[observe] park elapsed \\(Int(parkElapsed))s, taking dump #\\(observeDumpCount) at episode \\(idlediagEpisodes) instr \\(totalNow)\\n".utf8))
                        idlediagDumpDRAM(cpu, "dram_observe\\(observeDumpCount).bin")
                    }
"""
assert src.count(old_block) == 1, "dump block anchor not unique"
src = src.replace(old_block, new_block)

# 3. Raise the wall cap so boot (~2h) + 90 min observation fits.
old_cap = "if Date().timeIntervalSince(wallStart) > 4.5 * 3600 {"
new_cap = "if Date().timeIntervalSince(wallStart) > 6.5 * 3600 {"
assert src.count(old_cap) == 1, "wall cap anchor not unique"
src = src.replace(old_cap, new_cap)

open(path, "w").write(src)
print("patched OK")
