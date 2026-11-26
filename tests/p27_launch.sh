#!/bin/bash
# Phase 27: launch the p27 driver + watcher detached on the PC.
# Records both PIDs. Never touches the restore supervisor or any other boot.
LOGD=/home/retasu/retasuvm/tests/logs
IT=/home/retasu/retasuvm/inst/imagetest
# Pre-flight: home_p27 disks must exist (fresh golden copies).
if [ ! -f $IT/home_p27/workspace/retasuvm/disks/root.img ]; then
  echo "ERROR: home_p27 disks missing; NOT starting p27 driver" >> $LOGD/p27_launcher.log
  exit 1
fi
md5sum $IT/home_p27/workspace/retasuvm/disks/aux.img >> $LOGD/p27_launcher.log
echo "p27 launcher: aux md5 (expect 6be363a954a3083e10b87311eaf657f4) above; starting driver $(date '+%F %T %Z')" >> $LOGD/p27_launcher.log
nohup bash $IT/p27_driver.sh > $LOGD/p27_driver_stdout.log 2>&1 &
echo "p27 driver pid $! started $(date '+%F %T %Z')" >> $LOGD/p27_launcher.log
nohup bash $IT/p27_watcher.sh > $LOGD/p27_watcher_stdout.log 2>&1 &
echo "p27 watcher pid $! started $(date '+%F %T %Z')" >> $LOGD/p27_launcher.log
echo "p27 launch done $(date '+%F %T %Z')" >> $LOGD/p27_launcher.log
cat $LOGD/p27_launcher.log
