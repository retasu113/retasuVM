#!/bin/bash
# Phase 27 ROM-trace gate: same-window A/B control.
# A = pre-change binary h_rom_img_p25, B = new binary h_rom_img_p27
# (instrumentation OFF: P27TRACE, SPTRACE and SFVTRACE unset). Both run
# under the SAME gate HOME, same args, back-to-back. The ROM-trace md5
# drifts across hours for the same binary (live RTC value), so only the
# same-window A/B comparison is valid. Expect: filtered traces
# byte-identical (0 diff lines).
IT=/home/retasu/retasuvm/inst/imagetest
G=$IT/gate_p27
mkdir -p $G/workspace/retasuvm/disks
# Placeholder disk files (the ROM phase does not touch disks; the
# harness only needs the paths to exist).
: > $G/workspace/retasuvm/disks/root.img
: > $G/workspace/retasuvm/disks/aux.img
cd $G
export HOME=$G VMAPPLE_ECID=17184306859705076658 ROM_TRACE=1
echo "A (p25 control) start $(date '+%F %T %Z')"
$IT/build/h_rom_img_p25 /home/retasu/retasuvm/bootrom/AVPBooter.vmapple2.bin 2048 3 0 > gate_p27_stdout_a.log 2> gate_p27_trace_a.txt
echo "A end $(date '+%F %T %Z')"
echo "B (p27) start $(date '+%F %T %Z')"
$IT/build/h_rom_img_p27 /home/retasu/retasuvm/bootrom/AVPBooter.vmapple2.bin 2048 3 0 > gate_p27_stdout_b.log 2> gate_p27_trace_b.txt
echo "B end $(date '+%F %T %Z')"
grep '^T ' gate_p27_trace_a.txt > gate_p27_filt_a.txt
grep '^T ' gate_p27_trace_b.txt > gate_p27_filt_b.txt
{
  echo "raw md5:"
  md5sum gate_p27_trace_a.txt gate_p27_trace_b.txt
  echo "raw lines:"
  wc -l gate_p27_trace_a.txt gate_p27_trace_b.txt
  echo "filtered md5:"
  md5sum gate_p27_filt_a.txt gate_p27_filt_b.txt
  echo "filtered lines:"
  wc -l gate_p27_filt_a.txt gate_p27_filt_b.txt
  echo "filtered diff lines: $(diff gate_p27_filt_a.txt gate_p27_filt_b.txt | wc -l)"
  echo "raw diff lines: $(diff gate_p27_trace_a.txt gate_p27_trace_b.txt | wc -l)"
} > gate_p27_result.txt
cat gate_p27_result.txt
echo "GATE_DONE $(date '+%F %T %Z')" >> gate_p27_result.txt
