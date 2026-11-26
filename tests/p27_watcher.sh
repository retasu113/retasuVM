#!/bin/bash
# Phase 27: watch for the p27 driver to finish (cycle 1), then record the
# kext SP-store capture verdict. Runs detached on the PC; polls every 10 min.
# Never touches any boot process.
LOGD=$HOME/retasuvm/tests/logs
IT=$HOME/retasuvm/inst/imagetest
HB=$LOGD/p27_watch_hb.txt
DONE=$LOGD/p27_watch_done.txt
echo "p27_watcher started $(date '+%F %T %Z')" > $HB
i=0
while true; do
  i=$((i+1))
  echo "iter=$i $(date '+%F %T %Z')" > $HB
  if grep -q "cycle 1 end" $LOGD/p27_driver.log 2>/dev/null; then
    break
  fi
  sleep 600
done
{
  echo "p27 cycle 1 ended $(date '+%F %T %Z')"
  echo "--- driver log ---"
  grep -E "cycle 1|romboot|binary|CAPTURED|SYSTEM_RESET|diagnose|NO p27trace" $LOGD/p27_driver.log
  echo "--- p27trace: word check ---"
  if [ -f $IT/home_p27/p27trace_cycle1.txt ]; then grep 'ev=WORD-CHECK\|ev=PC-MISMATCH' $IT/home_p27/p27trace_cycle1.txt; else echo "NO p27trace file"; fi
  echo "--- p27trace: counts ---"
  if [ -f $IT/home_p27/p27trace_cycle1.txt ]; then echo "installs=$(grep -c 'ev=INSTALL' $IT/home_p27/p27trace_cycle1.txt) misaligned=$(grep -c 'mis=1' $IT/home_p27/p27trace_cycle1.txt)"; fi
  echo "--- p27trace: misaligned installs (whole lines) ---"
  if [ -f $IT/home_p27/p27trace_cycle1.txt ]; then grep 'mis=1' $IT/home_p27/p27trace_cycle1.txt || echo "NONE misaligned"; fi
  echo "--- p27trace: first 5 installs ---"
  if [ -f $IT/home_p27/p27trace_cycle1.txt ]; then grep 'ev=INSTALL' $IT/home_p27/p27trace_cycle1.txt | head -5; fi
  echo "--- sfvtrace (backstop) ---"
  if [ -f $IT/home_p27/sfvtrace_cycle1.txt ]; then tail -3 $IT/home_p27/sfvtrace_cycle1.txt; else echo "NO sfvtrace file"; fi
  echo "--- boot log: panic line? ---"
  grep -m2 "^panic" $LOGD/boot_p27_cycle1.log || grep -m2 "panic(" $LOGD/boot_p27_cycle1.log || echo "NO panic line"
  echo "--- boot log: userspace boot reached? ---"
  grep -m1 "userspace boot" $LOGD/boot_p27_cycle1.log || echo "NO userspace boot line"
  echo "--- boot log tail ---"
  tail -5 $LOGD/boot_p27_cycle1.log
} > $DONE
echo "p27_watcher done $(date '+%F %T %Z')" >> $HB
