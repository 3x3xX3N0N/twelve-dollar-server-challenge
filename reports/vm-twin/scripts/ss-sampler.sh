#!/usr/bin/env bash
# ss-sampler.sh: once the diagnostic hold starts, samples TCP socket states on the server every 20 s for 8 min.
set -uo pipefail
W="${W:?}"; . "$W/state"; R=/home/excal/code/tdsc-wt/vm-twin/reports/vm-twin/runs
until ls $R/start-x2-hold5m-* >/dev/null 2>&1; do sleep 5; done
ssh -i $W/id_ed25519 -o UserKnownHostsFile=$W/known_hosts -o BatchMode=yes root@$server_ip 'for i in $(seq 24); do
  printf "%s " "$(date -u +%T)"; ss -Htan | awk "{n[\$1]++} END {for (s in n) printf \"%s=%d \", s, n[s]; print \"\"}"; sleep 20; done' > $R/x2-ss-states.txt 2>&1
