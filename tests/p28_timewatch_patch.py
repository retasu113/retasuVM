#!/usr/bin/env python3
"""Phase 28: counterValue() monotonic-clock FIX + TIMEWATCH diagnostic.

Grounding (phase 28 desk work, tests/logs/nonmono_phase28_20261124.md):
- The Non-monotonic-time panic that killed home_p27 fired in
  thread_unblock (sched_prim.c:1021), ctime = mach_approximate_time() =
  ml_get_timebase() = CNTVCT_EL0 read (identified by kernelcache
  disassembly: the caller PC 0xfffffe00200b6378 is the return address of
  the inlined check_monotonic_time copy whose ctime comes from a direct
  inline `mrs cntvct_el0`).
- The engine served CNTVCT/CNTPCT from counterValue() =
  Date().timeIntervalSince(timerEpoch) * timeScale * freq — the host
  WALL clock (CLOCK_REALTIME). The WSL2 host clock was stepped backwards
  repeatedly during the boot (journal: systemd-resolved "Clock change
  detected" 2,425 times on 2026-11-23, ~every 35 s, incl. 20:39:56 and
  20:40:29 bracketing the ~20:40 panic). Guest rewind was 3,454,121
  ticks @24 MHz = 143.9 ms guest = ~1.44 s host step at TIMESCALE=0.1.
- References use monotonic sources: QEMU's ARM generic timer =
  QEMU_CLOCK_VIRTUAL, based on get_clock() = clock_gettime(
  CLOCK_MONOTONIC) (util/qemu-timer-common.c:58; target/arm/helper.c:
  1296); Henge's counter() = mach_absolute_time() (core/sysreg.c:29).
- All other engine rewind paths excluded: timerEpoch is set once at
  init (a re-init would rewind by hours, not 144 ms); timeScale is set
  once by the harness from env; cntvOff is writable only from EL2
  (early boot); Double precision is ample.

FIX (both modes): counterValue() switches to DispatchTime
uptimeNanoseconds (CLOCK_MONOTONIC-based). timerEpochMonoNs is captured
at CPU init next to the old Date epoch.

Full mode (PC lineage src_p28 only) also adds the TIMEWATCH diagnostic
(env TIMEWATCH=1): inside counterValue, compute the LEGACY wall-clock
value alongside and log every backward step of the wall source (ev=
REWIND) plus periodic wall-vs-mono divergence snapshots (ev=DIVERGE)
to timewatch.txt. The returned value is always the monotonic one.

Usage: p28_timewatch_patch.py <path-to-ARM64CPU.swift> [--fix-only]
"""
import sys

path = sys.argv[1]
fix_only = "--fix-only" in sys.argv
src = open(path).read()

assert "timerEpochMonoNs" not in src, "patch already applied"
assert "p28TwLog" not in src, "patch already applied"

# ---------- 1. timer epoch: add monotonic epoch ----------
anchor1 = """    private var timerEpoch = Date()
"""
assert src.count(anchor1) == 1, f"anchor1 count={src.count(anchor1)}"
if fix_only:
    block1 = """    /// [p28 FIX] Monotonic epoch for counterValue() (DispatchTime =
    /// CLOCK_MONOTONIC). The old implementation used Date() (the host
    /// wall clock); WSL2 host clock steps rewound the guest counter
    /// and fired XNU's Non-monotonic-time panic (phase 28). QEMU uses
    /// CLOCK_MONOTONIC, Henge uses mach_absolute_time().
    private let timerEpochMonoNs: UInt64 = DispatchTime.now().uptimeNanoseconds
"""
else:
    block1 = anchor1 + """    /// [p28 FIX] Monotonic epoch for counterValue() (DispatchTime =
    /// CLOCK_MONOTONIC). timerEpoch (Date) is kept only as the legacy
    /// wall-clock reference for the TIMEWATCH diagnostic below.
    private let timerEpochMonoNs: UInt64 = DispatchTime.now().uptimeNanoseconds
"""
src = src.replace(anchor1, block1, 1)

