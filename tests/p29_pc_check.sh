#!/bin/bash
# Phase 29: initial PC state check. Read-only.
IT=$HOME/retasuvm/inst/imagetest
echo "=== date ==="; date '+%F %T %Z'
echo "=== supervisor (DO NOT TOUCH) ==="
systemctl is-active retasuvm-restore.service
echo "=== src trees ==="
ls -d $IT/src_p* 2>/dev/null
echo "=== builds ==="
ls -la $IT/build/ | grep h_rom_img
echo "=== SPTRACE/P27TRACE/TIMEWATCH presence in src_p28/ARM64CPU.swift ==="
grep -c "SPTRACE\|p25SpTrace" $IT/src_p28/ARM64CPU.swift
grep -c "P27TRACE" $IT/src_p28/ARM64CPU.swift
grep -c "TIMEWATCH" $IT/src_p28/ARM64CPU.swift
grep -c "SFVTRACE" $IT/src_p28/ARM64CPU.swift
echo "=== golden aux md5 ==="
md5sum $IT/images/aux.img
echo "=== home trees ==="
ls -d $IT/home_* 2>/dev/null
echo "=== disk free ==="
df -h / | tail -1
echo "=== running harness/driver procs ==="
ps aux | grep -E "h_rom|driver|watcher" | grep -v grep | head
