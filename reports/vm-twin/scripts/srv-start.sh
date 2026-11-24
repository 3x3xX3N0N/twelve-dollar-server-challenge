#!/usr/bin/env bash
# srv-start.sh <entry-dir> <label> (root, server VM): fresh seed copy, starts start.sh as the service the scorer
# describes (user bench, LimitNOFILE=65535, CAP_NET_BIND_SERVICE, HOST=0.0.0.0 PORT=80), waits for /health, then a
# monitor unit appends snap.sh lines every 5 s to /root/mon-<label>.log. KNENV="A=1 B=2" adds environment variables.
set -euo pipefail
E="$1"; L="$2"
systemctl stop srv mon 2>/dev/null || true; systemctl reset-failed srv mon 2>/dev/null || true
R=/home/bench/run; rm -rf "$R"; mkdir -p "$R"; cp /home/bench/repo/seed/feed.db "$R/feed.db"; chown -R bench: "$R"
EX=(); for kv in ${KNENV:-}; do EX+=(-E "$kv"); done
systemd-run --unit=srv -p User=bench -p Group=bench -p LimitNOFILE=65535 -p AmbientCapabilities=CAP_NET_BIND_SERVICE \
  -p WorkingDirectory="$E" -E SQLITE_PATH="$R/feed.db" -E JWT_SECRET=twelve-dollar-challenge -E HOST=0.0.0.0 -E PORT=80 "${EX[@]}" \
  /bin/bash "$E/start.sh"
t0=$(date +%s.%N)
for i in $(seq 600); do curl -sf http://127.0.0.1:80/health >/dev/null && break; sleep 0.1; done
echo "healthy after $(echo "$(date +%s.%N) - $t0" | bc) s: $(curl -s http://127.0.0.1:80/health)"
sleep 2
systemd-run --unit=mon /bin/bash -c "while :; do bash /root/snap.sh srv >> /root/mon-$L.log; sleep 5; done" >/dev/null 2>&1
journalctl -u srv --no-pager -o cat | tail -20
bash /root/snap.sh srv
