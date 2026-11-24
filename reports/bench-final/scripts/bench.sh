#!/usr/bin/env bash
# bench-final driver (from reports/b5-native-final/scripts/bench.sh, the method behind the kotlin-native README "Measured").
#   bench.sh <build> <VUS> [hold=60s] [ramp=30s]
# Server: fresh seed copy (DB on the shared disk, as the README numbers), own systemd --user scope (AllowedCPUs=14,
#   MemoryMax=2G, no swap), taskset 14, ulimit -n 65535, inside a fresh user+net namespace (bwrap: own loopback, no host
#   conntrack). Load: kload (k6-compatible replay of bench/load.js) in its OWN scope (MemoryMax=6G) on CPUs 0-3,8-11,
#   joined to the server's namespace with nsenter. CPU = the server scope's cgroup cpu.stat (all processes/threads).
set -euo pipefail
B="$1"; VUS="$2"; HOLD="${3:-60s}"; RAMP="${4:-30s}"
W=/mnt/nebula/excal/dev0/tdsc-fleet/bench-final-work; WT=/mnt/nebula/excal/dev0/tdsc-fleet/bench-wt; F=/mnt/nebula/excal/dev0/tdsc-fleet
ROOT="$HOME/code/twelve-dollar-server-challenge"; BENCH=/home/excal/code/tdsc-wt/bench-final/bench
case "$B" in
  kn-final|kn-b3) SUB=$WT/$B/submissions/kotlin-native-3x3xX3N0N; COMM=server.kexe ;;
  jvm-uring) SUB=$WT/$B/submissions/kotlin-jvm-uring-3x3xX3N0N; COMM=java ;;
  graal-ce|graal-nocpgo) SUB=$WT/$B/submissions/kotlin-graal-3x3xX3N0N; COMM=server; export GRAALVM_HOME=$F/b1-graal-work/graalvm ;;
  nio-v3) SUB=$WT/$B/submissions/kotlin-nio-3x3xX3N0N; COMM=java ;;
  dav) SUB=$WT/dav; COMM=server ;;
  *) echo "unknown build $B"; exit 2 ;;
esac
OUT="$W/runs/$B-$VUS-$HOLD${DBDIR:+-shm}-$(date +%m%d-%H%M%S)"; mkdir -p "$OUT"
# DBDIR=/dev/shm/x: database on tmpfs (side comparison only)
DBD="${DBDIR:+$DBDIR/$(basename "$OUT")}"; DBD="${DBD:-$OUT}"; mkdir -p "$DBD"
PORT=18150; CORE=14; GENCPUS=0-3,8-11
UNIT="bf-srv-$$"; LUNIT="bf-load-$$"
export JWT_SECRET=twelve-dollar-challenge HOST=0.0.0.0 PORT SQLITE_PATH="$DBD/feed.db"
cp "$ROOT/seed/feed.db" "$SQLITE_PATH"
cleanup() { systemctl --user stop "$LUNIT-w.scope" "$LUNIT.scope" 2>/dev/null || true; systemctl --user stop "$UNIT.scope" 2>/dev/null || true; }
trap cleanup EXIT
echo "load before: $(cut -d' ' -f1-3 /proc/loadavg); io psi: $(head -1 /proc/pressure/io); conntrack $(cat /proc/sys/net/netfilter/nf_conntrack_count)" > "$OUT/env.txt"
ps -eo pcpu,psr,comm --sort=-pcpu | head -8 >> "$OUT/env.txt"
systemd-run --user --scope --quiet --unit="$UNIT" -p AllowedCPUs="$CORE" -p MemoryMax=2G -p MemorySwapMax=0 -E GRAALVM_HOME \
  bash -c "ulimit -n 65535; exec bwrap --unshare-user --unshare-net --uid $(id -u) --gid $(id -g) --ro-bind / / --dev /dev --proc /proc --bind '$OUT' '$OUT' --bind '$DBD' '$DBD' --bind /tmp /tmp -- taskset -c $CORE bash $SUB/start.sh" > "$OUT/server.log" 2>&1 &
