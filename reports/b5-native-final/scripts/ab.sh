#!/usr/bin/env bash
# ab.sh <users> <rounds> <variant>...   variant = label:bindir[:KNENV]   (bindir under $BASE/bin; KNENV space-separated,
# written with commas: "KN_A=1,KN_B=2"). Runs the variants interleaved, round by round, with bench.sh.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; BASE="${BASE:-/mnt/nebula/excal/dev0/tdsc-fleet/b5-native-work}"
VUS="$1"; ROUNDS="$2"; shift 2
for r in $(seq 1 "$ROUNDS"); do
  for v in "$@"; do
    IFS=: read -r label bin env <<< "$v"
    KNBIN="$BASE/bin/$bin/server.kexe" KNENV="${env//,/ }" bash "$D/bench.sh" "$label" "$VUS" "${HOLD:-60s}" "${RAMP:-30s}" 2>&1 | tail -1
  done
done
