#!/usr/bin/env bash
# one.sh <label> <entry> <vus> [ramp=60] [hold=60]: fresh server (fresh seed copy), 1,000-user warm-up (not counted),
# then one step. GENS / NET / NSRC / KNENV are passed through to step.sh.
set -uo pipefail
export GENS="${GENS:-1 2 3 4}" NET="${NET:-vpc}" NSRC="${NSRC:-1}" KNENV="${KNENV:-}"
S="$(cd "$(dirname "$0")" && pwd)"; W="${W:?}"; . "$W/state"
L="$1"; E="$2"; V="$3"; RAMP="${4:-60}"; HOLD="${5:-60}"
SRV="ssh -i $W/id_ed25519 -o UserKnownHostsFile=$W/known_hosts -o ConnectTimeout=10 -o BatchMode=yes root@$server_ip"
$SRV "KNENV='$KNENV' bash /root/srv-start.sh /home/bench/repo/submissions/$E $L" > "$S/../runs/start-$L-$V-$(date +%H%M%S).txt" 2>&1
bash "$S/step.sh" "$L-warmup" 1000 20 20 > /dev/null
r=$(bash "$S/step.sh" "$L" "$V" "$RAMP" "$HOLD" | tail -1); echo "$(date -u +%T) $r" | cut -c1-600
