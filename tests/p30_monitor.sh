#!/bin/bash
# Phase 30 boot monitor: poll the PC every 15 min, append checkpoints to the
# local log, exit when the watcher done-file appears. Self-contained SSH.
LOG=~/workspace/retasuvm/tests/logs/p30_monitor_local.log
pcssh() {
  env HTTPS_PROXY=http://hatch-egress-proxy:3128 ssh -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 -o ConnectTimeout=30 -o UserKnownHostsFile=/home/hatch/.ssh/known_hosts -o ProxyCommand="env HTTPS_PROXY=http://hatch-egress-proxy:3128 python3 /home/hatch/workspace/retasuvm/restore/ts_proxy_connect.py 100.67.12.24 22" retasu@100.67.12.24 "$1"
}
for i in $(seq 1 40); do
  OUT=$(pcssh "if [ -f ~/retasuvm/tests/logs/p30_watch_done.txt ]; then echo WATCH_DONE; fi; ps aux | grep -c '[h]_rom_img_p30'; grep -a 'instr=' ~/retasuvm/tests/logs/boot_p30_cycle1.log | tail -1; grep -a 'ev=CAPTURE' ~/retasuvm/inst/imagetest/home_p30/sfvtrace.txt 2>/dev/null | head -1; grep -a -m1 'panic' ~/retasuvm/tests/logs/boot_p30_cycle1.log | head -1" 2>/dev/null)
  echo "=== check $i $(date '+%F %T %Z') ===" >> $LOG
  echo "$OUT" >> $LOG
  if echo "$OUT" | grep -q WATCH_DONE; then echo "monitor: watcher done" >> $LOG; break; fi
  sleep 900
done
echo "MONITOR_END $(date '+%F %T %Z')" >> $LOG
tail -30 $LOG
