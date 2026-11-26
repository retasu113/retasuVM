#!/bin/bash
# supervise_restore_multi.sh — parameterized sibling-instance supervisor.
# Runs one extra restore cycle (Tahoe / Golden Gate) alongside the main
# Sequoia supervisor (supervise_restore_pc.sh) without interfering with it:
#  - per-instance socket, logs, workdir, DONE marker
#  - per-instance COPIES of the harness/client binaries under different
#    names, so the main supervisor's pkill lines can never match them
#  - NO pkill cleanup here (would kill siblings); systemd
#    KillMode=control-group owns teardown.
# Required env: RB_TAG, RB_IPSW (absolute path), RB_DONE (marker filename
# in restore/, e.g. DONE_26.6.2).
# Completion marker: restore/$RB_DONE (created when a client logs
# "finished with 0").
set -u
BASE=/home/retasu/retasuvm
TAG=${RB_TAG:?RB_TAG not set}
DONE=$BASE/restore/${RB_DONE:?RB_DONE not set}
IPSW=${RB_IPSW:?RB_IPSW not set}
INST=$BASE/inst/$TAG
SOCK=/tmp/retasuvm_vusb_$TAG.sock
WORK=$INST/work
LOGD=$INST/logs
HARNESS=$INST/h_rom_$TAG
CLIENT=$INST/restore_$TAG
ECID=0x0001020304050607
RUN=$(date +%Y%m%d-%H%M%S)
HLOG=$LOGD/supervise_harness_$RUN.log
mkdir -p "$LOGD" "$WORK"
log(){ echo "[supervise $(date '+%F %T')] $*" >> "$LOGD/supervise.log"; }

# --- Direct TSS reachability check (home network). The CA bundle adds the
# Apple Root CA, which Ubuntu's system bundle lacks (same fix as the VM). ---
check_net(){
  # NB: curl prints 000 on connection failure — that must NOT count as up.
  curl -s --cacert "$BASE/restore/ca_bundle.pem" --max-time 20 -o /dev/null -w "%{http_code}" "https://gs.apple.com/TSS/controller?action=2" 2>/dev/null | grep -qE "^[1-5][0-9][0-9]$"
}
ensure_net(){
  for i in $(seq 1 12); do
    if check_net; then return 0; fi
    sleep 5
  done
  log "network/TSS check FAILED"
  return 1
}

if [ -f "$DONE" ]; then log "already done, exiting"; exit 0; fi
[ -x "$HARNESS" ] || { log "harness copy $HARNESS missing/not executable"; exit 1; }
[ -x "$CLIENT" ] || { log "client copy $CLIENT missing/not executable"; exit 1; }
[ -f "$IPSW" ] || { log "IPSW $IPSW missing"; exit 1; }
log "cycle start run=$RUN tag=$TAG"

# No pkill cleanup: sibling instances must never be signalled. systemd
# KillMode=control-group tears this instance down as a unit.
rm -f "$SOCK"

# --- harness (guest); HOME points at the instance home so the harness's
# hardcoded $HOME/workspace/retasuvm/disks paths land on this instance's
# own fresh sparse disks. ---
HOME=$INST/home FAST=1 VUSB_SOCK=$SOCK "$HARNESS" "$BASE/bootrom/AVPBooter.vmapple2.bin" 2048 200000 1 >> "$HLOG" 2>&1 &
HPID=$!
log "harness pid $HPID log $HLOG"
sleep 20

# NB: run_client must NOT be invoked via $(...) — command substitution runs
# it in a subshell, so the backgrounded client is reparented to PID 1 and
# `wait` returns 127 instantly (2026-11-17: 15 orphan clients). Call it
# directly; it sets LAST_CLIENT_PID.
LAST_CLIENT_PID=""
run_client(){ # $1=logfile $2=nomux(1/0); sets LAST_CLIENT_PID
  local envs=(HV_INSTALL_LOG=1 HV_VUSB_LOG=1 HV_LIBUSB_LOG=1 HV_USB_OUT_CHUNK=262144 SSL_CERT_FILE=$BASE/restore/ca_bundle.pem CURL_CA_BUNDLE=$BASE/restore/ca_bundle.pem)
  [ "$2" = 1 ] && envs+=(HV_NO_MUX=1)
  env "${envs[@]}" "$CLIENT" "$SOCK" "$IPSW" "$WORK" "$ECID" >> "$1" 2>&1 &
  LAST_CLIENT_PID=$!
}

# --- client A: DFU -> iBSS ---
ensure_net || { log "no network; restarting cycle"; exit 1; }
ALOG=$LOGD/supervise_clientA_$RUN.log
run_client "$ALOG" 1; APID=$LAST_CLIENT_PID
log "client A pid $APID"
ok=0
for i in $(seq 1 120); do
  if grep -a -q "session=2" "$HLOG"; then ok=1; break; fi
  kill -0 $HPID 2>/dev/null || { log "harness died during A"; exit 1; }
  sleep 10
done
[ $ok = 1 ] || { log "no session=2 within 20 min; restarting cycle"; exit 1; }
log "session=2 seen; killing A, settle 120s"
kill $APID 2>/dev/null; sleep 2; kill -9 $APID 2>/dev/null
sleep 120

# --- client B: recovery -> LocalPolicy -> iBEC -> ramdisk -> bootx ---
ensure_net || log "WARNING: network check failed before client B"
BLOG=$LOGD/supervise_clientB_$RUN.log
run_client "$BLOG" 1; BPID=$LAST_CLIENT_PID
log "client B pid $BPID"
wait $BPID
log "client B exited rc=$?"
if grep -a -q "finished with 0" "$BLOG"; then touch "$DONE"; log "DONE via B"; exit 0; fi

# --- client C loop: mux-enabled, drives the restore OS / ASR phase ---
CLOG=$LOGD/supervise_clientC_$RUN.log
while [ ! -f "$DONE" ]; do
  kill -0 $HPID 2>/dev/null || { log "harness died during C"; exit 1; }
  ensure_net || log "WARNING: network check failed before client C"
  run_client "$CLOG" 0; CPID=$LAST_CLIENT_PID
  log "client C pid $CPID"
  wait $CPID
  log "client C exited rc=$?"
  if grep -a -q "finished with 0" "$CLOG"; then touch "$DONE"; log "DONE via C"; break; fi
  sleep 30
done
log "supervisor done"
exit 0
