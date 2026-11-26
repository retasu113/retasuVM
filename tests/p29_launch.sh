#!/bin/bash
# Phase 29: launch the p29 driver + watcher detached on the PC.
# Records both PIDs. Never touches the restore supervisor or any other boot.
LOGD=/home/retasu/retasuvm/tests/logs
IT=/home/retasu/retasuvm/inst/imagetest
if [ ! -f $IT/home_p29/workspace/retasuvm/disks/root.img ]; then
  echo "ERROR: home_p29 disks missing; NOT starting p29 driver" >> $LOGD/p29_launcher.log
  exit 1
fi
md5sum $IT/home_p29/workspace/retasuvm/disks/aux.img >> $LOGD/p29_launcher.log
echo "p29 launcher: aux md5 (expect 6be363a954a3083e10b87311eaf657f4) above; starting driver $(date '+%F %T %Z')" >> $LOGD/p29_launcher.log
nohup bash $IT/p29_driver.sh > $LOGD/p29_driver_stdout.log 2>&1 &
echo "p29 driver pid $! started $(date '+%F %T %Z')" >> $LOGD/p29_launcher.log
nohup bash $IT/p29_watcher.sh > $LOGD/p29_watcher_stdout.log 2>&1 &
echo "p29 watcher pid $! started $(date '+%F %T %Z')" >> $LOGD/p29_launcher.log
echo "p29 launch done $(date '+%F %T %Z')" >> $LOGD/p29_launcher.log
cat $LOGD/p29_launcher.log
