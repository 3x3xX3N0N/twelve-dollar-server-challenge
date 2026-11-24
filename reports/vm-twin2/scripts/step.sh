#!/usr/bin/env bash
# step.sh <label> <VUS> [ramp=60] [hold=60]: one load step from $GENS generator VMs (default "1 2 3 4") against the
# running server. VUs are split evenly; every generator starts kload (load.js schedule: ramp, hold, 30 s ramp-down) at
# the same moment. NET=vpc (default; server's VPC address, NSRC source addresses per generator, default 1 like the
# scorer's one-IP generators), NET=pub (public addresses, one source IP per generator) or NET=mix (odd generators
# public, even generators VPC: the load enters through both NICs). The generators' JSON are
# merged bucket by bucket (merge.py) into one k6-style verdict. Server snapshots at hold start/end (snap.sh), the
# server journal, 5 s server and generator samples are kept; one row goes to results.tsv.
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"; W="${W:?}"; . "$W/state"
L="$1"; V="$2"; RAMP="${3:-60}"; HOLD="${4:-60}"
GENS="${GENS:-1 2 3 4}"; NET="${NET:-vpc}"; NSRC="${NSRC:-1}"; THREADS="${THREADS:-4}"
RUNS="$S/../runs"; OUT="$RUNS/$L-$V-$(date +%H%M%S)"; mkdir -p "$OUT"
SSH="ssh -i $W/id_ed25519 -o UserKnownHostsFile=$W/known_hosts -o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 -o ServerAliveInterval=15 -o BatchMode=yes"
SRV="$SSH root@$server_ip"
gip() { eval echo "\$gen${1}_ip"; }; gpriv() { eval echo "\$gen${1}_priv"; }
NG=$(echo $GENS | wc -w); PER=$((V / NG))
if [ "$NET" = pub ]; then URL="http://$server_ip:80"; else URL="http://$server_priv:80"; fi
echo "gens=[$GENS] net=$NET nsrc=$NSRC per_gen=$PER ramp=$RAMP hold=$HOLD knenv=[${KNENV:-}]" > "$OUT/setup.txt"
for k in $GENS; do
  $SSH root@$(gip $k) "for i in \$(seq 90); do [ \$(ss -Htan | wc -l) -lt 200 ] && break; sleep 2; done; ss -Htan | wc -l" > "$OUT/gen$k-sockets-before.txt" &
done; wait
$SRV "for i in \$(seq 60); do [ \$(awk '\$1==\"TCP:\"{print \$9+\$5}' /proc/net/sockstat) -lt 500 ] && break; sleep 2; done; bash /root/snap.sh srv" > "$OUT/snap-pre.txt"
T0=$(date +%s); DUR=$((RAMP + HOLD + 45))
for k in $GENS; do
  N=$NET; [ "$NET" = mix ] && { [ $((k % 2)) = 1 ] && N=pub || N=vpc; }
  if [ "$N" = pub ]; then URL="http://$server_ip:80"; else URL="http://$server_priv:80"; fi
  if [ "$N" = pub ]; then SRCS=$(gip $k); else
    p=$(gpriv $k); P=${p%.*}; SRCS=""; for j in $(seq 0 $((NSRC - 1))); do SRCS="$SRCS${SRCS:+,}$P.$((100 + 10 * k + j))"; done; fi
  $SSH root@$(gip $k) "mkdir -p /root/runs; rm -f /root/runs/cur.json /root/runs/cur.txt /root/runs/gmon.txt; cd /root; ulimit -n 1048576
    nohup bash -c 'for i in \$(seq $((DUR / 5 + 6))); do bash /root/gsnap.sh; sleep 5; done' > /root/runs/gmon.txt 2>&1 < /dev/null &
    KLOAD_OPTS='-Xms2g -Xmx10g -XX:+UseParallelGC' nohup ./kload/kload --vus $PER --ramp-up ${RAMP}s --duration ${HOLD}s \
    --threads $THREADS --url $URL --tokens /root/tokens.json --source-ips $SRCS --json /root/runs/cur.json > /root/runs/cur.txt 2>&1 < /dev/null &
    echo started" > /dev/null &
done; wait
# server snapshots: retried (the server's ssh shares a loaded NIC); the monitor's 5 s samples are the fallback
ssnap() { for t in 1 2 3; do $SRV "bash /root/snap.sh srv" > "$1" 2>/dev/null && [ -s "$1" ] && return 0; done; return 1; }
sleep $((RAMP + 3)); ssnap "$OUT/snap0.txt"
sleep $((HOLD - 5)); ssnap "$OUT/snap1.txt"
for k in $GENS; do
  # kload ends ~ramp+hold+40 s after T0; wait at most 120 s past that, every ssh bounded by timeout
  while [ $(date +%s) -lt $((T0 + RAMP + HOLD + 160)) ]; do timeout 30 $SSH root@$(gip $k) "test -s /root/runs/cur.json" && break; sleep 5; done
  timeout 60 $SSH root@$(gip $k) "cat /root/runs/cur.json" > "$OUT/kload-gen$k.json"; timeout 60 $SSH root@$(gip $k) "cat /root/runs/cur.txt" > "$OUT/kload-gen$k.txt"
  timeout 60 $SSH root@$(gip $k) "cat /root/runs/gmon.txt" > "$OUT/gmon-gen$k.txt" || true
done
python3 -I "$S/merge.py" $(for f in "$OUT"/kload-gen*.json; do [ -s "$f" ] && echo "$f"; done) > "$OUT/kload.json"
ssnap "$OUT/snap-post.txt"
$SRV "journalctl -u srv --no-pager -o short-iso --since @$T0" > "$OUT/journal.txt" || true
$SRV "awk -v t=$T0 '{split(\$1,a,\"=\"); if (a[2] >= t) print}' /root/mon-*.log" > "$OUT/mon.txt" || true
$SRV "dmesg -T | tail -30" > "$OUT/dmesg-tail.txt" || true
python3 -I "$S/row.py" "$OUT" "$L" "$V" "$HOLD" | tee -a "$S/../results.tsv"
