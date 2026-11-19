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

**Group commit on the loop, on the reader's own connection** (the Kotlin/Native entry: a committer thread with its
own connection; still there as `KJ_COMMITTER=1`). Writes are queued and committed once the oldest has waited 10 ms or
1,024 are queued (the Kotlin/Native entry: 2 ms / 64): the read snapshot is ended, `BEGIN IMMEDIATE` is tried
without waiting (if a checkpoint holds the write lock, the batch stays staged and a later pass tries again while
reads go on), the INSERTs run, `COMMIT`, and only then are the 201s handed to the kernel. Reason (measured below): a
COMMIT by another connection makes SQLite's WAL reader drop its whole page cache at its next read transaction, so with
a committer thread most post reads were a `pread`. With one connection the cache survives, and it is 256 MiB (the
seed database is 248 MB).

**Checkpoints off the loop**, as in the Kotlin/Native entry (PASSIVE every 50 ms at nice 5; a bounded RESTART once
the WAL is long and nearly copied).

**C built for the box**: `-O3 -march=native -mprefer-vector-width=256` (`build.sh` runs on the box).

**Runtime**: Serial GC, fixed 96 MB heap, compact object headers, no perf data. The loop allocates only on the write
path (the queued write, its body bytes, the JWT's JSON maps): one young collection every ~14 s at 24k req/s, pauses
0.1 ms after warm-up.

## Measured (LOCAL, relative only)

i7-10700K desktop shared with other jobs (load 2-9). The server is pinned to one core (`taskset`, its HT sibling
idle) in a 2 GB / no-swap cgroup with `ulimit -n 65535`, in a private network namespace (no conntrack). Load is kload,
a k6-compatible replay of `bench/load.js`, in its own cgroup on other cores: 25 s warm-up at 1,000 users, 30 s
ramp, 60 s hold. µs/req = server CPU (user + system, all threads) over the hold / requests in the hold. A desktop
core is faster than the droplet's vCPU and loopback is not a NIC: these numbers rank designs, they are not a score.
Run-to-run noise on this desktop was ±10-15 %, so A/Bs were interleaved and repeated.

| Users | Run | Result | CPU µs/req | CPU | p95 / p99 (hold) | RSS / cgroup peak |
|---|---|---|---|---|---|---|
| 160,000 | 60 s, ×2 | PASS | 15.6, 15.2 | 26 % | 4.9 / 10.3 ms (reads p99 1.1-1.5 ms) | 157 / 766 MB |
| 256,000 | 60 s | PASS | 14.2 | 38 % | 5.2 / 10.4 ms | 167 / 1,142 MB |
| 384,000 | 60 s | PASS | 13.2 | 54 % | 5.9 / 10.9 ms | 185 / 1,652 MB |
| 384,000 | 60 s, no warm-up | PASS | 14.1 | 57 % | 6.6 / 11.5 ms | 185 / 1,652 MB |
| 416,000 | 60 s | PASS | 15.0 | 66 % | 7.4 / 12.5 ms | 191 / 1,782 MB |
| 448,000 | 60 s | FAIL (OOM kill at 2 GB) | | | | — / 2.1 GB |

The same rig, database on tmpfs, 160k users, two interleaved rounds (µs/req): **this entry 15.7, 17.4**; this
entry with the Kotlin/Native entry's settings (committer thread, 64 MiB cache, 2 ms window) 20.2, 19.7; the
Kotlin/Native entry 19.8, 18.2; java-iouring-davidhsv (#393) 14.1, 13.0.

What each change did (160k users, µs/req, interleaved pairs):

| change | before → after | kept |
|---|---|---|
| the Kotlin/Native entry ported as is (FFM, `critical`, heap segments) | K/N 17.4 → JVM 19.1 (1st pair); 19.0 → 20.0 (avg of 2, tmpfs) | baseline |
| group-commit window 2 ms → 10 ms (batch max 64 → 1,024) | 17.6 → 16.1 (avg of 2); 30 ms: 15.8, p99 28 ms | yes (10 ms) |
| C at `-O3 -march=native` instead of `-O2` | 17.4 → 17.0 (avg of 2, both rounds lower) | yes |
| commit on the reader connection, on the loop (no committer thread) | 18.0 → 16.8 tmpfs, 18.6 → 17.8 disk (avg of 2) | yes |
| ... plus a 256 MiB reader page cache (64 MiB before) | 16.8 → 15.4 (avg of 2, tmpfs) | yes |
| 256 MiB reader cache while a committer thread commits | 20.5 → 19.4 (noisy; the cache is dropped at every foreign commit) | (superseded) |
| reader `mmap_size` 256 MiB | 20.6 → 20.7 | no |
| `IORING_SETUP_DEFER_TASKRUN` | 17.4 → 17.4 | no (knob) |
| after a light pass, wait for 32 completions or 1 ms | 17.4 → 17.1 | no (knob) |
| `DEFER_TASKRUN` + wait for 256 completions or 1 ms (the leaders' pair) | 14.85 → 14.35 | no (within noise; knob) |

- Why the cache change matters: every COMMIT by *another* connection makes SQLite's WAL reader drop its whole page
  cache at its next read transaction. With the committer thread that happened every 2 ms, so post reads were a
  `pread` each (9.5 % of all CPU samples in `unixRead`, async-profiler). Committing on the reader connection removed
  them (0 %) and made a larger cache worth having. The cost: the COMMIT now runs on the loop. Its `BEGIN IMMEDIATE`
  never waits (a checkpoint hold makes the batch wait for a later pass while reads go on), but a slow `write()` of
  the WAL does stall reads: one 2.0 s pass at 448k users, just before the OOM kill. `KJ_COMMITTER=1` brings back the
  committer thread.
- Start-up: healthy 0.35 s after launch, 0.35 s of CPU. With no warm-up, 384k users pass with p99 11.5 ms, so there
  is no AppCDS archive and no warm-up before bind.
- GC: one young collection every ~14 s at 24k req/s (≈ 77 bytes per request, all of it on the write path), 0.1 ms
  pauses after warm-up. Nothing to gain from removing the remaining allocations.
- Build: 32 s, peak RSS 626 MB (kotlinc, capped at `-Xmx600m`).
- `test/run.sh`: 42/42 with both commit modes. `KJ_VERIFY=1`: 500,010 post ids + the feed, 0 mismatches between the
  B-tree and SQL paths with the `-O3 -march=native` build.

## Knobs (all optional; the defaults are what is scored)

`KJ_COMMITTER=1` (committer thread + own connection), `KJ_WINDOW_US` / `KJ_BATCH_MAX` (group commit), `KJ_STALLS=1`
(log loop passes over 50 ms), `KJ_CACHE_KB` (reader page cache, KiB), `KJ_MMAP` (reader
`mmap_size`), `KJ_VFS` (SQLite VFS), `KJ_BTREE=0` (SQL only), `KJ_SNAPSHOT=0` (new read transaction every pass),
`KJ_PACE_NR` / `KJ_PACE_US` (after a light pass, wait for this many completions or this long), `KJ_DEFER=1`
(`IORING_SETUP_DEFER_TASKRUN`), `KJ_RINGS`, `KJ_TABLE` (direct-descriptor table size, for tests), `KJ_STATS=1`,
`KJ_CKPT_LOG=1`, `KJ_VERIFY=1` (B-tree vs SQL byte-for-byte check, then exit), `KJ_JVM_FLAGS` (extra JVM flags).

## Credits (ideas only; no files or code copied; all MIT)

Everything credited in [the Kotlin/Native entry](../kotlin-native-3x3xX3N0N/README.md#credits-ideas-only-no-files-or-code-copied-all-mit),
plus:
- java-iouring-davidhsv (#393): FFM on HotSpot with handles built once in static finals and `critical` for calls
  that never wait, ordinary downcalls for the ones that block; reads and the group commit on one connection on the
  loop (from rust-iouring-kensac #264), with writes held, not the loop, while a checkpoint copies the WAL's tail.
- kotlin-trikeshed-jnorthrup (#298): static-final FFM handles with `critical(true)` and heap segments; all
  completions and received bytes of a pass moved into Java arrays in one native call.

## Licences of what the build fetches

SQLite: public domain. liburing: MIT (dual MIT / LGPL-2.1; used under MIT). Kotlin compiler and stdlib: Apache-2.0.
Temurin JDK: GPLv2 with the Classpath Exception.
