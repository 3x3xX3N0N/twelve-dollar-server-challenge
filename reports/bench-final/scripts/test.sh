#!/usr/bin/env bash
# build.sh <name>: builds one bench-final build in its own worktree under bench-wt, nice 10, core 14, 3 GB scope.
set -uo pipefail
W=/mnt/nebula/excal/dev0/tdsc-fleet/bench-final-work; WT=/mnt/nebula/excal/dev0/tdsc-fleet/bench-wt; F=/mnt/nebula/excal/dev0/tdsc-fleet
N="$1"; export TMPDIR=$W/tmp
case "$N" in
  kn-final|kn-b3) D=$WT/$N/submissions/kotlin-native-3x3xX3N0N; export KN_HOME=$HOME/.local/opt/kotlin-native-prebuilt-linux-x86_64-2.4.21 KN_TRAIN_PORT=18151 ;;
  jvm-uring) D=$WT/$N/submissions/kotlin-jvm-uring-3x3xX3N0N; export KOTLINC=$F/b1-graal-work/kotlinc/bin/kotlinc ;;
  graal-ce|graal-nocpgo) D=$WT/$N/submissions/kotlin-graal-3x3xX3N0N; export GRAALVM_HOME=$F/b1-graal-work/graalvm KOTLINC_HOME=$F/b1-graal-work/kotlinc \
      KG_NI_EXTRA=--native-compiler-options=-L$F/b1-graal-work/zlib KG_TRAIN_PORT=18152; [ $N = graal-nocpgo ] && export KG_CPGO=0 ;;
  nio-v3) D=$WT/$N/submissions/kotlin-nio-3x3xX3N0N ;;
  dav) D=$WT/dav; export FEED_JDK=$F/b2-work/opt/jdk-27 ;;
esac
cd "$D"
NET=""; [ $N = dav ] && NET="bwrap --unshare-net --dev-bind / / --"; export PORT=18153
/usr/bin/time -v -o $W/test-$N.time systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 -p AllowedCPUs=14 \
  -E TMPDIR -E KN_HOME -E KN_TRAIN_PORT -E KOTLINC -E GRAALVM_HOME -E KOTLINC_HOME -E KG_NI_EXTRA -E KG_TRAIN_PORT -E KG_CPGO -E FEED_JDK -E PORT \
  taskset -c 14 nice -n 10 $NET bash /home/excal/code/tdsc-wt/bench-final/test/run.sh "$D" > $W/test-$N.log 2>&1; rc=$?
echo "$N rc=$rc $(grep -E "passed|failed|PASS|FAIL" $W/test-$N.log | tail -2 | tr "\n" " ")"
