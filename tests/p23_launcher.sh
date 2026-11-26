#!/bin/bash
# Phase 20: wait for the p22 driver to finish (cycle 2), then start the p23 driver.
# Runs detached on the PC; polls every 60 s. Never touches the p22 processes.
LOGD=$HOME/retasuvm/tests/logs
IT=$HOME/retasuvm/inst/imagetest
echo "p23_launcher started $(date '+%F %T %Z'), waiting for p22 driver to finish" >> $LOGD/p23_launcher.log
while true; do
  if grep -q "driver finished" $LOGD/p22_driver.log 2>/dev/null; then
    echo "p22 driver finished at $(date '+%F %T %Z'); starting p23 driver" >> $LOGD/p23_launcher.log
    break
  fi
  # Safety: if pid 84828 is gone AND the p22 driver log shows cycle 2 ended, also proceed.
  if ! kill -0 84828 2>/dev/null && grep -q "cycle 2 end" $LOGD/p22_driver.log 2>/dev/null; then
    sleep 60
    echo "p22 pid gone + cycle 2 ended at $(date '+%F %T %Z'); starting p23 driver" >> $LOGD/p23_launcher.log
    break
  fi
  sleep 60
done
# Fresh golden-copy check: home_p23 disks must exist (created by the parent before launching).
if [ ! -f $IT/home_p23/workspace/retasuvm/disks/root.img ]; then
  echo "ERROR: home_p23 disks missing; NOT starting p23 driver" >> $LOGD/p23_launcher.log
  exit 1
fi
md5sum $IT/home_p23/workspace/retasuvm/disks/aux.img >> $LOGD/p23_launcher.log
nohup bash $IT/p23_driver.sh > $LOGD/p23_driver_stdout.log 2>&1 &
echo "p23 driver pid $! started $(date '+%F %T %Z')" >> $LOGD/p23_launcher.log
