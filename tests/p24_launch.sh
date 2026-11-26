#!/bin/bash
# Phase 23: launch the p24 driver + watcher detached on the PC.
# Records both PIDs. Never touches the restore supervisor or any other boot.
LOGD=/home/retasu/retasuvm/tests/logs
IT=/home/retasu/retasuvm/inst/imagetest
# Pre-flight: home_p24 disks must exist (fresh golden copies).
if [ ! -f $IT/home_p24/workspace/retasuvm/disks/root.img ]; then
  echo "ERROR: home_p24 disks missing; NOT starting p24 driver" >> $LOGD/p24_launcher.log
  exit 1
fi
md5sum $IT/home_p24/workspace/retasuvm/disks/aux.img >> $LOGD/p24_launcher.log
echo "p24 launcher: aux md5 (expect 6be363a954a3083e10b87311eaf657f4) above; starting driver $(date '+%F %T %Z')" >> $LOGD/p24_launcher.log
nohup bash $IT/p24_driver.sh > $LOGD/p24_driver_stdout.log 2>&1 &
echo "p24 driver pid $! started $(date '+%F %T %Z')" >> $LOGD/p24_launcher.log
nohup bash $IT/p24_watcher.sh > $LOGD/p24_watcher_stdout.log 2>&1 &
echo "p24 watcher pid $! started $(date '+%F %T %Z')" >> $LOGD/p24_launcher.log
echo "p24 launch done $(date '+%F %T %Z')" >> $LOGD/p24_launcher.log
cat $LOGD/p24_launcher.log
