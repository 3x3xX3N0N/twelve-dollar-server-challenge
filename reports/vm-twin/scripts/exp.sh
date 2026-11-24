#!/usr/bin/env bash
# exp.sh "<label>|<entry>|<KNENV>|<vus>[|<ramp s>]" ...: one step each (ramp default 60 s, 60 s hold; fresh server +
# warm-up), after chain.sh is done.
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"; W="${W:?}"; . "$W/state"
while ! grep -q CHAIN-DONE "$W/holds.log" 2>/dev/null; do sleep 10; done
SRV="ssh -i $W/id_ed25519 -o UserKnownHostsFile=$W/known_hosts -o ConnectTimeout=10 -o BatchMode=yes root@$server_ip"
for spec in "$@"; do
  IFS='|' read -r L E KE V RAMP <<< "$spec"; RAMP=${RAMP:-60}
  $SRV "KNENV='$KE' bash /root/srv-start.sh /home/bench/repo/submissions/$E $L" > "$S/../runs/start-$L-$V-$(date +%H%M%S).txt" 2>&1
  bash "$S/step.sh" "$L-warmup" 1000 20 20 > /dev/null
  r=$(bash "$S/step.sh" "$L" "$V" "$RAMP" 60 | tail -1); echo "$(date -u +%T) env=[$KE] ramp=$RAMP $r"
done
echo EXP-DONE
