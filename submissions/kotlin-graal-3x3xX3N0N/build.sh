#!/usr/bin/env bash
# Builds, as a normal user, from source:
#   1. the SQLite 3.54.1 amalgamation (SHA3-256 as published on sqlite.org) and liburing 2.9 (sha256), downloaded;
#   2. build/libkn.so: csrc/*.c (our io_uring + SQLite B-tree shim; db.c #includes sqlite3.c unchanged) + liburing;
#   3. build/app.jar: src/*.kt with kotlinc 2.4.21 on the GraalVM JDK;
#   4. build/server: a GraalVM native-image of the same jar (KG_NATIVE=0 skips it; start.sh then runs the JIT mode).
# Peak memory: native-image is the big step; its heap is capped at KG_NI_XMX (default 800m): ~1.1 GB peak on one core, see README.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
GRAAL="${GRAALVM_HOME:-/opt/graalvm-jdk-25.0.5}"
KC="${KOTLINC_HOME:-/opt/kotlinc-2.4.21}"
[ -x "$GRAAL/bin/java" ] || { echo "GraalVM not found at $GRAAL (run install.sh)" >&2; exit 1; }
[ -x "$KC/bin/kotlinc" ] || { echo "kotlinc not found at $KC (run install.sh)" >&2; exit 1; }
export JAVA_HOME="$GRAAL" PATH="$GRAAL/bin:$PATH" MALLOC_ARENA_MAX=2

SQLITE_URL=https://sqlite.org/2026/sqlite-amalgamation-3540100.zip
SQLITE_SHA3=92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30
URING_URL=https://github.com/axboe/liburing/archive/refs/tags/liburing-2.9.tar.gz
URING_SHA=897b1153b55543e8b92a5a3eb9b906537a5fedcf8afaf241f8b8787940c79f8d

B="$ROOT/build"; D="$B/deps"; C="$B/c"
mkdir -p "$D" "$C"
if [ ! -f "$D/sqlite/sqlite3.c" ]; then
  curl -fsSL --retry 3 "$SQLITE_URL" -o "$D/sqlite.zip"
  got=$(openssl dgst -sha3-256 -r "$D/sqlite.zip" | cut -d' ' -f1)
  [ "$got" = "$SQLITE_SHA3" ] || { echo "sqlite amalgamation: SHA3-256 $got, expected $SQLITE_SHA3" >&2; exit 1; }
  mkdir -p "$D/sqlite" && unzip -j -o -q "$D/sqlite.zip" '*/sqlite3.c' '*/sqlite3.h' -d "$D/sqlite" && rm "$D/sqlite.zip"
fi
if [ ! -f "$D/liburing/src/include/liburing.h" ]; then
  curl -fsSL --retry 3 "$URING_URL" -o "$D/liburing.tgz"
  echo "$URING_SHA  $D/liburing.tgz" | sha256sum -c -
  rm -rf "$D/liburing" && mkdir -p "$D/liburing" && tar -xzf "$D/liburing.tgz" -C "$D/liburing" --strip-components=1 && rm "$D/liburing.tgz"
fi

# ---- 2. the C shim
CC="${CC:-gcc}"
if [ ! -f "$C/liburing.a" ]; then
  ( cd "$D/liburing" && ./configure --cc="$CC" >/dev/null && make -s -C src CC="$CC" liburing.a )
  cp "$D/liburing/src/liburing.a" "$C/liburing.a"
fi
# SQLite: threads in separate connections (checkpointer, committer), QPSG (plans fixed at prepare), no memory stats.
SQLITE_OPTS="-DSQLITE_THREADSAFE=2 -DSQLITE_ENABLE_QPSG -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DQS=0
  -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE -DSQLITE_USE_ALLOCA
  -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 -DSQLITE_LIKE_DOESNT_MATCH_BLOBS"
# -O3 -march=native: build.sh runs on the box, so this targets the box's own CPU, with vectors kept at 256 bits
# (no AVX-512 clock drop on Cascade Lake). KG_CFLAGS overrides. Measured (read micro-benchmark, 5 alternating pairs,
# LOCAL): the feed plan 6.25-6.45 -> 5.76-6.15 us per call against -O2, the post plan unchanged.
CFLAGS="${KG_CFLAGS:--O3 -march=native -mprefer-vector-width=256} -fPIC -g0 -Wall -Wno-unused-function"
$CC $CFLAGS $SQLITE_OPTS -w -I"$D/sqlite" -I"$ROOT/csrc" -c "$ROOT/csrc/db.c" -o "$C/db.o"
$CC $CFLAGS -I"$D/liburing/src/include" -I"$ROOT/csrc" -c "$ROOT/csrc/uring.c" -o "$C/uring.o"
$CC $CFLAGS -I"$ROOT/csrc" -c "$ROOT/csrc/jv.c" -o "$C/jv.o"
$CC -shared -o "$B/libkn.so" "$C/db.o" "$C/uring.o" "$C/jv.o" "$C/liburing.a" -lpthread -ldl -lm

# ---- 3. the jar (Kotlin stdlib next to it)
JAVA_OPTS="-Xmx700m -XX:+UseSerialGC" "$KC/bin/kotlinc" -jvm-target 25 -Xno-param-assertions -Xno-call-assertions \
  -Xno-receiver-assertions -nowarn "$ROOT"/src/*.kt -d "$B/app.jar"
cp "$KC/lib/kotlin-stdlib.jar" "$B/kotlin-stdlib.jar"

# ---- 4. native-image (closed world: the FFM handles in app.H are created here, at image build time)
if [ "${KG_NATIVE:-1}" != "0" ]; then
  # x86-64-v3 (AVX2, BMI, FMA): the box's Cascade Lake has it. Not -march=native: on Cascade Lake that would allow
  # AVX-512, and 512-bit code lowers the core's clock for what follows. KG_MARCH overrides (native, compatibility).
  MARCH=("-march=${KG_MARCH:-x86-64-v3}")
  rm -f "$B/server"
  native-image -J-Xmx"${KG_NI_XMX:-800m}" -J-Djava.io.tmpdir="${TMPDIR:-/tmp}" --gc=serial "${MARCH[@]}" -O"${KG_NI_O:-2}" \
    --enable-native-access=ALL-UNNAMED --initialize-at-build-time=app.H ${KG_NI_EXTRA:-} \
    -H:+UnlockExperimentalVMOptions -H:+ForeignAPISupport -H:-UnlockExperimentalVMOptions \
    -cp "$B/app.jar:$B/kotlin-stdlib.jar:$ROOT/native-image" -o "$B/server" app.MainKt
  ls -la "$B/server"
fi
ls -la "$B/libkn.so" "$B/app.jar"
