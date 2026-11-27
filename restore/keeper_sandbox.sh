#!/bin/bash
# keeper_sandbox.sh — relaunch the sandbox restore supervisor if it is
# not running (e.g. after a sandbox VM replacement killed it). Invoked
# every ~10 minutes by the retasuvm-restore-keeper cron. Idempotent:
# the supervisor itself also holds a flock, so duplicates cannot run.
# Exits silently when the supervisor is alive or the restore is DONE.
BASE=/home/hatch/workspace/retasuvm
DONE=$BASE/restore/DONE_15.6.1
[ -f "$DONE" ] && exit 0
# Cutover gate: do NOT start the supervisor until the PC service has been
# confirmed stopped (gate file written by poll_pc_stop.sh after 2
# consecutive inactive checks). Without this, the keeper's first cron run
# (2026-11-27 07:58 JST) launched a sandbox cycle while the PC service
# was still active — the parent had to kill it. See
# tests/logs/supervisor_cutover_20261127.md ("CORRECTION").
GATE=$BASE/tests/logs/pc_stop_confirmed.txt
[ -f "$GATE" ] || exit 0
if pgrep -f "supervise_restore_sandbox\.sh" >/dev/null 2>&1; then exit 0; fi
mkdir -p "$BASE/tests/logs"
setsid nohup "$BASE/restore/supervise_restore_sandbox.sh" >> "$BASE/tests/logs/supervise_sandbox_out.log" 2>&1 &
echo "[keeper $(date '+%F %T')] relaunched sandbox supervisor" >> "$BASE/tests/logs/supervise_keeper.log"
exit 0
