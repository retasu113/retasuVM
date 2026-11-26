#!/bin/bash
# supervise_restore.sh — run the full Sequoia restore cycle (attempt-29-proven
# recipe) and restart it from scratch whenever anything dies, until the
# restore completes. Runs under systemd (retasuvm-restore.service).
# Completion marker: restore/DONE_15.6.1 (created when a client logs
# "finished with 0").
set -u
BASE=/home/hatch/workspace/retasuvm
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

# --- TSS tunnel via the user's Mac mini (gs.apple.com is unreachable from
# this VM's own egress since 2026-11-17 ~19:22 JST; the Mac mini's home
# network reaches it fine). Key-only SSH through the tailnet tunnel proxy;
# a local SOCKS port (1080) is the restore clients' only internet path. ---
MACMINI=100.111.99.27
SSHKEY=/home/hatch/.ssh/id_ed25519
TUN_PID=""
tunnel_up(){
  # NB: curl prints 000 on connection failure — that must NOT count as up.
  curl -s --cacert "$BASE/restore/ca_bundle.pem" --socks5-hostname 127.0.0.1:1080 --max-time 20 -o /dev/null -w "%{http_code}" "https://gs.apple.com/TSS/controller?action=2" 2>/dev/null | grep -qE "^[1-5][0-9][0-9]$"
}
ensure_tunnel(){
  if tunnel_up; then return 0; fi
  [ -n "$TUN_PID" ] && kill $TUN_PID 2>/dev/null; sleep 1
  HTTPS_PROXY=http://hatch-egress-proxy:3128 ssh -N -D 127.0.0.1:1080 \
    -o ProxyCommand="python3 $BASE/restore/ts_proxy_connect.py $MACMINI 22" \
    -o IdentitiesOnly=yes -i "$SSHKEY" -o UserKnownHostsFile=/home/hatch/.ssh/known_hosts \
    -o BatchMode=yes -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=accept-new \
    retasu@$MACMINI >> "$LOGD/supervise_tunnel.log" 2>&1 &
  TUN_PID=$!
  for i in $(seq 1 15); do
    if tunnel_up; then log "tunnel up pid $TUN_PID"; return 0; fi
    sleep 5
  done
  log "tunnel FAILED to come up"
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
# `wait` returns 127 instantly (2026-11-17: 15 orphan clients, one new
# client every ~31 s). Call it directly; it sets LAST_CLIENT_PID.
LAST_CLIENT_PID=""
run_client(){ # $1=logfile $2=nomux(1/0); sets LAST_CLIENT_PID
  local envs=(HV_INSTALL_LOG=1 HV_VUSB_LOG=1 HV_LIBUSB_LOG=1 HV_USB_OUT_CHUNK=262144 https_proxy=socks5h://127.0.0.1:1080 HTTPS_PROXY=socks5h://127.0.0.1:1080 http_proxy=socks5h://127.0.0.1:1080 HTTP_PROXY=socks5h://127.0.0.1:1080 SSL_CERT_FILE=$BASE/restore/ca_bundle.pem CURL_CA_BUNDLE=$BASE/restore/ca_bundle.pem)
  [ "$2" = 1 ] && envs+=(HV_NO_MUX=1)
  env "${envs[@]}" "$BASE/restore/build/restore" "$SOCK" "$IPSW" "$WORK" "$ECID" >> "$1" 2>&1 &
  LAST_CLIENT_PID=$!
}

# --- client A: DFU -> iBSS ---
ensure_tunnel || { log "no tunnel; restarting cycle"; exit 1; }
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
ensure_tunnel || log "WARNING: tunnel down before client B"
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
  ensure_tunnel || log "WARNING: tunnel down before client C"
  run_client "$CLOG" 0; CPID=$LAST_CLIENT_PID
  log "client C pid $CPID"
  wait $CPID
  log "client C exited rc=$?"
  if grep -a -q "finished with 0" "$CLOG"; then touch "$DONE"; log "DONE via C"; break; fi
  sleep 30
done
log "supervisor done"
exit 0
