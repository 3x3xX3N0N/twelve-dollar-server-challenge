#!/usr/bin/env bash
# Builds, as a normal user:
#   build/native/libsqlite3.so  SQLite 3.54.0 from the official amalgamation (pinned by sha256), compiled for this
#                               workload: no mutexes on our connections, no memory statistics, unused features off
#   build/lib/*.jar             the Kotlin app (no dependencies besides the Kotlin stdlib)
set -euo pipefail
cd "$(dirname "$0")"

SQLITE_URL=https://www.sqlite.org/2026/sqlite-amalgamation-3540000.zip
SQLITE_SHA=68e913b0fe8ec6b4e5f391c594a28872884e80d6cd042a1e50c957be46b5aa4d   # sqlite.org's SHA3-256 checked too
mkdir -p build/native
if [ ! -f build/native/sqlite3.c ]; then
  curl -fsSL "$SQLITE_URL" -o build/native/sqlite.zip
  echo "$SQLITE_SHA  build/native/sqlite.zip" | sha256sum -c - >/dev/null
  unzip -oqj build/native/sqlite.zip '*/sqlite3.c' '*/sqlite3.h' -d build/native
fi
if [ ! -f build/native/libsqlite3.so ] || [ build.sh -nt build/native/libsqlite3.so ]; then
  # THREADSAFE=2: connections are never shared between threads (event loop / checkpointer each own theirs).
  cc -O2 -march=native -fPIC -shared -o build/native/libsqlite3.so build/native/sqlite3.c -lm \
    -DSQLITE_THREADSAFE=2 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DQS=0 -DSQLITE_LIKE_DOESNT_MATCH_BLOBS \
    -DSQLITE_MAX_EXPR_DEPTH=0 -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_PROGRESS_CALLBACK -DSQLITE_OMIT_SHARED_CACHE \
    -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_AUTHORIZATION -DSQLITE_OMIT_TRACE -DSQLITE_USE_ALLOCA \
    -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1
fi

if [ -x /opt/jdk-25/bin/java ]; then export JAVA_HOME=/opt/jdk-25; fi
GRADLE=/opt/gradle-9.8.1/bin/gradle
[ -x "$GRADLE" ] || GRADLE="$(command -v gradle)"
"$GRADLE" --no-daemon --console=plain -q build
ls build/lib build/native/libsqlite3.so
