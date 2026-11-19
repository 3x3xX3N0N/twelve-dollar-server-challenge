#!/usr/bin/env bash
# Builds build/app.jar and build/libkj.so as a normal user, from source:
#   1. downloads the SQLite 3.54.1 amalgamation (SHA3-256 as published on sqlite.org) and liburing 2.9 (sha256),
#   2. compiles them with csrc/*.c into build/libkj.so (gcc; sqlite3.c is used unchanged: csrc/db.c #includes it
#      so the B-tree read paths can use SQLite's cursor API),
#   3. compiles src/*.kt with kotlinc into build/app.jar (Kotlin stdlib included).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
if [ -x /opt/jdk-25/bin/java ]; then export JAVA_HOME=/opt/jdk-25; fi
KOTLINC="${KOTLINC:-/opt/kotlinc-2.4.21/bin/kotlinc}"
[ -x "$KOTLINC" ] || KOTLINC="$(command -v kotlinc)"
# Two malloc arenas and a capped compiler heap keep the build well inside the box (peak RSS in README).
export MALLOC_ARENA_MAX=2 JAVA_OPTS="${JAVA_OPTS:--Xmx600m -XX:+UseSerialGC}"

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

CC="${CC:-gcc}"
if [ ! -f "$C/liburing.a" ]; then
  ( cd "$D/liburing" && ./configure --cc="$CC" >/dev/null && make -s -C src CC="$CC" CFLAGS="-O2 -fPIC" liburing.a )
  cp "$D/liburing/src/liburing.a" "$C/liburing.a"
fi
# SQLite: threads in separate connections (checkpointer, committer), QPSG (plans fixed at prepare), no per-call
# memory stats.
SQLITE_OPTS="-DSQLITE_THREADSAFE=2 -DSQLITE_ENABLE_QPSG -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DQS=0
  -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE -DSQLITE_USE_ALLOCA
  -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 -DSQLITE_LIKE_DOESNT_MATCH_BLOBS"
CFLAGS="${KJ_CFLAGS:--O2} -fPIC -g0 -Wall -Wno-unused-function"
$CC $CFLAGS $SQLITE_OPTS -w -I"$D/sqlite" -I"$ROOT/csrc" -c "$ROOT/csrc/db.c" -o "$C/db.o"
$CC $CFLAGS -I"$D/liburing/src/include" -I"$ROOT/csrc" -c "$ROOT/csrc/uring.c" -o "$C/uring.o"
$CC $CFLAGS -I"$ROOT/csrc" -c "$ROOT/csrc/jvm.c" -o "$C/jvm.o"
$CC -shared -Wl,-z,now -o "$B/libkj.so" "$C/db.o" "$C/uring.o" "$C/jvm.o" "$C/liburing.a" -lpthread -lm

"$KOTLINC" -jvm-target 21 -Xno-param-assertions -Xno-call-assertions -Xno-receiver-assertions -nowarn \
  -include-runtime -d "$B/app.jar" "$ROOT"/src/*.kt
ls -la "$B/app.jar" "$B/libkj.so"
