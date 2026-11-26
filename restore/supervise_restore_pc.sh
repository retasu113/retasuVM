#!/bin/bash
# supervise_restore_pc.sh — PC (WSL) version of supervise_restore.sh.
# Same attempt-29-proven cycle recipe, but: no Mac mini TSS tunnel (the
# home network reaches gs.apple.com directly) and BASE points at the WSL
# tree. Runs under systemd (retasuvm-restore.service in WSL).
# Completion marker: restore/DONE_15.6.1 (created when a client logs
# "finished with 0").
set -u
BASE=/home/retasu/retasuvm
DONE=$BASE/restore/DONE_15.6.1
SOCK=/tmp/retasuvm_vusb.sock
IPSW=$BASE/ipsw15/sequoia_15.6.1.ipsw
WORK=$BASE/restore/work
LOGD=$BASE/tests/logs
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
log "cycle start run=$RUN"

# Clean leftovers from a previous (killed) cycle.
pkill -x h_rom 2>/dev/null
pkill -f 'restore/build/restore' 2>/dev/null
sleep 2
rm -f "$SOCK"

# --- harness (guest) ---
FAST=1 VUSB_SOCK=$SOCK "$BASE/tests/h_rom" "$BASE/bootrom/AVPBooter.vmapple2.bin" 2048 200000 1 >> "$HLOG" 2>&1 &
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
  env "${envs[@]}" "$BASE/restore/build/restore" "$SOCK" "$IPSW" "$WORK" "$ECID" >> "$1" 2>&1 &
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
