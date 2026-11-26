#!/bin/bash
# Phase 23: build src_p24 and report error count + binary timestamp + time.
cd /home/retasu/retasuvm/inst/imagetest
/home/retasu/swift-toolchain/swift-5.10.1-RELEASE-ubuntu24.04/usr/bin/swiftc -O -o build/h_rom_img_p24 src_p24/*.swift > /tmp/build_p24.log 2>&1
ec=$?
echo "swiftc exit=$ec"
echo "errors=$(grep -c 'error:' /tmp/build_p24.log)"
echo "warnings=$(grep -c 'warning:' /tmp/build_p24.log)"
ls -la build/h_rom_img_p24
date '+now: %F %T %Z'
