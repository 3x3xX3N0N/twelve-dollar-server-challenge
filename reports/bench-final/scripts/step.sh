#!/usr/bin/env bash
# step.sh <start> <step> <builds...>: 60 s runs at start, start+step, ... interleaved over the builds still passing.
# A build drops out after a FAIL that a second run at the same level confirms (a pass on the retry keeps it in).
set -uo pipefail
D=/mnt/nebula/excal/dev0/tdsc-fleet/bench-final-work
U="$1"; S="$2"; shift 2; ALIVE=("$@")
while [ ${#ALIVE[@]} -gt 0 ]; do
  NEXT=()
  for b in "${ALIVE[@]}"; do
    for try in 1 2; do
      echo "step $U: $b try $try ($(date +%T), load $(cut -d' ' -f1-3 /proc/loadavg))"
      line=$(bash "$D/bench.sh" "$b" "$U" 60s 30s 2>&1 | tail -1); echo "$line"
      case "$line" in *PASS*) NEXT+=("$b"); break ;; esac
    done
  done
  ALIVE=("${NEXT[@]}"); U=$((U + S))
done
