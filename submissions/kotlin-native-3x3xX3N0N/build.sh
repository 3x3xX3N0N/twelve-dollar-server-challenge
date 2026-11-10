#!/usr/bin/env bash
# Builds build/server.kexe as a normal user, from source:
#   1. downloads the SQLite 3.54.1 amalgamation (SHA3-256 as published on sqlite.org) and liburing 2.9 (sha256),
#   2. compiles them and csrc/*.c with the clang + glibc sysroot that ship with Kotlin/Native (fetched by Kotlin/Native
#      itself into ~/.konan on first use), so the C objects match what the Kotlin/Native linker links against,
#   3. cinterop (kn.def -> klib) and kotlinc-native -opt.
# sqlite3.c is used unchanged; csrc/db.c #includes it so the B-tree read paths can use SQLite's cursor API.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
KN="${KN_HOME:-/opt/kotlin-native-2.4.21}"
[ -x "$KN/bin/kotlinc-native" ] || KN="$(dirname "$(dirname "$(command -v kotlinc-native)")")"
if [ -x /opt/jdk-25/bin/java ]; then export JAVA_HOME=/opt/jdk-25; fi
# Two malloc arenas and a capped heap keep the compiler inside a 2 GB box.
export MALLOC_ARENA_MAX=2 JAVA_OPTS="${JAVA_OPTS:--Xmx1200m -XX:+UseSerialGC}"

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

# Kotlin/Native's toolchain (clang, lld, the x86_64 glibc sysroot): a one-line cinterop run makes it download it.
KONAN="${KONAN_DATA_DIR:-$HOME/.konan}/dependencies"
if ! ls -d "$KONAN"/llvm-*-x86_64-linux-essentials-* >/dev/null 2>&1; then
  echo "headers = stdint.h" > "$B/probe.def"
  "$KN/bin/cinterop" -def "$B/probe.def" -o "$B/probe" >/dev/null
fi
LLVM="$(ls -d "$KONAN"/llvm-*-x86_64-linux-essentials-* | head -1)"
GT="$(ls -d "$KONAN"/x86_64-unknown-linux-gnu-gcc-* | head -1)"
CC="$LLVM/bin/clang --target=x86_64-unknown-linux-gnu --sysroot=$GT/x86_64-unknown-linux-gnu/sysroot --gcc-toolchain=$GT"

if [ ! -f "$C/liburing.a" ]; then
  ( cd "$D/liburing" && ./configure --cc="$CC" >/dev/null && make -s -C src CC="$CC" AR="$LLVM/bin/llvm-ar" RANLIB=true liburing.a )
  cp "$D/liburing/src/liburing.a" "$C/liburing.a"
fi
# SQLite: threads in separate connections (checkpointer), QPSG (plans fixed at prepare), no per-call memory stats.
SQLITE_OPTS="-DSQLITE_THREADSAFE=2 -DSQLITE_ENABLE_QPSG -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DQS=0
  -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE -DSQLITE_USE_ALLOCA
  -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 -DSQLITE_LIKE_DOESNT_MATCH_BLOBS"
CFLAGS="-O2 -fPIC -g0 -Wall -Wno-unused-function"
$CC $CFLAGS $SQLITE_OPTS -w -I"$D/sqlite" -I"$ROOT/csrc" -c "$ROOT/csrc/db.c" -o "$C/db.o"
$CC $CFLAGS -I"$D/liburing/src/include" -I"$ROOT/csrc" -c "$ROOT/csrc/uring.c" -o "$C/uring.o"
rm -f "$C/libkn.a" && "$LLVM/bin/llvm-ar" rcs "$C/libkn.a" "$C/db.o" "$C/uring.o"

"$KN/bin/cinterop" -def "$ROOT/kn.def" -compiler-option -I"$ROOT/csrc" -libraryPath "$C" \
  -staticLibrary liburing.a -o "$B/knc"
"$KN/bin/kotlinc-native" -opt -e app.main -l "$B/knc.klib" "$ROOT"/src/*.kt -o "$B/server"
ls -la "$B/server.kexe"
