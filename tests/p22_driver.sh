#!/bin/bash
# Phase-20: ILLTRACE boot — catch the instruction that SIGILLs fsck. Max 2 cycles.
HT=$HOME/retasuvm/inst/imagetest/home_p22
LOGD=$HOME/retasuvm/tests/logs
BIN=$HOME/retasuvm/inst/imagetest/build/h_rom_img_p22
ROM=$HOME/retasuvm/bootrom/AVPBooter.vmapple2.bin
mkdir -p $LOGD
for cycle in 1 2; do
  L=$LOGD/boot_p22_cycle$cycle.log
  echo "=== cycle $cycle start $(date '+%F %T %Z') ===" >> $LOGD/p22_driver.log
  (cd $HT && HOME=$HT FAST=1 TIMESCALE=0.1 WATCH=1 NOBSDMGROOT=1 ILLTRACE=1 VMAPPLE_ECID=17184306859705076658 $BIN $ROM 4096 12000 0 > $L 2>&1)
  echo "=== cycle $cycle end $(date '+%F %T %Z') ===" >> $LOGD/p22_driver.log
  grep -m1 '\[romboot\] done' $L >> $LOGD/p22_driver.log
  if [ -f $HT/dram_fpend.bin ]; then mv $HT/dram_fpend.bin $HT/dram_fpend_cycle$cycle.bin; fi
  if [ -f $HT/illtrace.txt ]; then mv $HT/illtrace.txt $HT/illtrace_cycle$cycle.txt; fi
  if ! grep -q 'exit=0x52535431' $L; then echo "cycle $cycle: no SYSTEM_RESET exit; driver stops" >> $LOGD/p22_driver.log; break; fi
  echo "cycle $cycle: guest SYSTEM_RESET; relaunching on same disks" >> $LOGD/p22_driver.log
done
echo "driver finished $(date '+%F %T %Z')" >> $LOGD/p22_driver.log
