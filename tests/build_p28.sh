#!/bin/bash
# Phase 28: build src_p28 and report error count + binary timestamp + time.
cd /home/retasu/retasuvm/inst/imagetest
/home/retasu/swift-toolchain/swift-5.10.1-RELEASE-ubuntu24.04/usr/bin/swiftc -O -o build/h_rom_img_p28 src_p28/*.swift > /tmp/build_p28.log 2>&1
ec=$?
echo "swiftc exit=$ec"
echo "errors=$(grep -c 'error:' /tmp/build_p28.log)"
echo "warnings=$(grep -c 'warning:' /tmp/build_p28.log)"
ls -la build/h_rom_img_p28
date '+now: %F %T %Z'
