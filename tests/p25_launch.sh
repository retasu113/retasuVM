#!/bin/bash
# Phase 25: launch the p25 driver + watcher detached on the PC.
# Records both PIDs. Never touches the restore supervisor or any other boot.
LOGD=/home/retasu/retasuvm/tests/logs
IT=/home/retasu/retasuvm/inst/imagetest
# Pre-flight: home_p25 disks must exist (fresh golden copies).
if [ ! -f $IT/home_p25/workspace/retasuvm/disks/root.img ]; then
  echo "ERROR: home_p25 disks missing; NOT starting p25 driver" >> $LOGD/p25_launcher.log
  exit 1
fi
md5sum $IT/home_p25/workspace/retasuvm/disks/aux.img >> $LOGD/p25_launcher.log
echo "p25 launcher: aux md5 (expect 6be363a954a3083e10b87311eaf657f4) above; starting driver $(date '+%F %T %Z')" >> $LOGD/p25_launcher.log
nohup bash $IT/p25_driver.sh > $LOGD/p25_driver_stdout.log 2>&1 &
echo "p25 driver pid $! started $(date '+%F %T %Z')" >> $LOGD/p25_launcher.log
nohup bash $IT/p25_watcher.sh > $LOGD/p25_watcher_stdout.log 2>&1 &
echo "p25 watcher pid $! started $(date '+%F %T %Z')" >> $LOGD/p25_launcher.log
echo "p25 launch done $(date '+%F %T %Z')" >> $LOGD/p25_launcher.log
cat $LOGD/p25_launcher.log
