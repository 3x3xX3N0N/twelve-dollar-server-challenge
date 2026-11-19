#!/usr/bin/env bash
# Runs the server in the foreground. Config: SQLITE_PATH, JWT_SECRET, HOST, PORT (optional knobs in README).
DIR="$(cd "$(dirname "$0")" && pwd)"
JAVA=java
[ -x /opt/jdk-25/bin/java ] && JAVA=/opt/jdk-25/bin/java
exec "$JAVA" -XX:+UseSerialGC -Xms96m -Xmx96m -XX:+UseCompactObjectHeaders -XX:-UsePerfData \
  --enable-native-access=ALL-UNNAMED -Dkj.lib="$DIR/build/libkj.so" ${KJ_JVM_FLAGS:-} \
  -cp "$DIR/build/app.jar" app.MainKt
