#!/bin/bash
# Phase 29 housekeeping: delete home_p29 disk copies only; verify golden.
IT=$HOME/retasuvm/inst/imagetest
HT=$IT/home_p29
echo "before:"; du -sh $HT; df -h / | tail -1
rm -f $HT/workspace/retasuvm/disks/root.img $HT/workspace/retasuvm/disks/aux.img
echo "after delete:"; ls -la $HT; du -sh $HT
echo "golden aux md5:"; md5sum $IT/images/aux.img
echo "golden root size:"; ls -la $IT/images/
df -h / | tail -1
echo "supervisor:"; systemctl is-active retasuvm-restore.service
echo "watcher done file:"; ls -la $HOME/retasuvm/tests/logs/p29_watch_done.txt 2>/dev/null || echo "not yet (watcher polls 600s)"
date '+now: %F %T %Z'
