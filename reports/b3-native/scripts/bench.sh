#!/usr/bin/env bash
# b3-native bench driver (derived from /mnt/nebula/excal/research/knio-v3/bench-ns.sh, the method behind the
# kotlin-native README "Measured" numbers).
#   bench.sh <label> <VUS> [hold=60s] [ramp=30s]      env: KNENV="KN_X=1 KN_Y=2" (server knobs), PORT, CORE
# Server: fresh seed copy, own systemd --user scope (AllowedCPUs=$CORE, MemoryMax=2G, no swap), taskset $CORE,
#   ulimit -n 65535, inside a fresh user+net namespace (bwrap: own loopback, no host conntrack, no TIME_WAIT carry-over).
# Load: kload (k6-compatible replay of bench/load.js) in its OWN scope (MemoryMax=6G) on CPUs 0-3,8-11, joined to the
#   server's namespace with nsenter. Kills only what it started.
set -euo pipefail
LABEL="$1"; VUS="$2"; HOLD="${3:-60s}"; RAMP="${4:-30s}"
WT="$(cd "$(dirname "$0")/../../.." && pwd)"
ROOT="$HOME/code/twelve-dollar-server-challenge"          # seed + tokens (read only)
SUB="${SUB:-$WT/submissions/kotlin-native-3x3xX3N0N}"
BASE="${BASE:-/mnt/nebula/excal/dev0/tdsc-fleet/b3-native-work}"
OUT="$BASE/runs/$LABEL-$VUS-$(date +%m%d-%H%M%S)"; mkdir -p "$OUT"
PORT="${PORT:-18120}"; CORE="${CORE:-14}"; GENCPUS="${GENCPUS:-0-3,8-11}"
UNIT="b3n-srv-$$"; LUNIT="b3n-load-$$"
export JWT_SECRET=twelve-dollar-challenge HOST=0.0.0.0 PORT SQLITE_PATH="$OUT/feed.db"
cp "$ROOT/seed/feed.db" "$SQLITE_PATH"
cleanup() {
  systemctl --user stop "$LUNIT.scope" 2>/dev/null || true
  systemctl --user stop "$UNIT.scope" 2>/dev/null || true
}
trap cleanup EXIT
echo "load before: $(cut -d' ' -f1-3 /proc/loadavg); io psi: $(head -1 /proc/pressure/io)" > "$OUT/env.txt"
echo "knobs: ${KNENV:-none}" >> "$OUT/env.txt"
ps -eo pcpu,psr,comm --sort=-pcpu | head -8 >> "$OUT/env.txt"
systemd-run --user --scope --quiet --unit="$UNIT" -p AllowedCPUs="$CORE" ${CPUQUOTA:+-p CPUQuota=$CPUQUOTA} \
  -p MemoryMax=2G -p MemorySwapMax=0 \
  bash -c "ulimit -n ${NOFILE:-65535}; exec bwrap --unshare-user --unshare-net --uid $(id -u) --gid $(id -g) --ro-bind / / --dev /dev --proc /proc --bind '$OUT' '$OUT' --bind /tmp /tmp -- env ${KNENV:-} taskset -c $CORE bash '$SUB/start.sh'" > "$OUT/server.log" 2>&1 &
sleep 1
CG="/sys/fs/cgroup$(systemctl --user show -p ControlGroup --value "$UNIT.scope")"
NSP=""
for _ in $(seq 50); do
  for p in $(cat "$CG/cgroup.procs" 2>/dev/null); do [ "$(cat /proc/$p/comm 2>/dev/null)" = server.kexe ] && NSP=$p; done
  [ -n "$NSP" ] && break; sleep 0.2
