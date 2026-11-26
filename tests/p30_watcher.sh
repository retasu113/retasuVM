#!/bin/bash
# Phase 29: watch for the p30 driver to finish (cycle 1), then record the
# verdict: (a) wqtrace installs + any misaligned + word check,
# (b) p27trace comparison, (c) SFV backstop capture, (d) panic check.
# Polls every 10 min. Never touches any boot process.
LOGD=$HOME/retasuvm/tests/logs
IT=$HOME/retasuvm/inst/imagetest
HB=$LOGD/p30_watch_hb.txt
DONE=$LOGD/p30_watch_done.txt
echo "p30_watcher started $(date '+%F %T %Z')" > $HB
i=0
while true; do
  i=$((i+1))
  echo "iter=$i $(date '+%F %T %Z')" > $HB
  if grep -q "cycle 1 end" $LOGD/p30_driver.log 2>/dev/null; then
    break
  fi
  sleep 600
done
{
  echo "p30 cycle 1 ended $(date '+%F %T %Z')"
  echo "--- driver log ---"
  grep -E "cycle 1|romboot|binary|CAPTURED|SYSTEM_RESET|diagnose|NO wqtrace|NO p27trace|NON-MONOTONIC" $LOGD/p30_driver.log
  echo "--- Non-monotonic panic in boot log? ---"
  grep -m2 "Non-monotonic time" $LOGD/boot_p30_cycle1.log || echo "NO Non-monotonic panic"
  echo "--- wqtrace: word check ---"
  if [ -f $IT/home_p30/wqtrace_cycle1.txt ]; then grep 'ev=WORD-CHECK\|ev=PC-MISMATCH' $IT/home_p30/wqtrace_cycle1.txt; else echo "NO wqtrace file"; fi
  echo "--- wqtrace: counts ---"
  if [ -f $IT/home_p30/wqtrace_cycle1.txt ]; then echo "installs=$(grep -c 'ev=INSTALL' $IT/home_p30/wqtrace_cycle1.txt) misaligned=$(grep -c 'mis=1' $IT/home_p30/wqtrace_cycle1.txt)"; fi
  echo "--- wqtrace: misaligned installs (whole lines) ---"
  if [ -f $IT/home_p30/wqtrace_cycle1.txt ]; then grep 'mis=1' $IT/home_p30/wqtrace_cycle1.txt || echo "NONE misaligned"; fi
  echo "--- wqtrace: first 5 installs ---"
  if [ -f $IT/home_p30/wqtrace_cycle1.txt ]; then grep 'ev=INSTALL' $IT/home_p30/wqtrace_cycle1.txt | head -5; fi
  echo "--- wqtrace: distinct ttbr0el1 values ---"
  if [ -f $IT/home_p30/wqtrace_cycle1.txt ]; then grep 'ev=INSTALL' $IT/home_p30/wqtrace_cycle1.txt | sed 's/.*ttbr0el1=0x\([0-9a-f]*\).*/\1/' | sort | uniq -c; fi
  echo "--- p27trace: counts ---"
  if [ -f $IT/home_p30/p27trace_cycle1.txt ]; then echo "installs=$(grep -c 'ev=INSTALL' $IT/home_p30/p27trace_cycle1.txt) misaligned=$(grep -c 'mis=1' $IT/home_p30/p27trace_cycle1.txt)"; fi
  echo "--- sfvtrace (backstop) ---"
  if [ -f $IT/home_p30/sfvtrace_cycle1.txt ]; then tail -3 $IT/home_p30/sfvtrace_cycle1.txt; else echo "NO sfvtrace file"; fi
  echo "--- p30 KEY QUESTION: did the __sfvwrite spin still occur? ---"
  if [ -f $IT/home_p30/sfvtrace_cycle1.txt ] && grep -q 'ev=CAPTURE' $IT/home_p30/sfvtrace_cycle1.txt; then
    echo "SFV CAPTURE FIRED: spin STILL occurs despite the #31 fix — diagnose"
  else
    echo "NO SFV CAPTURE: the __sfvwrite spin did NOT trigger the backstop in this run (fix effective at the spin point, or boot ended earlier — check romboot done line / instr count below)"
  fi
  echo "--- romboot done line (final instr count) ---"
  grep -m1 '\[romboot\] done' $LOGD/boot_p30_cycle1.log || echo "NO romboot done line"
  echo "--- boot log: panic line? ---"
  grep -m2 "^panic" $LOGD/boot_p30_cycle1.log || grep -m2 "panic(" $LOGD/boot_p30_cycle1.log || echo "NO panic line"
  echo "--- boot log: userspace boot reached? ---"
  grep -m1 "userspace boot" $LOGD/boot_p30_cycle1.log || echo "NO userspace boot line"
  echo "--- boot log tail ---"
  tail -5 $LOGD/boot_p30_cycle1.log
} > $DONE
echo "p30_watcher done $(date '+%F %T %Z')" >> $HB
