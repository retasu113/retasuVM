#!/bin/bash
# Phase 29: create src_p29 from src_p28 and show patch anchors.
IT=$HOME/retasuvm/inst/imagetest
if [ ! -d $IT/src_p29 ]; then cp -r $IT/src_p28 $IT/src_p29; fi
ls $IT/src_p29
F=$IT/src_p29/ARM64CPU.swift
echo "=== p27Log func ==="
grep -n "func p27Log" $F
echo "=== p27 step-start check ==="
grep -n "p27KextSpCheck(instructionPC" $F
grep -n "if p27TraceEnabled" $F
echo "=== p27KextSpCheck def/end ==="
grep -n "func p27KextSpCheck" $F
echo "=== p25SpPeekWord ==="
grep -n "func p25SpPeekWord" $F
echo "=== files in src_p29 ==="
wc -l $IT/src_p29/*.swift