done
[ -n "$NSP" ] || { echo "server did not start"; cat "$OUT/server.log"; exit 1; }
IN="nsenter --preserve-credentials -U -n -t $NSP"
for _ in $(seq 60); do $IN curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 1; done
sleep 2
SPIDS="$NSP"
echo "server pid $NSP; out $OUT"
ticks() { awk '{print $14+$15}' /proc/$NSP/stat; }
uticks() { awk '{print $14}' /proc/$NSP/stat; }
rssmb() { ps -o rss= -p "$NSP" | awk '{s+=$1} END {print int(s/1024)}'; }
IDLE=$(rssmb)
KL="systemd-run --user --scope --quiet -p MemoryMax=6G -p MemorySwapMax=0 -p AllowedCPUs=$GENCPUS"
# warm-up, 1000 VUs, not scored
( cd "$WT/bench" && $KL --unit="$LUNIT-w" $IN taskset -c "$GENCPUS" "$HOME/code/kload/kload" --vus 1000 --ramp-up 5s \
    --duration 15s --ramp-down 1s --grace 1s --quiet --url "http://127.0.0.1:$PORT" --tokens "$ROOT/seed/tokens.json" \
    > "$OUT/warmup.txt" 2>&1 ) || true
( cd "$WT/bench" && exec $KL --unit="$LUNIT" $IN taskset -c "$GENCPUS" "$HOME/code/kload/kload" --vus "$VUS" \
    --ramp-up "$RAMP" --duration "$HOLD" --ramp-down 5s --grace 5s --quiet \
    --url "http://127.0.0.1:$PORT" --tokens "$ROOT/seed/tokens.json" --json "$OUT/kload.json" > "$OUT/kload.txt" 2>&1 ) &
KPID=$!
( while kill -0 "$KPID" 2>/dev/null; do echo "$(date +%s) $(rssmb) MB cg $(( $(cat $CG/memory.current) / 1048576 )) MB"; sleep 5; done ) > "$OUT/server-stats.txt" &
STATP=$!
sleep "${RAMP%s}"; t0=$(ticks); u0=$(uticks); s0=$(date +%s.%N); w0=$(awk '/syscw/{print $2}' /proc/$NSP/io)
[ -n "${PERF:-}" ] && ( sleep 10; perf record -F 2000 -p "$NSP" -o "$OUT/perf.data" -- sleep 20 > "$OUT/perf.log" 2>&1 ) &
sleep "${HOLD%s}"; t1=$(ticks); u1=$(uticks); s1=$(date +%s.%N); w1=$(awk '/syscw/{print $2}' /proc/$NSP/io)
RSS=$(rssmb)
wait "$KPID" || true
kill $STATP 2>/dev/null || true
CGPEAK=$(( $(cat "$CG/memory.peak") / 1048576 ))
echo "load after: $(cut -d' ' -f1-3 /proc/loadavg); io psi: $(head -1 /proc/pressure/io)" >> "$OUT/env.txt"
python3 -I - "$OUT" "$LABEL" "$VUS" "$t0" "$t1" "$u0" "$u1" "$s0" "$s1" "$(getconf CLK_TCK)" "$RSS" "$IDLE" "$CGPEAK" "$w0" "$w1" <<'EOF' | tee -a "$BASE/results.tsv"
import json,sys
out,label,vus,t0,t1,u0,u1,s0,s1,hz,rss,idle,cgpeak,w0,w1=sys.argv[1:]
j=json.load(open(out+"/kload.json"))
h=j["hold"]; wall=float(s1)-float(s0); cpu=(int(t1)-int(t0))/int(hz); ucpu=(int(u1)-int(u0))/int(hz)
hreqs=h["reqs"] or 1
us=cpu/hreqs*1e6
ok="PASS" if j["pass"] else "FAIL"
print(f"{label}\tVUS={vus}\t{ok}\treqs={j['reqs']}\terr={j['fail_rate']*100:.3f}%\tp95={j['p95_ms']:.1f}\tp99={j['p99_ms']:.1f}\t"
      f"hold_p99={h['p99_ms']:.1f}\tcpu={cpu/wall*100:.0f}%\tus/req={us:.1f}\t(user {ucpu/hreqs*1e6:.1f})\trss={rss}MB\tidle={idle}MB\t"
      f"writes/req={(int(w1)-int(w0))/hreqs:.3f}\tcgpeak={cgpeak}MB\tgenstalls={j['gen_loop_stalls']}\tmaxopen={j['max_open']}\t{out.split('/')[-1]}")
EOF
cleanup; trap - EXIT
sleep 1
[ -n "${INTEGRITY:-}" ] && echo "integrity_check: $($HOME/.local/opt/sqlite-3.54/sqlite3 "$SQLITE_PATH" "PRAGMA integrity_check" | head -3 | tr "\n" " ")"
rm -f "$OUT"/feed.db*
