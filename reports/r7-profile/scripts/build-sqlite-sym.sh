#!/usr/bin/env bash
# Builds an UNSTRIPPED libsqlitejdbc.so (sqlite-jdbc 3.53.4.0 + amalgamation 3530400) with the same SQLITE_* flags
# and -Os as the shipped one, plus -fno-omit-frame-pointer, so async-profiler can name SQLite's internal functions.
#   build-sqlite-sym.sh <sqlite-jdbc checkout> <amalgamation dir> <out dir>
set -euo pipefail
SJ="$(cd "$1" && pwd)"; AM="$(cd "$2" && pwd)"; OUT="$3"; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
JH="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
# JNI header
javac -d "$OUT/cls" -h "$OUT" -cp "$(ls "$PWD"/submissions/kotlin-nio-3x3xX3N0N/build/lib/*.jar | tr '\n' :)" \
  "$SJ/src/main/java/org/sqlite/core/NativeDB.java" 2>&1 | grep -v warning || true
mv "$OUT/org_sqlite_core_NativeDB.h" "$OUT/NativeDB.h"
perl -p -e "s/sqlite3_api;/sqlite3_api = 0;/g" "$AM/sqlite3ext.h" > "$OUT/sqlite3ext.h"
perl -p -e 's/^opendb_out:/  if(!db->mallocFailed && rc==SQLITE_OK){ rc = RegisterExtensionFunctions(db); }\nopendb_out:/;' "$AM/sqlite3.c" > "$OUT/sqlite3.c"
cat "$SJ"/src/main/ext/*.c >> "$OUT/sqlite3.c"
cp "$AM/sqlite3.h" "$OUT/"
CF="-I$OUT -I$JH/include -I$JH/include/linux -Os -fPIC -m64 -fvisibility=hidden -g -fno-omit-frame-pointer -Wno-implicit-function-declaration"
SF="-DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_HAVE_ISNAN -DHAVE_USLEEP=1 -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_CORE
 -DSQLITE_ENABLE_FTS3 -DSQLITE_ENABLE_FTS3_PARENTHESIS -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_PERCENTILE
 -DSQLITE_ENABLE_STAT4 -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_MEMSTATUS=0
 -DSQLITE_DEFAULT_FILE_PERMISSIONS=0666 -DSQLITE_MAX_VARIABLE_NUMBER=250000 -DSQLITE_MAX_MMAP_SIZE=1099511627776
 -DSQLITE_MAX_LENGTH=2147483647 -DSQLITE_MAX_COLUMN=32767 -DSQLITE_MAX_SQL_LENGTH=1073741824 -DSQLITE_MAX_FUNCTION_ARG=127
 -DSQLITE_MAX_ATTACHED=125 -DSQLITE_MAX_PAGE_COUNT=4294967294 -DSQLITE_DISABLE_PAGECACHE_OVERFLOW_STATS -DSQLITE_ENABLE_UPDATE_DELETE_LIMIT"
gcc -o "$OUT/sqlite3.o" -c $CF $SF "$OUT/sqlite3.c"
gcc $CF -c -o "$OUT/NativeDB.o" "$SJ/src/main/java/org/sqlite/core/NativeDB.c"
gcc $CF -o "$OUT/libsqlitejdbc.so" "$OUT/NativeDB.o" "$OUT/sqlite3.o" -shared -static-libgcc -pthread -lm
gcc --version | head -1; file "$OUT/libsqlitejdbc.so"
