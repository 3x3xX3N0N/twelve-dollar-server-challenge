#!/usr/bin/env bash
# search.sh <first> <step> <max>: interleaved 60 s step search, kn-final (KN_STATS=1) and #393 at the same users one
# after the other, each on a fresh server + warm-up (one.sh). An entry stops at its first FAIL (no retry, for time).
# Prints HIGHEST lines. NICQ (default 4) is applied before every run.
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"; W="${W:?}"
V=$1; STEP=$2; MAX=$3; kn=go; dv=go; kb=""; db=""
while [ "$V" -le "$MAX" ] && { [ $kn = go ] || [ $dv = go ]; }; do
  if [ $kn = go ]; then bash $S/nicq.sh ${NICQ:-4} >/dev/null; r=$(KNENV=KN_STATS=1 bash $S/one.sh kn kotlin-native-3x3xX3N0N $V); echo "$r" | cut -c1-260
    echo "$r" | grep -q pass=PASS && kb=$V || kn=stop; fi
  if [ $dv = go ]; then bash $S/nicq.sh ${NICQ:-4} >/dev/null; r=$(KNENV= bash $S/one.sh dav java-iouring-davidhsv $V); echo "$r" | cut -c1-260
    echo "$r" | grep -q pass=PASS && db=$V || dv=stop; fi
  V=$((V + STEP))
done
echo "HIGHEST kn $kb"; echo "HIGHEST dav $db"
