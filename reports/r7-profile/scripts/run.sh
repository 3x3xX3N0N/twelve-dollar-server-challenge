#!/usr/bin/env bash
# r7-profile bench driver: one server (start.sh, default WORKERS=3) pinned to ONE core in a 2 GB systemd scope,
# k6 on other cores, a measurement window inside the hold where the chosen probe runs.
#
#   run.sh <label> <VUS> <THINK> <mode> [hold_s=150] [window_s=90]
#   mode: base | cpu | alloc | strace | perfstat | inline
#
# THINK scales every sleep of bench/load.js (scripts/load-think.js; THINK=1 is bench/load.js unchanged).
# Server CPU 15 (its HT sibling 7 is left idle), k6 on 0-6,8-13. Ports 18080 (server), 18081 (k6 REST API).
# Kills only what it started: its own scope unit and its own k6 PIDs.
set -euo pipefail
LABEL="$1"; VUS="$2"; THINK="$3"; MODE="$4"; HOLD="${5:-150}"; WIN="${6:-90}"
WT="$(cd "$(dirname "$0")/../../.." && pwd)"
SUB="$WT/submissions/kotlin-nio-3x3xX3N0N"
AP="$WT/tools/ap"
K6="$HOME/.local/bin/k6"
# k6 runs in its OWN scope (6 GB cap, ~345 KB RSS per VU measured), never next to the server or this script
k6scope() { local u="$1"; shift; systemd-run --user --scope --quiet --unit="$u" -p MemoryMax=6G -p MemorySwapMax=0 taskset -c "$GENCPUS" "$K6" "$@"; }
SCRIPT="$WT/reports/r7-profile/scripts/load-think.js"
export TMPDIR="$WT/tmp"
OUT="$WT/tmp/runs/$LABEL"; rm -rf "$OUT"; mkdir -p "$OUT"
PORT=18080; KAPI=127.0.0.1:18081
UNIT="r7prof-$$"
export JWT_SECRET=twelve-dollar-challenge HOST=127.0.0.1 PORT SQLITE_PATH="$OUT/feed.db"
cp "$WT/seed/feed.db" "$SQLITE_PATH"
GENCPUS="${GENCPUS:-0-6,8-13}"

JOPTS="-Djava.io.tmpdir=$TMPDIR -Xlog:gc:file=$OUT/gc-%p.log:uptime"
# SQLITE_LIB=<dir>: load that libsqlitejdbc.so (e.g. the unstripped build from build-sqlite-sym.sh) instead of the jar's
[ -n "${SQLITE_LIB:-}" ] && JOPTS="$JOPTS -Dorg.sqlite.lib.path=$SQLITE_LIB -Dorg.sqlite.lib.name=libsqlitejdbc.so"
case "$MODE" in
  inline) JOPTS="$JOPTS -XX:+UnlockDiagnosticVMOptions -XX:+PrintCompilation -XX:+PrintInlining -XX:-DisplayVMOutputToStderr -XX:+LogVMOutput -XX:LogFile=$OUT/vm-%p.log" ;;
esac
export JAVA_TOOL_OPTIONS="$JOPTS"

# strace: yama ptrace_scope=1 forbids attaching, so strace is the parent of start.sh (counts cover the whole run)
PRE=""; [ "$MODE" = strace ] && PRE="strace -f -c -q -U name,calls,errors -o $OUT/strace.txt"
KPIDS=""
cleanup() {
  for p in $KPIDS; do kill "$p" 2>/dev/null || true; done
  systemctl --user stop "$UNIT.scope" "$UNIT-k6w.scope" "$UNIT-k6.scope" 2>/dev/null || true
  rm -f "$SQLITE_PATH" "$SQLITE_PATH-wal" "$SQLITE_PATH-shm"
}
trap cleanup EXIT
for _ in $(seq 40); do [ "$(ss -tan state time-wait "( sport = :$PORT )" | wc -l)" -le 1 ] && break; sleep 5; done
if ss -ltn "sport = :$PORT" | grep -q LISTEN; then echo "port $PORT busy"; exit 1; fi
{ echo "sqlite_lib=${SQLITE_LIB:-jar} mode=$MODE vus=$VUS think=$THINK hold=$HOLD win=$WIN"; echo "load before: $(cut -d' ' -f1-3 /proc/loadavg)";
  echo "conntrack: $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)"; } > "$OUT/env.txt"

