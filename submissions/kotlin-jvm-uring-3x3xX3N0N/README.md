# Kotlin on HotSpot, no framework: io_uring + SQLite B-tree reads through FFM

The Kotlin handlers of [kotlin-native-3x3xX3N0N](../kotlin-native-3x3xX3N0N) (HTTP parsing, routing, JWT, group
commit), compiled for the JVM and run on plain HotSpot (OpenJDK 25, C2, Serial GC). The C side (`csrc/`, the same
`uring.c` / `db.c` / `btree_reads.c` as the Kotlin/Native entry) is reached through `java.lang.foreign` (FFM) in
one shared library, `build/libkj.so`. No GraalVM.

| | |
|---|---|
| Language | Kotlin 2.4.21 (kotlinc, JVM target 21), on Temurin JDK 25.0.4.1 (HotSpot) |
| Framework | none (`src/Server.kt`) |
| Native calls | `java.lang.foreign` downcalls into `build/libkj.so` (`src/Native.kt`, `csrc/jvm.c`) |
| io_uring | liburing 2.9 (MIT), fetched by `build.sh` at its release tag, sha256-checked, called from `csrc/uring.c` |
| SQLite | 3.54.1 amalgamation, unchanged, SHA3-256-checked against sqlite.org, compiled into `libkj.so` (`csrc/db.c`) |
| C compiler | gcc (Ubuntu 24.04 `build-essential`) |
| Nginx or direct | **Direct**: serves `HOST:PORT` itself (`0.0.0.0:80` on the benchmark box) |
| Needs | Linux 6.0+ io_uring (multishot receive, provided-buffer rings, direct descriptors). No epoll fallback |

## Design

Everything about the transport, the B-tree reads and the durability is the Kotlin/Native entry's; see
[its README](../kotlin-native-3x3xX3N0N/README.md#design) for one thread over io_uring with direct descriptors in up
to 8 rings, multishot receive into provided buffers, the B-tree read paths with their start-up schema check and SQL
fallback, the read snapshot kept across passes, the committer thread and the checkpointer. What is different here:

**The JVM boundary** (`src/Native.kt`, `csrc/jvm.c`):
- Each C function has one downcall handle in a top-level `private val` (a `static final` field, so C2 treats the
  handle as a constant and inlines the downcall at its call site), called with `invokeExact` and its exact signature.
- Calls that never wait are `Linker.Option.critical(true)`: no Java-to-native thread-state transition, and Java
  arrays are passed as heap segments that C reads and writes in place. One cached `MemorySegment` per array, and
  offsets are explicit `int` parameters, so a call creates no slice.
- The one call that sleeps (`kj_enter`: submit + `io_uring_enter` wait) is an ordinary downcall, so a safepoint
  never waits on it; the reap that follows is critical. `ur_poll` of the Kotlin/Native entry is split in two for this.
- `kj_reap` turns all ready completions of a pass into 5 ints each in a Java `int[]` and copies every received byte
  into one Java `byte[]` (8 MiB) in the same call, then gives the provided buffers back at once.
- SQLite writes a `GET /feed` or `GET /posts/:id` JSON body straight into the Java output array (`kj_feed`,
  `kj_post`), and `kj_send` hands a slice of that array to the send path, which copies it once into the send request.

**Group-commit window 10 ms** (the Kotlin/Native entry: 2 ms): writes are committed once the oldest has waited 10 ms
or 1,024 are queued. Measured below: every COMMIT by the committer's connection makes the reader connection drop its
whole page cache at its next read transaction (SQLite's WAL `changed` check), so fewer commits mean fewer re-reads.

**Runtime**: Serial GC, fixed 96 MB heap, compact object headers, no perf data. The loop allocates only on the write
path (the queued write, its body bytes, the JWT's JSON maps): one young collection every ~14 s at 24k req/s, pauses
0.1 ms after warm-up.

## Measured (LOCAL, relative only)

(see the report; filled in below)

## Knobs (all optional; the defaults are what is scored)

`KJ_WINDOW_US` / `KJ_BATCH_MAX` (group commit), `KJ_CACHE_KB` (reader page cache, KiB), `KJ_MMAP` (reader
`mmap_size`), `KJ_VFS` (SQLite VFS), `KJ_BTREE=0` (SQL only), `KJ_SNAPSHOT=0` (new read transaction every pass),
`KJ_PACE_NR` / `KJ_PACE_US` (after a light pass, wait for this many completions or this long), `KJ_DEFER=1`
(`IORING_SETUP_DEFER_TASKRUN`), `KJ_RINGS`, `KJ_TABLE` (direct-descriptor table size, for tests), `KJ_STATS=1`,
`KJ_CKPT_LOG=1`, `KJ_VERIFY=1` (B-tree vs SQL byte-for-byte check, then exit), `KJ_JVM_FLAGS` (extra JVM flags).

## Credits (ideas only; no files or code copied; all MIT)

Everything credited in [the Kotlin/Native entry](../kotlin-native-3x3xX3N0N/README.md#credits-ideas-only-no-files-or-code-copied-all-mit),
plus:
- java-iouring-davidhsv (#393): FFM on HotSpot with handles built once in static finals and `critical` for calls
  that never wait, ordinary downcalls for the ones that block.
- kotlin-trikeshed-jnorthrup (#298): static-final FFM handles with `critical(true)` and heap segments; all
  completions and received bytes of a pass moved into Java arrays in one native call.

## Licences of what the build fetches

SQLite: public domain. liburing: MIT (dual MIT / LGPL-2.1; used under MIT). Kotlin compiler and stdlib: Apache-2.0.
Temurin JDK: GPLv2 with the Classpath Exception.
