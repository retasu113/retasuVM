#!/bin/bash
# First restore attempt: harness (bridge mode, FAST) + restore client.
# Usage: run_restore.sh [maxM]   (maxM = harness instruction budget in millions)
set -u
cd ~/workspace/retasuvm
MAXM=${1:-4000}
SOCK=/tmp/retasuvm_vusb.sock
rm -f $SOCK
mkdir -p restore/work
echo "== starting harness (maxM=$MAXM)"
FAST=1 VUSB_SOCK=$SOCK ./tests/h_rom bootrom/AVPBooter.vmapple2.bin 2048 $MAXM 1 \
  > tests/logs/restore_harness_out.log 2> tests/logs/restore_harness.log &
HPID=$!
sleep 2
echo "== starting restore client"
HV_INSTALL_LOG=1 HV_VUSB_LOG=1 ./restore/build/restore $SOCK \
  ~/workspace/retasuvm/ipsw15/sequoia_15.6.1.ipsw \
  ~/workspace/retasuvm/restore/work \
  0x0001020304050607 > tests/logs/restore_client.log 2>&1 &
CPID=$!
echo "harness pid $HPID, client pid $CPID"
wait $CPID
echo "== client exited rc=$?"
kill $HPID 2>/dev/null
wait $HPID 2>/dev/null
echo "== done"
