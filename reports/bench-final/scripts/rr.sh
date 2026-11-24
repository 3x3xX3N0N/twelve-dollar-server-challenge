#!/usr/bin/env bash
# rr.sh <rounds> <users...> -- <builds...>: round-robin, every round runs each users level over all builds in order.
set -uo pipefail
D=/mnt/nebula/excal/dev0/tdsc-fleet/bench-final-work
R="$1"; shift; U=(); while [ "$1" != -- ]; do U+=("$1"); shift; done; shift
for r in $(seq 1 "$R"); do for u in "${U[@]}"; do for b in "$@"; do
  echo "round $r: $b $u ($(date +%T), load $(cut -d' ' -f1-3 /proc/loadavg))"
  bash "$D/bench.sh" "$b" "$u" "${HOLD:-60s}" "${RAMP:-30s}" 2>&1 | tail -1
done; done; done