# ---------- 2. counterValue(): monotonic source (+ TIMEWATCH hook) ----------
anchor2 = """    private func counterValue() -> UInt64 {
        let elapsed = Date().timeIntervalSince(timerEpoch)
        return UInt64(elapsed * timeScale * Double(timerFrequency))
    }
"""
assert src.count(anchor2) == 1, f"anchor2 count={src.count(anchor2)}"
if fix_only:
    block2 = """    private func counterValue() -> UInt64 {
        // [p28 FIX] Monotonic time source (see timerEpochMonoNs). The
        // wall clock must never feed the guest counter: a host clock
        // step backwards rewinds CNTVCT/CNTPCT and XNU panics with
        // "Non-monotonic time" (check_monotonic_time, thread_unblock).
        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- timerEpochMonoNs
        let elapsed = Double(elapsedNs) / 1_000_000_000.0
        return UInt64(elapsed * timeScale * Double(timerFrequency))
    }
"""
else:
    block2 = """    private func counterValue() -> UInt64 {
        // [p28 FIX] Monotonic time source (see timerEpochMonoNs). The
        // wall clock must never feed the guest counter: a host clock
        // step backwards rewinds CNTVCT/CNTPCT and XNU panics with
        // "Non-monotonic time" (check_monotonic_time, thread_unblock).
        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- timerEpochMonoNs
        let elapsed = Double(elapsedNs) / 1_000_000_000.0
        let value = UInt64(elapsed * timeScale * Double(timerFrequency))
        if p28TimewatchEnabled { p28Timewatch(mono: value) }
        return value
    }

    // [p28] TIMEWATCH hook (TIMEWATCH=1): computes the LEGACY
    // wall-clock (Date) value alongside the monotonic value and logs
    // every backward step of the wall source — exactly the events that
    // used to rewind the guest clock — plus a periodic wall-vs-mono
    // divergence snapshot. Never affects the returned value.
    private func p28Timewatch(mono: UInt64) {
        let wallElapsed = Date().timeIntervalSince(timerEpoch)
        let wall = wallElapsed > 0 ? UInt64(wallElapsed * timeScale * Double(timerFrequency)) : 0
        p28TwCalls &+= 1
        if wall < p28TwLastWall && p28TwRewinds < 512 {
            p28TwRewinds &+= 1
            p28TwLog("instr=\\(instructionsExecuted) ev=REWIND wallPrev=\\(p28TwLastWall) wallNow=\\(wall) rewindTicks=\\(p28TwLastWall - wall) mono=\\(mono)")
        }
        p28TwLastWall = wall
        if (p28TwCalls & 0x3FFFFF) == 0 && p28TwSnapshots < 4096 {
            p28TwSnapshots &+= 1
            let div = Int64(bitPattern: wall) &- Int64(bitPattern: mono)
            p28TwLog("instr=\\(instructionsExecuted) ev=DIVERGE wall=\\(wall) mono=\\(mono) wallMinusMono=\\(div)")
        }
    }
"""
src = src.replace(anchor2, block2, 1)

# ---------- 3. TIMEWATCH globals (full mode only; after p27Log) ----------
if not fix_only:
    anchor3 = """func p27Log(_ s: String) {
    guard p27TraceEnabled else { return }
    if p27Handle == nil {
        let path = ProcessInfo.processInfo.environment["P27TRACE_PATH"] ?? "p27trace.txt"
        FileManager.default.createFile(atPath: path, contents: nil)
        p27Handle = FileHandle(forWritingAtPath: path)
    }
    p27Handle?.write(Data((s + "\\n").utf8))
    FileHandle.standardError.write(Data(("[p27trace] " + s + "\\n").utf8))
}
"""
    assert src.count(anchor3) == 1, f"anchor3 count={src.count(anchor3)}"
    block3 = anchor3 + """
// MARK: - Phase-28 diagnostic: wall-clock rewind watcher (env TIMEWATCH=1; unset = no-op)
// counterValue() now runs on a monotonic clock (the phase-28 fix). This
// watcher computes the LEGACY wall-clock (Date) value alongside and logs
// every backward step of the wall source — the events that used to
// rewind the guest counter and fire XNU's check_monotonic_time panic —
// plus periodic wall-vs-mono divergence snapshots.
// Log: timewatch.txt (TIMEWATCH_PATH override).
let p28TimewatchEnabled = ProcessInfo.processInfo.environment["TIMEWATCH"] != nil
private var p28TwHandle: FileHandle? = nil
private var p28TwLastWall: UInt64 = 0
private var p28TwRewinds = 0
private var p28TwCalls: UInt64 = 0
private var p28TwSnapshots = 0
func p28TwLog(_ s: String) {
    guard p28TimewatchEnabled else { return }
    if p28TwHandle == nil {
        let path = ProcessInfo.processInfo.environment["TIMEWATCH_PATH"] ?? "timewatch.txt"
        FileManager.default.createFile(atPath: path, contents: nil)
        p28TwHandle = FileHandle(forWritingAtPath: path)
    }
    p28TwHandle?.write(Data((s + "\\n").utf8))
    FileHandle.standardError.write(Data(("[timewatch] " + s + "\\n").utf8))
}
"""
    src = src.replace(anchor3, block3, 1)

open(path, "w").write(src)
print(f"p28 patch applied ({'fix-only' if fix_only else 'full: fix + TIMEWATCH'})")
