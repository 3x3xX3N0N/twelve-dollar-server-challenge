#!/usr/bin/env bash
# chain.sh: after the kn search: #393 step search, then the 5-min holds at each one's highest pass (kn first).
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"; W="${W:?}"
while ! grep -q HIGHEST "$W/campaign-kn.log"; do sleep 10; done
KNENV= bash "$S/campaign.sh" dav java-iouring-davidhsv 96000 16000 512000 > "$W/campaign-dav.log" 2>&1
kb=$(awk '/HIGHEST/{print $3}' "$W/campaign-kn.log"); db=$(awk '/HIGHEST/{print $3}' "$W/campaign-dav.log")
[ -n "$kb" ] && KNENV=KN_STATS=1 bash "$S/hold.sh" kn-hold5m kotlin-native-3x3xX3N0N "$kb" >> "$W/holds.log" 2>&1
[ -n "$db" ] && KNENV= bash "$S/hold.sh" dav-hold5m java-iouring-davidhsv "$db" >> "$W/holds.log" 2>&1
echo CHAIN-DONE >> "$W/holds.log"
