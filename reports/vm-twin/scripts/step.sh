#!/usr/bin/env bash
# step.sh <label> <VUS> [ramp=60] [hold=60]: one load step from the generator VM against the running server.
# kload (load.js schedule: ramp, hold, 30 s ramp-down) runs on the generator over the VPC; this script snapshots server
# counters (snap.sh) at hold start and end, keeps the server journal and monitor samples, appends a row to results.tsv.
set -euo pipefail
S="$(cd "$(dirname "$0")" && pwd)"; W="${W:?}"; . "$W/state"
L="$1"; V="$2"; RAMP="${3:-60}"; HOLD="${4:-60}"
RUNS="$S/../runs"; OUT="$RUNS/$L-$V-$(date +%H%M%S)"; mkdir -p "$OUT"
SSH="ssh -i $W/id_ed25519 -o UserKnownHostsFile=$W/known_hosts -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=15 -o BatchMode=yes"
SRV="$SSH root@$server_ip"; GEN="$SSH root@$gen_ip"
SRCS="$(cat "$W/srcips")"
# both ends drained (no socket carry-over between steps)
$GEN "for i in \$(seq 90); do [ \$(ss -Htan | wc -l) -lt 200 ] && break; sleep 2; done; ss -Htan | wc -l" > "$OUT/gen-sockets-before.txt"
$SRV "for i in \$(seq 60); do [ \$(awk '\$1==\"TCP:\"{print \$9+\$5}' /proc/net/sockstat) -lt 500 ] && break; sleep 2; done; bash /root/snap.sh srv" > "$OUT/snap-pre.txt"
T0=$(date +%s)
$GEN "mkdir -p /root/runs; rm -f /root/runs/$L-$V.json /root/runs/$L-$V.txt; cd /root; ulimit -n 1048576; KLOAD_OPTS='-Xms2g -Xmx10g -XX:+UseParallelGC' nohup ./kload/kload --vus $V \
  --ramp-up ${RAMP}s --duration ${HOLD}s --threads ${THREADS:-6} --url http://$server_priv:80 --tokens /root/tokens.json \
  --source-ips $SRCS --json /root/runs/$L-$V.json > /root/runs/$L-$V.txt 2>&1 < /dev/null & echo started" > /dev/null
sleep $((RAMP + 3)); $SRV "bash /root/snap.sh srv" > "$OUT/snap0.txt"
sleep $((HOLD - 5)); $SRV "bash /root/snap.sh srv" > "$OUT/snap1.txt"
for i in $(seq 120); do $GEN "test -s /root/runs/$L-$V.json" && break; sleep 5; done
$GEN "cat /root/runs/$L-$V.json" > "$OUT/kload.json"; $GEN "cat /root/runs/$L-$V.txt" > "$OUT/kload.txt"
$SRV "bash /root/snap.sh srv" > "$OUT/snap-post.txt"
$SRV "journalctl -u srv --no-pager -o short-iso --since @$T0" > "$OUT/journal.txt" || true
$SRV "awk -v t=$T0 '{split(\$1,a,\"=\"); if (a[2] >= t) print}' /root/mon-*.log" > "$OUT/mon.txt" || true
$SRV "dmesg -T | tail -20" > "$OUT/dmesg-tail.txt" || true
python3 -I "$S/row.py" "$OUT" "$L" "$V" "$HOLD" | tee -a "$S/../results.tsv"
