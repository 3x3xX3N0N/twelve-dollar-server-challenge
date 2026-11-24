#!/usr/bin/env bash
# exp.sh "<label>|<entry>|<KNENV>|<vus>" ...: after chain.sh is done, one 60 s step each (fresh server + warm-up, NIC 4 queues).
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"; export W="${W:?}"
while ! grep -q CHAIN-DONE "$W/chain.log" 2>/dev/null; do sleep 10; done
for spec in "$@"; do
  IFS='|' read -r L E KE V <<< "$spec"
  bash $S/nicq.sh 4 >/dev/null; r=$(KNENV="$KE" bash $S/one.sh "$L" "$E" "$V"); echo "env=[$KE] $r" | cut -c1-330
done
echo EXP-DONE
