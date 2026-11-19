#!/usr/bin/env bash
# Builds, as a normal user, from source:
#   1. the SQLite 3.54.1 amalgamation (SHA3-256 as published on sqlite.org) and liburing 2.9 (sha256), downloaded;
#   2. build/libkn.so: csrc/*.c (our io_uring + SQLite B-tree shim; db.c #includes sqlite3.c unchanged) + liburing;
#   3. build/app.jar: src/*.kt (+ train/Train.kt, the build-time training client) with kotlinc 2.4.21 on the GraalVM JDK;
#   4. build/server: a GraalVM native-image of the same jar (KG_NATIVE=0 skips it; start.sh then runs the JIT mode).
#   5. Profile-guided builds (see README "Knobs"): C PGO of libkn.so (default; KG_CPGO=0 turns it off) and
#      KG_PGO=1 (native-image PGO, Oracle GraalVM only; does not fit the box, off). The profile is recorded HERE, during this build, on this machine: the
#      instrumented build serves a synthetic scratch database (train/mkdb.c: random rows, none of the seed) to the
#      training client for ~KG_TRAIN_REQS requests, then the final build reads that profile. No profile is committed.
#      If training fails, the build falls back to the plain build and says so.
# Peak memory: native-image is the big step; its heap is capped at KG_NI_XMX (default 800m): ~1.1 GB peak on one core, see README.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
case "${KG_GRAAL:-ce}" in
  ce) GRAAL="${GRAALVM_HOME:-/opt/graalvm-jdk-25.0.5}" ;;
  oracle) GRAAL="${GRAALVM_HOME:-/opt/oracle-graalvm-jdk-25.0.4}" ;;
  *) echo "KG_GRAAL must be ce or oracle" >&2; exit 1 ;;
esac
KC="${KOTLINC_HOME:-/opt/kotlinc-2.4.21}"
[ -x "$GRAAL/bin/java" ] || { echo "GraalVM not found at $GRAAL (run install.sh)" >&2; exit 1; }
[ -x "$KC/bin/kotlinc" ] || { echo "kotlinc not found at $KC (run install.sh)" >&2; exit 1; }
export JAVA_HOME="$GRAAL" PATH="$GRAAL/bin:$PATH" MALLOC_ARENA_MAX=2
PGO="${KG_PGO:-0}"; CPGO="${KG_CPGO:-1}"   # C PGO on by default (README: feed plan -15 %), native-image PGO off
[ "${KG_NATIVE:-1}" = 0 ] && PGO=0
if [ "$PGO" = 1 ] && ! native-image --help 2>&1 | grep -q -- --pgo-instrument; then
  echo "KG_PGO=1 needs Oracle GraalVM (KG_GRAAL=oracle); this native-image has no --pgo-instrument" >&2; exit 1
fi

SQLITE_URL=https://sqlite.org/2026/sqlite-amalgamation-3540100.zip
SQLITE_SHA3=92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30
URING_URL=https://github.com/axboe/liburing/archive/refs/tags/liburing-2.9.tar.gz
URING_SHA=897b1153b55543e8b92a5a3eb9b906537a5fedcf8afaf241f8b8787940c79f8d

B="$ROOT/build"; D="$B/deps"; C="$B/c"; P="$B/pgo"
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
# gcc by default; CC=clang works too (with llvm-profdata for the PGO step; apt: clang llvm). Measured equal with PGO.
CC="${CC:-gcc}"
command -v "$CC" >/dev/null || { echo "C compiler $CC not found" >&2; exit 1; }
IS_CLANG=0; "$CC" --version 2>/dev/null | grep -q clang && IS_CLANG=1
if [ "$CPGO" = 1 ] && [ "$IS_CLANG" = 1 ]; then
  # llvm-profdata of the same LLVM as the compiler (Ubuntu: /usr/bin/clang -> /usr/lib/llvm-18/bin/clang)
  PROFDATA="${KG_PROFDATA:-$(dirname "$(readlink -f "$(command -v "$CC")")")/llvm-profdata}"
  [ -x "$PROFDATA" ] || PROFDATA="$(command -v llvm-profdata || true)"
  [ -x "$PROFDATA" ] || { echo "KG_CPGO=1 with clang needs llvm-profdata (apt: llvm)" >&2; exit 1; }
fi
if [ ! -f "$C/liburing.a" ]; then
  ( cd "$D/liburing" && ./configure --cc=gcc >/dev/null && make -s -C src CC=gcc liburing.a )
  cp "$D/liburing/src/liburing.a" "$C/liburing.a"
