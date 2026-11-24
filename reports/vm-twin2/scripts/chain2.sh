#!/usr/bin/env bash
# chain2.sh: after the kn rebuild with the new defaults (4,096 buffers, re-arm all): step search for kn2 from 160k
# (+16k, stop at the first FAIL), kn-final's old behaviour (KN_NBUF=1024 KN_REARM=256) at 144k, then 5-min holds at
# each one's highest pass, stepping down 16k once on a FAIL: #393 (176k), kn2, kn-final.
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"; export W="${W:?}"; K=kotlin-native-3x3xX3N0N; OLD="KN_NBUF=1024 KN_REARM=256"
run() { bash $S/nicq.sh 4 >/dev/null; KNENV="$3" bash $S/one.sh "$1" "$2" "$4" "${5:-60}" "${6:-60}"; }
V=160000; kb=""
while [ $V -le 320000 ]; do r=$(run kn2 $K "KN_STATS=1" $V); echo "$r" | cut -c1-300; echo "$r" | grep -q pass=PASS || break; kb=$V; V=$((V + 16000)); done
echo "HIGHEST kn2 $kb"
r=$(run knold $K "KN_STATS=1 $OLD" 144000); echo "$r" | cut -c1-300; ob=""; echo "$r" | grep -q pass=PASS && ob=144000
echo "HIGHEST knold ${ob:-<144000}"
hold() { local L=$1 E=$2 KE=$3 V=$4; [ -z "$V" ] && return; r=$(run $L $E "$KE" $V 60 300); echo "$r" | cut -c1-300
  echo "$r" | grep -q pass=PASS || { r=$(run $L $E "$KE" $((V - 16000)) 60 300); echo "$r" | cut -c1-300; }; }
hold dav-hold5m java-iouring-davidhsv "" 176000
hold kn2-hold5m $K "KN_STATS=1" "$kb"
hold knold-hold5m $K "KN_STATS=1 $OLD" "${ob:-128000}"
echo CHAIN2-DONE
