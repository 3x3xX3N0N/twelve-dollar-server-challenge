#!/usr/bin/env bash
# Runs the server in the foreground. Config: SQLITE_PATH, JWT_SECRET, HOST, PORT.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
JAVA=java
[ -x /opt/jdk-25/bin/java ] && JAVA=/opt/jdk-25/bin/java
exec "$JAVA" \
  -XX:+UseSerialGC -Xms192m -Xmx448m -Xss512k \
  -XX:+UseCompactObjectHeaders -XX:-UsePerfData -XX:TieredStopAtLevel=4 \
  --enable-native-access=ALL-UNNAMED \
  -cp "$DIR/build/lib/*" nio.MainKt