fi
# SQLite: threads in separate connections (checkpointer, committer), QPSG (plans fixed at prepare), no memory stats.
SQLITE_OPTS="-DSQLITE_THREADSAFE=2 -DSQLITE_ENABLE_QPSG -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DQS=0
  -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE -DSQLITE_USE_ALLOCA
  -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 -DSQLITE_LIKE_DOESNT_MATCH_BLOBS"
# -O3 -march=native: build.sh runs on the box, so this targets the box's own CPU, with vectors kept at 256 bits
# (no AVX-512 clock drop on Cascade Lake). KG_CFLAGS overrides. Measured (read micro-benchmark, 5 alternating pairs,
# LOCAL): the feed plan 6.25-6.45 -> 5.76-6.15 us per call against -O2, the post plan unchanged.
BASE_CFLAGS="${KG_CFLAGS:--O3 -march=native -mprefer-vector-width=256} -fPIC -g0 -Wall -Wno-unused-function"
# build_c plain|gen|use: libkn.so without a profile, instrumented, or optimized with the recorded profile.
build_c() {
  local pf=""
  case "$1" in
    gen) if [ "$IS_CLANG" = 1 ]; then pf="-fprofile-generate=$P/c"; else pf="-fprofile-generate -fprofile-update=prefer-atomic -fprofile-dir=$P/c"; fi ;;
    use) if [ "$IS_CLANG" = 1 ]; then pf="-fprofile-use=$P/c.profdata -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date"
         else pf="-fprofile-use -fprofile-partial-training -Wno-missing-profile -fprofile-dir=$P/c"; fi ;;
  esac
  local CFLAGS="$BASE_CFLAGS $pf"
  $CC $CFLAGS $SQLITE_OPTS -w -I"$D/sqlite" -I"$ROOT/csrc" -c "$ROOT/csrc/db.c" -o "$C/db.o"
  $CC $CFLAGS -I"$D/liburing/src/include" -I"$ROOT/csrc" -c "$ROOT/csrc/uring.c" -o "$C/uring.o"
  $CC $CFLAGS -I"$ROOT/csrc" -c "$ROOT/csrc/jv.c" -o "$C/jv.o"
  $CC $pf -shared -o "$B/libkn.so" "$C/db.o" "$C/uring.o" "$C/jv.o" "$C/liburing.a" -lpthread -ldl -lm
}
if [ "$CPGO" = 1 ]; then rm -rf "$P/c" "$P/c.profdata"; build_c gen; else build_c plain; fi

