#!/bin/bash
# Phase 29: wqthread SP-install capture on the p28 (monotonic-clock fixed)
# engine. ONE cycle only.
# - WQTRACE=1: kext _workq_set_register_state SP-store watchpoint
#   (slid 0xfffffe0022534bcc, STP x8, x21, [sp, #0x118], word 0xA911D7E8).
#   Logs every wqthread __sp install with TTBR0 for process attribution.
# - P27TRACE=1: bsdthread_create installs (comparison, as p28).
# - TIMEWATCH=1, SFVTRACE / ILLTRACE backstops on, SPTRACE off (as p28).
HT=$HOME/retasuvm/inst/imagetest/home_p30
LOGD=$HOME/retasuvm/tests/logs
BIN=$HOME/retasuvm/inst/imagetest/build/h_rom_img_p30
ROM=$HOME/retasuvm/bootrom/AVPBooter.vmapple2.bin
mkdir -p $LOGD
echo "p30 binary: $(ls -la $BIN 2>/dev/null | awk '{print $6, $7, $8, $9}'), errors in build log: $(grep -c 'error:' /tmp/build_p30.log 2>/dev/null), now: $(date '+%F %T %Z')" >> $LOGD/p30_driver.log
L=$LOGD/boot_p30_cycle1.log
echo "=== cycle 1 start $(date '+%F %T %Z') ===" >> $LOGD/p30_driver.log
(cd $HT && HOME=$HT FAST=1 TIMESCALE=0.1 WATCH=1 NOBSDMGROOT=1 ILLTRACE=1 SFVTRACE=1 P27TRACE=1 TIMEWATCH=1 WQTRACE=1 VMAPPLE_ECID=17184306859705076658 $BIN $ROM 4096 12000 0 > $L 2>&1)
echo "=== cycle 1 end $(date '+%F %T %Z') ===" >> $LOGD/p30_driver.log
grep -m1 '\[romboot\] done' $L >> $LOGD/p30_driver.log
if [ -f $HT/dram_fpend.bin ]; then mv $HT/dram_fpend.bin $HT/dram_fpend_cycle1.bin; fi
if [ -f $HT/wqtrace.txt ]; then mv $HT/wqtrace.txt $HT/wqtrace_cycle1.txt; fi
if [ -f $HT/p27trace.txt ]; then mv $HT/p27trace.txt $HT/p27trace_cycle1.txt; fi
if [ -f $HT/timewatch.txt ]; then mv $HT/timewatch.txt $HT/timewatch_cycle1.txt; fi
if [ -f $HT/sfvtrace.txt ]; then mv $HT/sfvtrace.txt $HT/sfvtrace_cycle1.txt; fi
if [ -f $HT/illtrace.txt ]; then mv $HT/illtrace.txt $HT/illtrace_cycle1.txt; fi
if [ -f $HT/wqtrace_cycle1.txt ]; then
  echo "cycle 1: wqtrace installs=$(grep -c 'ev=INSTALL' $HT/wqtrace_cycle1.txt), misaligned=$(grep -c 'mis=1' $HT/wqtrace_cycle1.txt), wordcheck=$(grep -c 'ev=WORD-CHECK' $HT/wqtrace_cycle1.txt), mismatch=$(grep -c 'ev=PC-MISMATCH' $HT/wqtrace_cycle1.txt)" >> $LOGD/p30_driver.log
else
  echo "cycle 1: NO wqtrace file (kext wq SP store never executed — diagnose from boot log)" >> $LOGD/p30_driver.log
fi
if [ -f $HT/p27trace_cycle1.txt ]; then
  echo "cycle 1: p27trace installs=$(grep -c 'ev=INSTALL' $HT/p27trace_cycle1.txt), misaligned=$(grep -c 'mis=1' $HT/p27trace_cycle1.txt), wordcheck=$(grep -c 'ev=WORD-CHECK' $HT/p27trace_cycle1.txt), mismatch=$(grep -c 'ev=PC-MISMATCH' $HT/p27trace_cycle1.txt)" >> $LOGD/p30_driver.log
else
  echo "cycle 1: NO p27trace file (kext SP store never executed — diagnose from boot log)" >> $LOGD/p30_driver.log
fi
if [ -f $HT/timewatch_cycle1.txt ]; then
  echo "cycle 1: timewatch rewinds=$(grep -c 'ev=REWIND' $HT/timewatch_cycle1.txt), divergeSnapshots=$(grep -c 'ev=DIVERGE' $HT/timewatch_cycle1.txt)" >> $LOGD/p30_driver.log
else
  echo "cycle 1: NO timewatch file (counterValue never called?? — diagnose)" >> $LOGD/p30_driver.log
fi
if grep -q 'Non-monotonic time' $L; then
  echo "cycle 1: NON-MONOTONIC PANIC RECURRED despite the fix — attribution falsified, diagnose" >> $LOGD/p30_driver.log
fi
if grep -q 'ev=CAPTURE' $HT/sfvtrace_cycle1.txt 2>/dev/null; then
  echo "cycle 1: SFV WATCHPOINT CAPTURED (spin reached; backstop fired)" >> $LOGD/p30_driver.log
elif grep -q 'exit=0x52535431' $L; then
  echo "cycle 1: guest SYSTEM_RESET — diagnose from boot log, do not re-run blindly" >> $LOGD/p30_driver.log
else
  echo "cycle 1: non-reset exit — diagnose from boot log, do not re-run blindly" >> $LOGD/p30_driver.log
fi
echo "driver finished $(date '+%F %T %Z')" >> $LOGD/p30_driver.log
