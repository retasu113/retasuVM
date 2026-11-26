#!/bin/bash
# Phase 25: SP_EL0 misalignment transition capture boot. ONE cycle only.
# The harness halts (non-reset exit) when SPTRACE fires on the first
# aligned -> misaligned SP_EL0 transition after userspace starts (or on
# an ERET to EL0 with a bad SP, or EL0 execution with a bad SP).
HT=$HOME/retasuvm/inst/imagetest/home_p25
LOGD=$HOME/retasuvm/tests/logs
BIN=$HOME/retasuvm/inst/imagetest/build/h_rom_img_p25
ROM=$HOME/retasuvm/bootrom/AVPBooter.vmapple2.bin
mkdir -p $LOGD
# Build-rule check: refuse to run a stale/failed binary.
echo "p25 binary: $(ls -la $BIN 2>/dev/null | awk '{print $6, $7, $8, $9}'), errors in build log: $(grep -c 'error:' $HOME/retasuvm/inst/imagetest/build_p25.log 2>/dev/null), now: $(date '+%F %T %Z')" >> $LOGD/p25_driver.log
L=$LOGD/boot_p25_cycle1.log
echo "=== cycle 1 start $(date '+%F %T %Z') ===" >> $LOGD/p25_driver.log
(cd $HT && HOME=$HT FAST=1 TIMESCALE=0.1 WATCH=1 NOBSDMGROOT=1 ILLTRACE=1 SFVTRACE=1 SPTRACE=1 VMAPPLE_ECID=17184306859705076658 $BIN $ROM 4096 12000 0 > $L 2>&1)
echo "=== cycle 1 end $(date '+%F %T %Z') ===" >> $LOGD/p25_driver.log
grep -m1 '\[romboot\] done' $L >> $LOGD/p25_driver.log
if [ -f $HT/dram_fpend.bin ]; then mv $HT/dram_fpend.bin $HT/dram_fpend_cycle1.bin; fi
if [ -f $HT/sptrace.txt ]; then mv $HT/sptrace.txt $HT/sptrace_cycle1.txt; fi
if [ -f $HT/sfvtrace.txt ]; then mv $HT/sfvtrace.txt $HT/sfvtrace_cycle1.txt; fi
if [ -f $HT/illtrace.txt ]; then mv $HT/illtrace.txt $HT/illtrace_cycle1.txt; fi
if grep -q 'ev=FIRE' $HT/sptrace_cycle1.txt 2>/dev/null; then
  echo "cycle 1: SP CAPTURED (sptrace ev=FIRE present)" >> $LOGD/p25_driver.log
elif grep -q 'ev=CAPTURE' $HT/sfvtrace_cycle1.txt 2>/dev/null; then
  echo "cycle 1: SFV WATCHPOINT CAPTURED (backstop; sptrace did not fire — diagnose why)" >> $LOGD/p25_driver.log
elif grep -q 'exit=0x52535431' $L; then
  echo "cycle 1: guest SYSTEM_RESET with NO capture — diagnose from boot log, do not re-run blindly" >> $LOGD/p25_driver.log
else
  echo "cycle 1: non-reset exit with NO capture — diagnose from boot log, do not re-run blindly" >> $LOGD/p25_driver.log
fi
echo "driver finished $(date '+%F %T %Z')" >> $LOGD/p25_driver.log
