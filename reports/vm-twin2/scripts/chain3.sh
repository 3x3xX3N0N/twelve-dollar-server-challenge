#!/usr/bin/env bash
# chain3.sh: after chain2: 184k (midpoint of 176k PASS / 192k FAIL for both) as a 60 s step, kn2 then #393; a 5-min
# hold at 184k for each one that passes the step.
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"; export W="${W:?}"; K=kotlin-native-3x3xX3N0N
while ! grep -q CHAIN2-DONE "$W/chain2.log" 2>/dev/null; do sleep 10; done
run() { bash $S/nicq.sh 4 >/dev/null; KNENV="$3" bash $S/one.sh "$1" "$2" "$4" "${5:-60}" "${6:-60}"; }
rk=$(run kn2 $K "KN_STATS=1" 184000); echo "$rk" | cut -c1-300
rd=$(run dav java-iouring-davidhsv "" 184000); echo "$rd" | cut -c1-300
echo "$rk" | grep -q pass=PASS && { r=$(run kn2-hold5m $K "KN_STATS=1" 184000 60 300); echo "$r" | cut -c1-300; }
echo "$rd" | grep -q pass=PASS && { r=$(run dav-hold5m java-iouring-davidhsv "" 184000 60 300); echo "$r" | cut -c1-300; }
echo CHAIN3-DONE
