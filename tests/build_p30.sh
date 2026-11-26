#!/bin/bash
# Phase 29: build src_p30 and report error count + binary timestamp + time.
cd /home/retasu/retasuvm/inst/imagetest
/home/retasu/swift-toolchain/swift-5.10.1-RELEASE-ubuntu24.04/usr/bin/swiftc -O -o build/h_rom_img_p30 src_p30/*.swift > /tmp/build_p30.log 2>&1
ec=$?
echo "swiftc exit=$ec"
echo "errors=$(grep -c 'error:' /tmp/build_p30.log)"
echo "warnings=$(grep -c 'warning:' /tmp/build_p30.log)"
ls -la build/h_rom_img_p30
date '+now: %F %T %Z'
