#!/usr/bin/env python3
"""Phase 20: add ILLTRACE instrument to src_p22/ARM64CPU.swift.
Logs every EC 0x00 (unknown/unallocated instruction) synchronous exception
with instr count, EL, faulting PC, instruction word, and LR.
Env-gated (ILLTRACE=1); inert when unset. Mirrors the p16 WATCH pattern.
"""
import sys

path = sys.argv[1]
src = open(path).read()

block = '''
// MARK: - Phase-20 diagnostic: illegal-instruction trace (env ILLTRACE=1; unset = no-op)
// Logs every synchronous exception with EC 0x00 (unallocated/undefined
// instruction) as it is raised: instr count, current EL, faulting PC,
// instruction word (re-fetched at ELR; 0xFFFFFFFF if unfetchable), LR.
// The guest kernel delivers these as SIGILL to EL0 processes.
let p20IllTraceEnabled = ProcessInfo.processInfo.environment["ILLTRACE"] != nil
private var p20IllLines: [String] = []
private var p20IllHandle: FileHandle? = nil
func p20IllLog(_ s: String) {
    guard p20IllTraceEnabled else { return }
    p20IllLines.append(s)
    if p20IllLines.count >= 64 { p20IllFlush() }
}
func p20IllFlush() {
    guard p20IllTraceEnabled, !p20IllLines.isEmpty else { return }
    if p20IllHandle == nil {
        let path = ProcessInfo.processInfo.environment["ILLTRACE_PATH"] ?? "illtrace.txt"
        FileManager.default.createFile(atPath: path, contents: nil)
        p20IllHandle = FileHandle(forWritingAtPath: path)
    }
    p20IllHandle?.write(Data((p20IllLines.joined(separator: "\\n") + "\\n").utf8))
    p20IllLines.removeAll()
}
'''

anchor1 = """    p16WatchHandle?.write(Data((p16WatchLines.joined(separator: "\\n") + "\\n").utf8))
    p16WatchLines.removeAll()
}"""
assert src.count(anchor1) == 1, f"anchor1 count={src.count(anchor1)}"
src = src.replace(anchor1, anchor1 + "\n" + block, 1)

old_raise = """    private func raiseSync(ec: UInt64, iss: UInt64, elr: UInt64) {
        enterException(vectorOffset: syncVectorOffset(), elr: elr, esr: (ec << 26) | (1 << 25) | (iss & 0x1FF_FFFF))
    }"""
new_raise = """    private func raiseSync(ec: UInt64, iss: UInt64, elr: UInt64) {
        if ec == 0x00 && p20IllTraceEnabled {
            let word = (try? fetch32(at: elr)) ?? 0xFFFF_FFFF
            p20IllLog("instr=\\(instructionsExecuted) el=\\(currentEL) ec=0x00 pc=0x\\(String(elr, radix: 16)) word=0x\\(String(word, radix: 16)) x30=0x\\(String(registers[30], radix: 16))")
            p20IllFlush()
        }
        enterException(vectorOffset: syncVectorOffset(), elr: elr, esr: (ec << 26) | (1 << 25) | (iss & 0x1FF_FFFF))
    }"""
assert src.count(old_raise) == 1, f"anchor2 count={src.count(old_raise)}"
src = src.replace(old_raise, new_raise, 1)

open(path, "w").write(src)
print("PATCH_OK illtrace instrument applied")
