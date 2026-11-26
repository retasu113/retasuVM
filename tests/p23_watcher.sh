#!/bin/bash
# Phase 20: watch for p23 cycle 1 to end, then record the verification verdict.
# Runs detached on the PC; polls every 10 min. Never touches any boot process.
LOGD=$HOME/retasuvm/tests/logs
IT=$HOME/retasuvm/inst/imagetest
HB=$LOGD/p23_watch_hb.txt
DONE=$LOGD/p23_watch_done.txt
echo "p23_watcher started $(date '+%F %T %Z')" > $HB
i=0
while true; do
  i=$((i+1))
  echo "iter=$i $(date '+%F %T %Z')" > $HB
  if grep -q "cycle 1 end" $LOGD/p23_driver.log 2>/dev/null; then
    break
  fi
  sleep 600
done
{
  echo "p23 cycle 1 ended $(date '+%F %T %Z')"
  echo "--- driver log ---"
  grep -E "cycle 1|romboot|binary" $LOGD/p23_driver.log
  echo "--- boot log: fsck exit line? ---"
  grep -m2 "fsck\[2\] exited" $LOGD/boot_p23_cycle1.log || echo "NO fsck-exit panic line"
  echo "--- boot log: panic line? ---"
  grep -m2 "^panic" $LOGD/boot_p23_cycle1.log || grep -m2 "panic(" $LOGD/boot_p23_cycle1.log || echo "NO panic line"
  echo "--- boot log: fsck output lines (first 5)? ---"
  grep -i "fsck" $LOGD/boot_p23_cycle1.log | head -5
  echo "--- illtrace_cycle1.txt ---"
  if [ -f $IT/home_p23/illtrace_cycle1.txt ]; then cat $IT/home_p23/illtrace_cycle1.txt; else echo "NO illtrace file (no EC 0x00 raised in cycle 1)"; fi
  echo "--- boot log tail ---"
  tail -5 $LOGD/boot_p23_cycle1.log
} > $DONE
echo "p23_watcher done $(date '+%F %T %Z')" >> $HB
