#!/bin/bash
# Phase 29: apply WQTRACE patch to src_p29 and build.
IT=$HOME/retasuvm/inst/imagetest
cd $IT
python3 $HOME/retasuvm/tests/p29_wq_patch.py $IT/src_p29/ARM64CPU.swift
echo "patch exit=$?"
grep -c "WQTRACE" $IT/src_p29/ARM64CPU.swift
bash $IT/build_p29.sh
