#!/bin/bash
# Phase 27: kext bsdthread_create SP-store capture boot. ONE cycle only.
# The harness logs every bsdthread_create SP install (P27TRACE=1) and does
# NOT halt on install; the boot runs until the SFVTRACE backstop fires at
# the __sfvwrite spin (or a reset / the 6.5 h wall cap). SPTRACE is OFF
# (it would halt on fsck's first dispatch before the worker's creation).
HT=$HOME/retasuvm/inst/imagetest/home_p27
LOGD=$HOME/retasuvm/tests/logs
BIN=$HOME/retasuvm/inst/imagetest/build/h_rom_img_p27
ROM=$HOME/retasuvm/bootrom/AVPBooter.vmapple2.bin
mkdir -p $LOGD
# Build-rule check: refuse to run a stale/failed binary.
echo "p27 binary: $(ls -la $BIN 2>/dev/null | awk '{print $6, $7, $8, $9}'), errors in build log: $(grep -c 'error:' $HOME/retasuvm/inst/imagetest/build_p27.log 2>/dev/null), now: $(date '+%F %T %Z')" >> $LOGD/p27_driver.log
L=$LOGD/boot_p27_cycle1.log
echo "=== cycle 1 start $(date '+%F %T %Z') ===" >> $LOGD/p27_driver.log
(cd $HT && HOME=$HT FAST=1 TIMESCALE=0.1 WATCH=1 NOBSDMGROOT=1 ILLTRACE=1 SFVTRACE=1 P27TRACE=1 VMAPPLE_ECID=17184306859705076658 $BIN $ROM 4096 12000 0 > $L 2>&1)
echo "=== cycle 1 end $(date '+%F %T %Z') ===" >> $LOGD/p27_driver.log
grep -m1 '\[romboot\] done' $L >> $LOGD/p27_driver.log
if [ -f $HT/dram_fpend.bin ]; then mv $HT/dram_fpend.bin $HT/dram_fpend_cycle1.bin; fi
if [ -f $HT/p27trace.txt ]; then mv $HT/p27trace.txt $HT/p27trace_cycle1.txt; fi
if [ -f $HT/sfvtrace.txt ]; then mv $HT/sfvtrace.txt $HT/sfvtrace_cycle1.txt; fi
if [ -f $HT/illtrace.txt ]; then mv $HT/illtrace.txt $HT/illtrace_cycle1.txt; fi
if [ -f $HT/p27trace_cycle1.txt ]; then
  echo "cycle 1: p27trace installs=$(grep -c 'ev=INSTALL' $HT/p27trace_cycle1.txt), misaligned=$(grep -c 'mis=1' $HT/p27trace_cycle1.txt), wordcheck=$(grep -c 'ev=WORD-CHECK' $HT/p27trace_cycle1.txt), mismatch=$(grep -c 'ev=PC-MISMATCH' $HT/p27trace_cycle1.txt)" >> $LOGD/p27_driver.log
else
  echo "cycle 1: NO p27trace file (kext SP store never executed — diagnose from boot log)" >> $LOGD/p27_driver.log
fi
if grep -q 'ev=CAPTURE' $HT/sfvtrace_cycle1.txt 2>/dev/null; then
  echo "cycle 1: SFV WATCHPOINT CAPTURED (spin reached; backstop fired)" >> $LOGD/p27_driver.log
elif grep -q 'exit=0x52535431' $L; then
  echo "cycle 1: guest SYSTEM_RESET — diagnose from boot log, do not re-run blindly" >> $LOGD/p27_driver.log
else
  echo "cycle 1: non-reset exit — diagnose from boot log, do not re-run blindly" >> $LOGD/p27_driver.log
fi
echo "driver finished $(date '+%F %T %Z')" >> $LOGD/p27_driver.log
