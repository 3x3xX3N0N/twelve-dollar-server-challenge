#!/usr/bin/env bash
# Runs the server in the foreground. Config: SQLITE_PATH, JWT_SECRET, HOST, PORT (optional knobs in README).
# KG_MODE=native (default): the GraalVM native-image build/server.
# KG_MODE=jit: the same jar on the GraalVM JDK (Graal JIT), Serial GC, fixed heap.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
GRAAL="${GRAALVM_HOME:-/opt/graalvm-jdk-25.0.5}"
export KN_LIB="$DIR/build/libkn.so"
HEAP="${KG_HEAP:-96m}"   # the loop allocates nothing on the GET path; ~25 MB of arrays live in the heap
MODE="${KG_MODE:-native}"
if [ "$MODE" = native ] && [ ! -x "$DIR/build/server" ]; then MODE=jit; fi   # built with KG_NATIVE=0
if [ "$MODE" = native ]; then
  exec "$DIR/build/server" -Xms"$HEAP" -Xmx"$HEAP"
fi
exec "$GRAAL/bin/java" -XX:+UseSerialGC -Xms"$HEAP" -Xmx"$HEAP" -Xss1m \
  -XX:ReservedCodeCacheSize=64m -XX:MaxMetaspaceSize=64m -XX:-UsePerfData -XX:+UseCompactObjectHeaders --enable-native-access=ALL-UNNAMED ${KG_JAVA_OPTS:-} \
  -cp "$DIR/build/app.jar:$DIR/build/kotlin-stdlib.jar" app.MainKt
