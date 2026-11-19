#!/usr/bin/env bash
# Runs the server in the foreground. Config: SQLITE_PATH, JWT_SECRET, HOST, PORT (optional knobs in README).
# KG_MODE=native (default): the GraalVM native-image build/server.
# KG_MODE=jit: the same jar on the GraalVM JDK (Graal JIT), Serial GC, fixed heap.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
GRAAL="${GRAALVM_HOME:-/opt/graalvm-jdk-25.0.5}"
export KN_LIB="$DIR/build/libkn.so"
HEAP="${KG_HEAP:-256m}"
MODE="${KG_MODE:-native}"
if [ "$MODE" = native ] && [ ! -x "$DIR/build/server" ]; then MODE=jit; fi   # built with KG_NATIVE=0
if [ "$MODE" = native ]; then
  exec "$DIR/build/server" -Xms"$HEAP" -Xmx"$HEAP"
fi
exec "$GRAAL/bin/java" -XX:+UseSerialGC -Xms"$HEAP" -Xmx"$HEAP" -XX:+AlwaysPreTouch -Xss1m \
  -XX:-UsePerfData -XX:+UseCompactObjectHeaders --enable-native-access=ALL-UNNAMED \
  -cp "$DIR/build/app.jar:$DIR/build/kotlin-stdlib.jar" app.MainKt
