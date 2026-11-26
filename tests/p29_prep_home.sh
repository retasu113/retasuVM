#!/bin/bash
# Phase 29: prepare home_p29 with fresh golden copies (sparse cp).
IT=$HOME/retasuvm/inst/imagetest
HT=$IT/home_p29
mkdir -p $HT/workspace/retasuvm/disks
cp --sparse=always $IT/images/disk.raw $HT/workspace/retasuvm/disks/root.img
cp --sparse=always $IT/images/aux.img $HT/workspace/retasuvm/disks/aux.img
ls -la $HT/workspace/retasuvm/disks/
echo "copy aux md5:"; md5sum $HT/workspace/retasuvm/disks/aux.img
echo "golden aux md5:"; md5sum $IT/images/aux.img
du -sh $HT
df -h / | tail -1
date '+now: %F %T %Z'