sleep 1
CG="/sys/fs/cgroup$(systemctl --user show -p ControlGroup --value "$UNIT.scope")"
spids() { for p in $(cat "$CG/cgroup.procs" 2>/dev/null); do [ "$(cat /proc/$p/comm 2>/dev/null)" = "$COMM" ] && echo $p; done; true; }
NSP=""
for _ in $(seq 100); do NSP=$(spids | awk "NR==1"); [ -n "$NSP" ] && break; sleep 0.2; done
[ -n "$NSP" ] || { echo "server did not start"; cat "$OUT/server.log"; exit 1; }
IN="nsenter --preserve-credentials -U -n -t $NSP"
for _ in $(seq 90); do $IN curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 1; done
$IN curl -sf "http://127.0.0.1:$PORT/health" >/dev/null || { echo "no /health"; tail "$OUT/server.log"; exit 1; }
sleep 2
cpu() { awk '/^usage_usec/{u=$2} /^user_usec/{s=$2} END{print u, s}' "$CG/cpu.stat"; }
rssmb() { local s=0; for p in $(spids); do s=$((s + $(awk '/VmRSS/{print $2}' /proc/$p/status 2>/dev/null || echo 0))); done; echo $((s/1024)); }
IDLE=$(rssmb)
KL="systemd-run --user --scope --quiet -p MemoryMax=6G -p MemorySwapMax=0 -p AllowedCPUs=$GENCPUS"
( cd "$BENCH" && $KL --unit="$LUNIT-w" $IN taskset -c "$GENCPUS" "$HOME/code/kload/kload" --vus 1000 --ramp-up 5s \
    --duration 15s --ramp-down 1s --grace 1s --quiet --url "http://127.0.0.1:$PORT" --tokens "$ROOT/seed/tokens.json" \
    > "$OUT/warmup.txt" 2>&1 ) || true
( cd "$BENCH" && exec $KL --unit="$LUNIT" $IN taskset -c "$GENCPUS" "$HOME/code/kload/kload" --vus "$VUS" \
    --ramp-up "$RAMP" --duration "$HOLD" --ramp-down 5s --grace 5s --quiet \
    --url "http://127.0.0.1:$PORT" --tokens "$ROOT/seed/tokens.json" --json "$OUT/kload.json" > "$OUT/kload.txt" 2>&1 ) &
KPID=$!
( while kill -0 "$KPID" 2>/dev/null; do echo "$(date +%s) $(rssmb) MB cg $(( $(cat $CG/memory.current) / 1048576 )) MB"; sleep 5; done ) > "$OUT/server-stats.txt" &
STATP=$!
sleep "${RAMP%s}"; read c0 u0 < <(cpu); s0=$(date +%s.%N)
sleep "${HOLD%s}"; read c1 u1 < <(cpu); s1=$(date +%s.%N)
wait "$KPID" || true
kill $STATP 2>/dev/null || true
RSSPK=$(awk '{if($2>m)m=$2} END{print m+0}' "$OUT/server-stats.txt")
CGPEAK=$(( $(cat "$CG/memory.peak") / 1048576 ))
ALIVE=$(spids | wc -l)
echo "load after: $(cut -d' ' -f1-3 /proc/loadavg); io psi: $(head -1 /proc/pressure/io)" >> "$OUT/env.txt"
python3 -I - "$OUT" "$B" "$VUS" "$HOLD" "$c0" "$c1" "$u0" "$u1" "$s0" "$s1" "$RSSPK" "$IDLE" "$CGPEAK" "$ALIVE" <<'PY' | tee -a "$W/results.tsv"
import json,sys
out,b,vus,hold,c0,c1,u0,u1,s0,s1,rss,idle,cgpeak,alive=sys.argv[1:]
try: j=json.load(open(out+"/kload.json"))
except Exception as e: print(f"{b}\tVUS={vus}\thold={hold}\tNOJSON\t{e}\t{out.split('/')[-1]}"); sys.exit()
h=j["hold"]; wall=float(s1)-float(s0); cpu=(int(c1)-int(c0))/1e6; ucpu=(int(u1)-int(u0))/1e6
hreqs=h["reqs"] or 1
ok="PASS" if j["pass"] else "FAIL"
print(f"{b}\tVUS={vus}\thold={hold}\t{ok}\treqs={j['reqs']}\terr={j['fail_rate']*100:.3f}%\tp95={j['p95_ms']:.1f}\tp99={j['p99_ms']:.1f}\t"
      f"hold_p99={h['p99_ms']:.1f}\tcpu={cpu/wall*100:.0f}%\tus/req={cpu/hreqs*1e6:.2f}\t(user {ucpu/hreqs*1e6:.2f})\trsspk={rss}MB\tidle={idle}MB\t"
      f"cgpeak={cgpeak}MB\talive={alive}\tgenstalls={j['gen_loop_stalls']}\tmaxopen={j['max_open']}\t{out.split('/')[-1]}")
PY
cleanup; trap - EXIT
sleep 1
rm -f "$OUT"/feed.db* "$DBD"/feed.db*; [ "$DBD" != "$OUT" ] && rmdir "$DBD"; true
