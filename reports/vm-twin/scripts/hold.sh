#!/usr/bin/env bash
# hold.sh <label> <entry> <vus>: fresh server, 1,000-user warm-up, then one 60 s ramp + 5-min hold.
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"; W="${W:?}"; . "$W/state"
L="$1"; E="$2"; V="$3"
SRV="ssh -i $W/id_ed25519 -o UserKnownHostsFile=$W/known_hosts -o ConnectTimeout=10 -o BatchMode=yes root@$server_ip"
$SRV "KNENV='${KNENV:-}' bash /root/srv-start.sh /home/bench/repo/submissions/$E $L" > "$S/../runs/start-$L-$V-$(date +%H%M%S).txt" 2>&1
bash "$S/step.sh" "$L-warmup" 1000 20 20 > /dev/null
r=$(bash "$S/step.sh" "$L" "$V" 60 300 | tail -1); echo "$(date -u +%T) $r"
