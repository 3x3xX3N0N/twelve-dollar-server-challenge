#!/usr/bin/env bash
# merge.sh <run dir> <cpu|alloc>: per-JVM JFR -> collapsed (thread-rooted, tid stripped), merged into <mode>-all.collapsed
set -euo pipefail
R="$1"; M="$2"; J="$(cd "$(dirname "$0")/../../.." && pwd)/tools/ap/bin/jfrconv"
for f in "$R"/$M-[0-9]*.jfr; do "$J" --$M -t --dot -o collapsed "$f" "${f%.jfr}.collapsed" >/dev/null; done
cat "$R"/$M-[0-9]*.collapsed | sed -E 's/^\[([^;]*) tid=[0-9]+\]/[\1]/' \
  | awk '{c=$NF; $NF=""; sub(/ $/,""); a[$0]+=c} END {for (k in a) print k, a[k]}' > "$R/$M-all.collapsed"
awk '{n+=$NF} END {print n" samples"}' "$R/$M-all.collapsed"
