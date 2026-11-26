#!/bin/bash
# Phase 29 ROM-trace gate: same-window A/B control.
# A = pre-fix binary h_rom_img_p28, B = new binary h_rom_img_p29
# (instrumentation OFF: P27TRACE, WQTRACE, SPTRACE, SFVTRACE, TIMEWATCH unset).
# The p29 binary carries the counterValue() monotonic-clock FIX (always
# on); the ROM instruction trace must still be byte-identical to the
# pre-fix binary in the same window (the trace is PC-only; the ROM phase
# does not branch on counter values — same assumption as the p20/p23/
# p25/p27 gates, which all passed with live-RTC drift).
IT=/home/retasu/retasuvm/inst/imagetest
G=$IT/gate_p29
mkdir -p $G/workspace/retasuvm/disks
: > $G/workspace/retasuvm/disks/root.img
: > $G/workspace/retasuvm/disks/aux.img
cd $G
export HOME=$G VMAPPLE_ECID=17184306859705076658 ROM_TRACE=1
echo "A (p28 control) start $(date '+%F %T %Z')"
$IT/build/h_rom_img_p28 /home/retasu/retasuvm/bootrom/AVPBooter.vmapple2.bin 2048 3 0 > gate_p29_stdout_a.log 2> gate_p29_trace_a.txt
echo "A end $(date '+%F %T %Z')"
echo "B (p29) start $(date '+%F %T %Z')"
$IT/build/h_rom_img_p29 /home/retasu/retasuvm/bootrom/AVPBooter.vmapple2.bin 2048 3 0 > gate_p29_stdout_b.log 2> gate_p29_trace_b.txt
echo "B end $(date '+%F %T %Z')"
grep '^T ' gate_p29_trace_a.txt > gate_p29_filt_a.txt
grep '^T ' gate_p29_trace_b.txt > gate_p29_filt_b.txt
{
  echo "raw md5:"
  md5sum gate_p29_trace_a.txt gate_p29_trace_b.txt
  echo "raw lines:"
  wc -l gate_p29_trace_a.txt gate_p29_trace_b.txt
  echo "filtered md5:"
  md5sum gate_p29_filt_a.txt gate_p29_filt_b.txt
  echo "filtered lines:"
  wc -l gate_p29_filt_a.txt gate_p29_filt_b.txt
  echo "filtered diff lines: $(diff gate_p29_filt_a.txt gate_p29_filt_b.txt | wc -l)"
  echo "raw diff lines: $(diff gate_p29_trace_a.txt gate_p29_trace_b.txt | wc -l)"
} > gate_p29_result.txt
cat gate_p29_result.txt
echo "GATE_DONE $(date '+%F %T %Z')" >> gate_p29_result.txt
