#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: a C toolchain (gcc builds the C shim, with PGO, and links the native image;
# native-image also links zlib), GraalVM Community 25.5.5 (JDK 25.0.5, with native-image) and the Kotlin 2.4.21
# compiler, both from their official release tarballs, pinned and sha256-checked, into /opt.
# (build.sh fetches the pinned SQLite amalgamation and liburing.)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get install -y --no-install-recommends curl unzip ca-certificates openssl make gcc libc6-dev zlib1g-dev

GRAAL_URL=https://github.com/graalvm/graalvm-ce-builds/releases/download/graal-25.5.5.0.3/graalvm-community-jdk-25i5-25.0.5.0.3_linux-x64_bin.tar.gz
GRAAL_SHA=c6438dee6c3ade2220d40b7ccdcad24b512d30e233e61bb4fc70519522de34ef
KOTLIN_URL=https://github.com/JetBrains/kotlin/releases/download/v2.4.21/kotlin-compiler-2.4.21.zip
KOTLIN_SHA=7cc140e76daf416a0424a5557f99afd7ca89ebd463ea1101261e3e01c33e75cd

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
if [ ! -x /opt/graalvm-jdk-25.0.5/bin/native-image ]; then
  curl -fsSL --retry 3 "$GRAAL_URL" -o "$tmp/graal.tgz"
  echo "$GRAAL_SHA  $tmp/graal.tgz" | sha256sum -c -
  rm -rf /opt/graalvm-jdk-25.0.5 && mkdir -p /opt/graalvm-jdk-25.0.5
  tar -xzf "$tmp/graal.tgz" -C /opt/graalvm-jdk-25.0.5 --strip-components=1
fi
if [ ! -x /opt/kotlinc-2.4.21/bin/kotlinc ]; then
  curl -fsSL --retry 3 "$KOTLIN_URL" -o "$tmp/kotlin.zip"
  echo "$KOTLIN_SHA  $tmp/kotlin.zip" | sha256sum -c -
  rm -rf /opt/kotlinc-2.4.21 "$tmp/kotlinc" && unzip -q "$tmp/kotlin.zip" -d "$tmp" && mv "$tmp/kotlinc" /opt/kotlinc-2.4.21
fi
# Optional, only with KG_GRAAL=oracle (knob, not the default): Oracle GraalVM 25.0.4 (GraalVM Free Terms and
# Conditions licence, see README), from Oracle's archive URL, sha256 as published next to it (<url>.sha256).
ORACLE_URL=https://download.oracle.com/graalvm/25/archive/graalvm-jdk-25.0.4_linux-x64_bin.tar.gz
ORACLE_SHA=76007c309f821aaf435bce63162ea0395587fc77350801c81643fe7feea37276
if [ "${KG_GRAAL:-ce}" = oracle ] && [ ! -x /opt/oracle-graalvm-jdk-25.0.4/bin/native-image ]; then
  curl -fsSL --retry 3 "$ORACLE_URL" -o "$tmp/oracle.tgz"
  echo "$ORACLE_SHA  $tmp/oracle.tgz" | sha256sum -c -
  rm -rf /opt/oracle-graalvm-jdk-25.0.4 && mkdir -p /opt/oracle-graalvm-jdk-25.0.4
  tar -xzf "$tmp/oracle.tgz" -C /opt/oracle-graalvm-jdk-25.0.4 --strip-components=1
fi
/opt/graalvm-jdk-25.0.5/bin/java -version
/opt/graalvm-jdk-25.0.5/bin/native-image --version