# ---- 3. the jar (Kotlin stdlib next to it)
JAVA_OPTS="-Xmx700m -XX:+UseSerialGC" "$KC/bin/kotlinc" -jvm-target 25 -Xno-param-assertions -Xno-call-assertions \
  -Xno-receiver-assertions -nowarn "$ROOT"/src/*.kt "$ROOT/train/Train.kt" -d "$B/app.jar"
cp "$KC/lib/kotlin-stdlib.jar" "$B/kotlin-stdlib.jar"

# ---- 4. native-image (closed world: the FFM handles in app.H are created here, at image build time)
# x86-64-v3 (AVX2, BMI, FMA): the box's Cascade Lake has it. Not -march=native: on Cascade Lake that would allow
# AVX-512, and 512-bit code lowers the core's clock for what follows. KG_MARCH overrides (native, compatibility).
# The FFM handles in app.H are created at image build time with CE 25.5; Oracle GraalVM 25.0.4's builder fails on
# those ("unexpected input could not be handled: linkToNative" while parsing the first invokeExact), so with
# KG_GRAAL=oracle app.H is initialized when the server starts (KG_NI_BUILDINIT=0/1 overrides).
INIT_H=(); [ "${KG_NI_BUILDINIT:-$([ "${KG_GRAAL:-ce}" = ce ] && echo 1 || echo 0)}" = 1 ] && INIT_H=(--initialize-at-build-time=app.H)
native_image() {  # native_image <output> <extra flags...>
  local out="$1"; shift
  rm -f "$out"
  native-image -J-Xmx"${NI_XMX:-${KG_NI_XMX:-800m}}" -J-Djava.io.tmpdir="${TMPDIR:-/tmp}" --gc=serial "-march=${KG_MARCH:-x86-64-v3}" \
    --enable-native-access=ALL-UNNAMED "${INIT_H[@]}" ${KG_NI_EXTRA:-} "$@" \
    -H:+UnlockExperimentalVMOptions -H:+ForeignAPISupport -H:-UnlockExperimentalVMOptions \
    -cp "$B/app.jar:$B/kotlin-stdlib.jar:$ROOT/native-image" -o "$out" app.MainKt
}
NI_O="-O${KG_NI_O:-2}"
if [ "${KG_NATIVE:-1}" != "0" ]; then
  # The instrumented image needs far more builder heap: 800m and 1050m both end in OutOfMemoryError; with 2g it peaks
  # at 2.2 GB RSS (LOCAL), more than the 2 GB box has, so KG_PGO=1 does not fit the box's 1.5 GB build cap (README).
  if [ "$PGO" = 1 ]; then NI_XMX="${KG_NI_XMX_INST:-2g}" native_image "$B/server" --pgo-instrument; else native_image "$B/server" "$NI_O"; fi
fi

# ---- 5. training run (only for KG_PGO=1 / KG_CPGO=1): instrumented server + synthetic database + training client
train() {
  local T="$B/train" port="${KG_TRAIN_PORT:-3999}" secret="train-$RANDOM$RANDOM$RANDOM" pid rc=0
  rm -rf "$T" && mkdir -p "$T" "$P"   # (set -e is off inside a function called from `if`: every step checks)
  $CC -O1 -I"$D/sqlite" "$ROOT/train/mkdb.c" -L"$B" -lkn -Wl,-rpath,"$B" -o "$T/mkdb" || return 1
  # mkdb's own SQLite calls must not land in the profile (it links the instrumented libkn.so too)
  LLVM_PROFILE_FILE="$T/mkdb.profraw" GCOV_PREFIX="$T/mkdb-gcov" \
    "$T/mkdb" "$T/train.db" "${KG_TRAIN_USERS:-20000}" "${KG_TRAIN_POSTS:-50000}" "${KG_TRAIN_LIKES:-200000}" || return 1
  local srv=("$B/server" -Xms96m -Xmx96m)
  [ "$PGO" = 1 ] && srv+=("-XX:ProfilesDumpFile=$P/server.iprof")
  [ -x "$B/server" ] || srv=("$GRAAL/bin/java" -XX:+UseSerialGC -Xmx96m --enable-native-access=ALL-UNNAMED -cp "$B/app.jar:$B/kotlin-stdlib.jar" app.MainKt)
  ( cd "$T" && KN_LIB="$B/libkn.so" SQLITE_PATH="$T/train.db" JWT_SECRET="$secret" HOST=127.0.0.1 PORT="$port" \
      LLVM_PROFILE_FILE="$P/c/%p-%m.profraw" exec "${srv[@]}" ) > "$T/server.log" 2>&1 &
  pid=$!
  for _ in $(seq 300); do curl -sf "http://127.0.0.1:$port/health" >/dev/null && break; kill -0 $pid 2>/dev/null || break; sleep 0.2; done
  if curl -sf "http://127.0.0.1:$port/health" >/dev/null; then
    timeout "${KG_TRAIN_TIMEOUT:-900}" java -XX:+UseSerialGC -Xmx256m -cp "$B/app.jar:$B/kotlin-stdlib.jar" app.Train \
      127.0.0.1 "$port" "$secret" "${KG_TRAIN_USERS:-20000}" "${KG_TRAIN_REQS:-200000}" "${KG_TRAIN_CONNS:-64}" || rc=1
  else
    echo "training server did not come up:"; cat "$T/server.log"; rc=1
  fi
  kill -TERM $pid 2>/dev/null || true
  for _ in $(seq 300); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
  kill -KILL $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
  [ "$rc" = 0 ] || return 1
  if [ "$PGO" = 1 ]; then [ -s "$P/server.iprof" ] || { echo "no native-image profile written"; return 1; }; fi
  if [ "$CPGO" = 1 ]; then
    if [ "$IS_CLANG" = 1 ]; then "$PROFDATA" merge -o "$P/c.profdata" "$P"/c/*.profraw || return 1
    else find "$P/c" -name '*.gcda' | grep -q . || { echo "no gcc profile written"; return 1; }; fi   # (gcc mangles the object path into the name)
  fi
  rm -rf "$T"
}
if [ "$PGO" = 1 ] || [ "$CPGO" = 1 ]; then
  if train; then
    echo "== training done; optimized builds with the recorded profile(s)"
    [ "$CPGO" = 1 ] && build_c use
    [ "$PGO" = 1 ] && native_image "$B/server" "--pgo=$P/server.iprof"
  else
    echo "!! PGO training failed: falling back to the plain build" >&2
    [ "$CPGO" = 1 ] && build_c plain
    [ "$PGO" = 1 ] && native_image "$B/server" "$NI_O"
  fi
fi
[ -x "$B/server" ] && ls -la "$B/server"
ls -la "$B/libkn.so" "$B/app.jar"
