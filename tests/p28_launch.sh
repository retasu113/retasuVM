#!/bin/bash
# Phase 28: launch the p28 driver + watcher detached on the PC.
# Records both PIDs. Never touches the restore supervisor or any other boot.
LOGD=/home/retasu/retasuvm/tests/logs
IT=/home/retasu/retasuvm/inst/imagetest
if [ ! -f $IT/home_p28/workspace/retasuvm/disks/root.img ]; then
  echo "ERROR: home_p28 disks missing; NOT starting p28 driver" >> $LOGD/p28_launcher.log
  exit 1
fi
md5sum $IT/home_p28/workspace/retasuvm/disks/aux.img >> $LOGD/p28_launcher.log
echo "p28 launcher: aux md5 (expect 6be363a954a3083e10b87311eaf657f4) above; starting driver $(date '+%F %T %Z')" >> $LOGD/p28_launcher.log
nohup bash $IT/p28_driver.sh > $LOGD/p28_driver_stdout.log 2>&1 &
echo "p28 driver pid $! started $(date '+%F %T %Z')" >> $LOGD/p28_launcher.log
nohup bash $IT/p28_watcher.sh > $LOGD/p28_watcher_stdout.log 2>&1 &
echo "p28 watcher pid $! started $(date '+%F %T %Z')" >> $LOGD/p28_launcher.log
echo "p28 launch done $(date '+%F %T %Z')" >> $LOGD/p28_launcher.log
cat $LOGD/p28_launcher.log
