#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: gcc/make (for libkj.so: SQLite, liburing and our C shim), Temurin
# JDK 25 and the Kotlin 2.4.21 compiler, into /opt, pinned and sha256-checked. (build.sh fetches the pinned SQLite
# amalgamation and liburing sources.)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get install -y --no-install-recommends build-essential curl unzip ca-certificates openssl

JDK_URL=https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.4.1%2B1/OpenJDK25U-jdk_x64_linux_hotspot_25.0.4.1_1.tar.gz
JDK_SHA=dbb698396d478e7fa2b1e50f4103324b2a99b90569ee27c33f2261f9215cf41e
KOTLINC_URL=https://github.com/JetBrains/kotlin/releases/download/v2.4.21/kotlin-compiler-2.4.21.zip
KOTLINC_SHA=7cc140e76daf416a0424a5557f99afd7ca89ebd463ea1101261e3e01c33e75cd

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
if [ ! -x /opt/jdk-25/bin/java ]; then
  curl -fsSL --retry 3 "$JDK_URL" -o "$tmp/jdk.tgz"
  echo "$JDK_SHA  $tmp/jdk.tgz" | sha256sum -c -
  rm -rf /opt/jdk-25 && mkdir -p /opt/jdk-25 && tar -xzf "$tmp/jdk.tgz" -C /opt/jdk-25 --strip-components=1
fi
if [ ! -x /opt/kotlinc-2.4.21/bin/kotlinc ]; then
  curl -fsSL --retry 3 "$KOTLINC_URL" -o "$tmp/kotlinc.zip"
  echo "$KOTLINC_SHA  $tmp/kotlinc.zip" | sha256sum -c -
  rm -rf /opt/kotlinc-2.4.21 "$tmp/kc" && mkdir -p "$tmp/kc" && unzip -q "$tmp/kotlinc.zip" -d "$tmp/kc"
  mv "$tmp/kc/kotlinc" /opt/kotlinc-2.4.21
fi
/opt/jdk-25/bin/java -version
/opt/kotlinc-2.4.21/bin/kotlinc -version