systemd-run --user --scope --quiet --unit="$UNIT" -p AllowedCPUs=15 -p MemoryMax=2G -p MemorySwapMax=0 \
  bash -c "ulimit -n 65535; exec taskset -c 15 $PRE bash '$SUB/start.sh'" > "$OUT/server.log" 2>&1 &
for _ in $(seq 60); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 1; done
sleep 2
CG="/sys/fs/cgroup$(systemctl --user show -p ControlGroup --value "$UNIT.scope")"
SPIDS=""
for p in $(cat "$CG/cgroup.procs"); do [ "$(cat /proc/$p/comm 2>/dev/null)" = java ] && SPIDS="$SPIDS $p"; done
SPIDS="$(echo $SPIDS)"; echo "server pids: $SPIDS" | tee -a "$OUT/env.txt"
ticks() { local s=0; for p in $SPIDS; do s=$((s + $(awk '{print $14+$15}' /proc/$p/stat))); done; echo $s; }
uticks() { local s=0; for p in $SPIDS; do s=$((s + $(awk '{print $14}' /proc/$p/stat))); done; echo $s; }
cgusage() { awk '/^usage_usec/ {print $2}' "$CG/cpu.stat"; }

# warm-up: JIT and page cache (not measured)
k6scope "$UNIT-k6w" run -q --no-usage-report --local-ips 127.0.0.2-127.0.0.5 --address 127.0.0.1:18082 -e BASE_URL="http://127.0.0.1:$PORT" \
  -e TOKENS="$WT/seed/tokens.json" -e VUS=$((VUS / 2)) -e THINK="$THINK" -e RAMP_UP=10s -e DURATION=30s \
  --summary-export "$OUT/warmup-summary.json" "$SCRIPT" > "$OUT/warmup.txt" 2>&1 || true

k6scope "$UNIT-k6" run --no-usage-report --local-ips 127.0.0.6-127.0.0.9 --address "$KAPI" -e BASE_URL="http://127.0.0.1:$PORT" \
  -e TOKENS="$WT/seed/tokens.json" -e VUS="$VUS" -e THINK="$THINK" -e RAMP_UP=30s -e DURATION="${HOLD}s" \
  --summary-export "$OUT/k6-summary.json" "$SCRIPT" > "$OUT/k6.txt" 2>&1 &
KPIDS="$!"
( sleep 60; ps -o rss= -p "$KPIDS" > "$OUT/k6-rss-kb.txt" ) &
reqs() {   # k6 REST API; retried (with 30k VUs the API can be slow to answer)
  local v
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    v=$(curl -sS -m 20 "http://$KAPI/v1/metrics/http_reqs" 2>>"$OUT/reqs.err" | python3 -I -c 'import json,sys; print(int(json.load(sys.stdin)["data"]["attributes"]["sample"]["count"]))' 2>>"$OUT/reqs.err") && [ -n "$v" ] && { echo "$v"; return 0; }
    sleep 1
  done
  echo "k6 API unreachable" >&2; return 1
}
sleep 30; sleep $(((HOLD - WIN) / 2))   # past the ramp, centre the window in the hold

PROBE=""
case "$MODE" in
  cpu)   for p in $SPIDS; do "$AP/bin/asprof" start -e cpu -i 1ms --threads -o jfr -f "$OUT/cpu-$p.jfr" "$p" >/dev/null; done ;;
  alloc) for p in $SPIDS; do "$AP/bin/asprof" start -e alloc --alloc 64k --threads -o jfr -f "$OUT/alloc-$p.jfr" "$p" >/dev/null; done ;;
  perfstat) perf stat -x, -o "$OUT/perfstat.csv" -e task-clock,context-switches,cpu-migrations,page-faults,cycles:u,cycles:k,instructions:u,instructions:k,branch-misses,cache-misses,L1-icache-load-misses,iTLB-load-misses \
              -p "$(echo $SPIDS | tr ' ' ,)" -- sleep "$WIN" & PROBE="$!" ;;
