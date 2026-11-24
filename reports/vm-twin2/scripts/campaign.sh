#!/usr/bin/env bash
# campaign.sh <label> <entry> <first> <step> <max>  : step search. Every step on a freshly started server (fresh seed
# copy, srv-start.sh) after a 1,000-user warm-up (20 s ramp + 20 s, not counted); 60 s ramp + 60 s hold per step.
# A FAIL is retried once; the search stops when the retry fails too. Prints the highest pass.
# KNENV is passed to srv-start.sh.
set -uo pipefail
export GENS="${GENS:-1 2 3 4}" NET="${NET:-vpc}" NSRC="${NSRC:-1}" KNENV="${KNENV:-}"
S="$(cd "$(dirname "$0")" && pwd)"; W="${W:?}"; . "$W/state"
L="$1"; E="$2"; V="$3"; STEP="$4"; MAX="$5"
SRV="ssh -i $W/id_ed25519 -o UserKnownHostsFile=$W/known_hosts -o ConnectTimeout=10 -o BatchMode=yes root@$server_ip"
start() { $SRV "KNENV='${KNENV:-}' bash /root/srv-start.sh /home/bench/repo/submissions/$E $L" > "$S/../runs/start-$L-$1-$(date +%H%M%S).txt" 2>&1; head -1 "$S/../runs/start-$L-$1-"*.txt | tail -1; }
best=""
while [ "$V" -le "$MAX" ]; do
  ok=""
  for try in 1 2; do
    start "$V"; bash "$S/step.sh" "$L-warmup" 1000 20 20 > /dev/null
    r=$(bash "$S/step.sh" "$L" "$V" 60 60 | tail -1); echo "$(date -u +%T) $r" | cut -c1-400
    if echo "$r" | grep -q 'pass=PASS'; then ok=1; break; fi
  done
  [ -n "$ok" ] || break
  best=$V; V=$((V + STEP))
done
echo "HIGHEST-PASS $L $best"
