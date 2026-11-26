#!/bin/bash
F=$HOME/retasuvm/inst/imagetest/src_p29/ARM64CPU.swift
echo "=== lines 75-112 (p27 top block) ==="
sed -n '75,112p' $F
echo "=== lines 672,690 (step start) ==="
sed -n '672,690p' $F
echo "=== lines 1297,1340 (p27 helper) ==="
sed -n '1297,1340p' $F
