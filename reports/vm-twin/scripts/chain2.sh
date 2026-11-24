#!/usr/bin/env bash
# chain2.sh: step-down holds (144k, both), then diagnostic kn holds at 160k (kn-exp2 = errno counters; then + 16k buffers).
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"; W="${W:?}"
KNENV=KN_STATS=1 bash "$S/hold.sh" kn-hold5m kotlin-native-3x3xX3N0N 144000 >> "$W/holds.log" 2>&1
KNENV= bash "$S/hold.sh" dav-hold5m java-iouring-davidhsv 144000 >> "$W/holds.log" 2>&1
while [ ! -f "$W/exp2-ready" ]; do sleep 5; done
KNENV=KN_STATS=1 bash "$S/hold.sh" x2-hold5m kn-exp2 160000 >> "$W/holds.log" 2>&1
KNENV="KN_STATS=1 KN_NBUF=16384 KN_REARM=0" bash "$S/hold.sh" x2nbuf-hold5m kn-exp2 160000 >> "$W/holds.log" 2>&1
echo CHAIN2-DONE >> "$W/holds.log"
