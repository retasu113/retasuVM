#!/bin/bash
# Phase 29: launch the p30 driver + watcher detached on the PC.
# Records both PIDs. Never touches the restore supervisor or any other boot.
LOGD=/home/retasu/retasuvm/tests/logs
IT=/home/retasu/retasuvm/inst/imagetest
if [ ! -f $IT/home_p30/workspace/retasuvm/disks/root.img ]; then
  echo "ERROR: home_p30 disks missing; NOT starting p30 driver" >> $LOGD/p30_launcher.log
  exit 1
fi
md5sum $IT/home_p30/workspace/retasuvm/disks/aux.img >> $LOGD/p30_launcher.log
echo "p30 launcher: aux md5 (expect 6be363a954a3083e10b87311eaf657f4) above; starting driver $(date '+%F %T %Z')" >> $LOGD/p30_launcher.log
nohup bash $IT/p30_driver.sh > $LOGD/p30_driver_stdout.log 2>&1 &
echo "p30 driver pid $! started $(date '+%F %T %Z')" >> $LOGD/p30_launcher.log
nohup bash $IT/p30_watcher.sh > $LOGD/p30_watcher_stdout.log 2>&1 &
echo "p30 watcher pid $! started $(date '+%F %T %Z')" >> $LOGD/p30_launcher.log
echo "p30 launch done $(date '+%F %T %Z')" >> $LOGD/p30_launcher.log
cat $LOGD/p30_launcher.log
