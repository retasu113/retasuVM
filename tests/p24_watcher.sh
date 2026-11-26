#!/bin/bash
# Phase 23: watch for the p24 driver to finish (cycle 1), then record the
# watchpoint-capture verdict. Runs detached on the PC; polls every 10 min.
# Never touches any boot process.
LOGD=$HOME/retasuvm/tests/logs
IT=$HOME/retasuvm/inst/imagetest
HB=$LOGD/p24_watch_hb.txt
DONE=$LOGD/p24_watch_done.txt
echo "p24_watcher started $(date '+%F %T %Z')" > $HB
i=0
while true; do
  i=$((i+1))
  echo "iter=$i $(date '+%F %T %Z')" > $HB
  if grep -q "cycle 1 end" $LOGD/p24_driver.log 2>/dev/null; then
    break
  fi
  sleep 600
done
{
  echo "p24 cycle 1 ended $(date '+%F %T %Z')"
  echo "--- driver log ---"
  grep -E "cycle 1|romboot|binary|CAPTURE|SYSTEM_RESET|diagnose" $LOGD/p24_driver.log
  echo "--- sfvtrace capture (whole file) ---"
  if [ -f $IT/home_p24/sfvtrace_cycle1.txt ]; then cat $IT/home_p24/sfvtrace_cycle1.txt; else echo "NO sfvtrace file (watchpoint never fired)"; fi
  echo "--- boot log: panic line? ---"
  grep -m2 "^panic" $LOGD/boot_p24_cycle1.log || grep -m2 "panic(" $LOGD/boot_p24_cycle1.log || echo "NO panic line"
  echo "--- boot log: userspace boot reached? ---"
  grep -m1 "userspace boot" $LOGD/boot_p24_cycle1.log || echo "NO userspace boot line"
  echo "--- boot log tail ---"
  tail -5 $LOGD/boot_p24_cycle1.log
} > $DONE
echo "p24_watcher done $(date '+%F %T %Z')" >> $HB
