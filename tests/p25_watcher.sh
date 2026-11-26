#!/bin/bash
# Phase 25: watch for the p25 driver to finish (cycle 1), then record the
# SP-capture verdict. Runs detached on the PC; polls every 10 min.
# Never touches any boot process.
LOGD=$HOME/retasuvm/tests/logs
IT=$HOME/retasuvm/inst/imagetest
HB=$LOGD/p25_watch_hb.txt
DONE=$LOGD/p25_watch_done.txt
echo "p25_watcher started $(date '+%F %T %Z')" > $HB
i=0
while true; do
  i=$((i+1))
  echo "iter=$i $(date '+%F %T %Z')" > $HB
  if grep -q "cycle 1 end" $LOGD/p25_driver.log 2>/dev/null; then
    break
  fi
  sleep 600
done
{
  echo "p25 cycle 1 ended $(date '+%F %T %Z')"
  echo "--- driver log ---"
  grep -E "cycle 1|romboot|binary|CAPTURED|SYSTEM_RESET|diagnose" $LOGD/p25_driver.log
  echo "--- sptrace capture (whole file) ---"
  if [ -f $IT/home_p25/sptrace_cycle1.txt ]; then cat $IT/home_p25/sptrace_cycle1.txt; else echo "NO sptrace file (SP logger never fired)"; fi
  echo "--- sfvtrace (backstop) ---"
  if [ -f $IT/home_p25/sfvtrace_cycle1.txt ]; then tail -3 $IT/home_p25/sfvtrace_cycle1.txt; else echo "NO sfvtrace file"; fi
  echo "--- boot log: panic line? ---"
  grep -m2 "^panic" $LOGD/boot_p25_cycle1.log || grep -m2 "panic(" $LOGD/boot_p25_cycle1.log || echo "NO panic line"
  echo "--- boot log: userspace boot reached? ---"
  grep -m1 "userspace boot" $LOGD/boot_p25_cycle1.log || echo "NO userspace boot line"
  echo "--- boot log tail ---"
  tail -5 $LOGD/boot_p25_cycle1.log
} > $DONE
echo "p25_watcher done $(date '+%F %T %Z')" >> $HB
