#!/bin/bash
# Phase 31 ROM-trace gate: same-window A/B. A = h_rom_img_p30, B = h_rom_img_p31
# (all instrumentation OFF, incl. P31UPC unset).
IT=/home/retasu/retasuvm/inst/imagetest
G=$IT/gate_p31
mkdir -p $G/workspace/retasuvm/disks
: > $G/workspace/retasuvm/disks/root.img
: > $G/workspace/retasuvm/disks/aux.img
cd $G
export HOME=$G VMAPPLE_ECID=17184306859705076658 ROM_TRACE=1
echo "A (p30 control) start $(date '+%F %T %Z')"
$IT/build/h_rom_img_p30 /home/retasu/retasuvm/bootrom/AVPBooter.vmapple2.bin 2048 3 0 > gate_p31_stdout_a.log 2> gate_p31_trace_a.txt
echo "A end $(date '+%F %T %Z')"
echo "B (p31) start $(date '+%F %T %Z')"
$IT/build/h_rom_img_p31 /home/retasu/retasuvm/bootrom/AVPBooter.vmapple2.bin 2048 3 0 > gate_p31_stdout_b.log 2> gate_p31_trace_b.txt
echo "B end $(date '+%F %T %Z')"
grep '^T ' gate_p31_trace_a.txt > gate_p31_filt_a.txt
grep '^T ' gate_p31_trace_b.txt > gate_p31_filt_b.txt
{
  echo "raw md5:"; md5sum gate_p31_trace_a.txt gate_p31_trace_b.txt
  echo "filtered md5:"; md5sum gate_p31_filt_a.txt gate_p31_filt_b.txt
  echo "filtered diff lines: $(diff gate_p31_filt_a.txt gate_p31_filt_b.txt | wc -l)"
  echo "raw diff lines: $(diff gate_p31_trace_a.txt gate_p31_trace_b.txt | wc -l)"
} > gate_p31_result.txt
cat gate_p31_result.txt
echo "GATE_DONE $(date '+%F %T %Z')" >> gate_p31_result.txt
