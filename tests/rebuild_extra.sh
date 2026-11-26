#!/bin/bash
export PATH=~/workspace/swift-toolchain/swift-5.10.1-RELEASE-ubuntu24.04/usr/bin:$PATH
cd ~/workspace/retasuvm/tests || exit 1
R=../repo/retasuVM.swiftpm
E=$R/Engine
for h in mb mb2 crypto lzfse mac macguest arm64asm adtcheck dbg dbguefi micro simd; do
  out="h_$h"
  swiftc -O -o "$out" $E/*.swift $R/Models/VirtualMachine.swift $h/main.swift 2>/tmp/build_$h.log
  echo "$h rc=$? errors=$(grep -c 'error:' /tmp/build_$h.log)"
done
echo EXTRA_BUILDS_DONE