esac
for p in $SPIDS; do echo "$p $(wc -l < "$OUT/gc-$p.log")"; done > "$OUT/gc-lines-t0.txt"
for p in $SPIDS; do echo "$p $(grep -E "^sysc" /proc/$p/io | tr "\n" " ")"; done > "$OUT/io-t0.txt"
t0=$(ticks); u0=$(uticks); c0=$(cgusage); r0=$(reqs); s0=$(date +%s.%N)
sleep "$WIN"
t1=$(ticks); u1=$(uticks); c1=$(cgusage); r1=$(reqs); s1=$(date +%s.%N)
for p in $SPIDS; do echo "$p $(wc -l < "$OUT/gc-$p.log")"; done > "$OUT/gc-lines-t1.txt"
echo "$r0 $r1 $s0 $s1" > "$OUT/window.txt"
for p in $SPIDS; do echo "$p $(grep -E "^sysc" /proc/$p/io | tr "\n" " ")"; done > "$OUT/io-t1.txt"
case "$MODE" in
  cpu|alloc) for p in $SPIDS; do "$AP/bin/asprof" stop "$p" >/dev/null; done ;;
  perfstat) wait "$PROBE" || true ;;
esac
RSS=$(ps -o rss= -p "$(echo $SPIDS | tr ' ' ,)" | awk '{s+=$1} END {print int(s/1024)}')
python3 -I - "$t0" "$t1" "$u0" "$u1" "$c0" "$c1" "$r0" "$r1" "$s0" "$s1" "$RSS" <<'EOF' | tee -a "$OUT/env.txt"
import sys
t0,t1,u0,u1,c0,c1,r0,r1=map(int,sys.argv[1:9]); s0,s1=map(float,sys.argv[9:11]); rss=sys.argv[11]
hz=100; el=s1-s0; n=r1-r0
cpu=(t1-t0)/hz; ucpu=(u1-u0)/hz; cg=(c1-c0)/1e6
print(f"window {el:.1f}s reqs {n} = {n/el:.0f} req/s | java cpu {cpu/el*100:.1f}% (user {ucpu/el*100:.1f}%, sys {(cpu-ucpu)/el*100:.1f}%) cgroup {cg/el*100:.1f}%")
print(f"us/req: total {cg*1e6/n:.1f} (java procs {cpu*1e6/n:.1f}: user {ucpu*1e6/n:.1f} sys {(cpu-ucpu)*1e6/n:.1f}) rss {rss} MB")
EOF
wait "$KPIDS" || true; KPIDS=""
grep -E "http_reqs|http_req_duration|http_req_failed|checks" "$OUT/k6.txt" | tee -a "$OUT/env.txt" || true
echo "load after: $(cut -d' ' -f1-3 /proc/loadavg)" >> "$OUT/env.txt"
for p in $SPIDS; do echo "== $p"; grep -c "Pause" "$OUT/gc-$p.log" 2>/dev/null; done >> "$OUT/env.txt" || true
if [ "$MODE" = strace ]; then
  for p in $(cat "$CG/cgroup.procs"); do [ "$(cat /proc/$p/comm 2>/dev/null)" = strace ] && kill -INT "$p"; done
  for _ in $(seq 30); do [ -s "$OUT/strace.txt" ] && break; sleep 1; done; sleep 1
  python3 -I -c 'import json,sys; t=0
for f in sys.argv[1:]: t+=json.load(open(f))["metrics"]["http_reqs"]["count"]
print("k6 requests over the whole run:", t)' "$OUT/k6-summary.json" "$OUT/warmup-summary.json" >> "$OUT/env.txt"
fi
echo "out: $OUT"
