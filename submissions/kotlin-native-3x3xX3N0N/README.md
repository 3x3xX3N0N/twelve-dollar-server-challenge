# Kotlin/Native, no framework: io_uring + SQLite B-tree reads

The Kotlin handlers of [kotlin-nio-3x3xX3N0N](../kotlin-nio-3x3xX3N0N) (HTTP parsing, routing, JWT, JSON, group
commit), compiled with Kotlin/Native for linuxX64 instead of the JVM, on one thread over io_uring, with SQLite
compiled in. The C side is kernel and SQLite plumbing only.

| | |
|---|---|
| Language | Kotlin 2.4.21, Kotlin/Native (`linuxX64`, `-opt`); the compiler runs on Temurin JDK 25.0.4.1 at build time only |
| Framework | none (`src/Server.kt`) |
| io_uring | liburing 2.9 (MIT), fetched by `build.sh` at its release tag, sha256-checked, called from `csrc/uring.c` |
| SQLite | 3.54.1 amalgamation, unchanged, SHA3-256-checked against sqlite.org, compiled into `csrc/db.c` |
| C compiler | the clang + glibc sysroot that ship with Kotlin/Native (so the C objects match its linker) |
| Nginx or direct | **Direct**: serves `HOST:PORT` itself (`0.0.0.0:80` on the benchmark box) |
| Needs | Linux 6.0+ io_uring (multishot receive, provided-buffer rings, direct descriptors). No epoll fallback |

## Design

**One thread, io_uring, no fds for clients.** `csrc/uring.c`:
- Accepted sockets go straight into a ring's *direct-descriptor* table (`accept_direct`, `IORING_FILE_INDEX_ALLOC`),
  so a connection never takes a normal fd. A table holds at most `RLIMIT_NOFILE` (65,535) entries, so when one ring
  is `FD_MARGIN` short of full, accepts move to the next ring (up to 8 rings, ~520k connections, one process).
  Secondary rings signal one eventfd that ring 0 reads, so the thread sleeps in a single `io_uring_enter`.
- 512 single-shot accepts in flight (multishot accept into a direct table lost connections for another entry).
- Multishot receive into a provided-buffer ring (4,096 × 2 KB per ring): an idle connection owns no buffer. Buffers go
  back after each pass. A receive that runs out of buffers (`ENOBUFS`) is re-armed later, at most 256 per pass.
- Each response is copied once into a send request; a short write resubmits the rest; output behind an in-flight send
  is queued so the order on the wire is kept. A `Connection: close` ends with `shutdown`, and the slot is closed when
  the receive sees the end.
- The soft `RLIMIT_NOFILE` is raised to the hard one at start. `TCP_NODELAY` and `TCP_DEFER_ACCEPT` on the listener.
- Ubuntu's 6.8.0-136+ kernels refuse a buffer-ring registration whose reserved words are zero (an inverted check,
  Launchpad #2162843): the registration is retried once with `resv[0]=1`.

**Kotlin does the rest** (`src/`): the event loop, the request parser, routing and every handler are the JVM entry's
code, ported (byte arrays instead of `ByteBuffer`, io_uring events instead of selector keys). Connections are slots
in flat arrays (no object per connection). JWTs: HS256 with the key's inner/outer pad states hashed once at start
(own SHA-256 in Kotlin); `exp` is required; every token is verified.

**Reads through SQLite's B-tree** (`csrc/btree_reads.c`, allowed by the 2026-10-31 ruling):
- `GET /posts/:id`: the `posts` row by rowid, its `users` row by rowid, and the like count by walking
  `likes_post_id_idx` from the first entry equal to the id. `GET /feed`: the first 20 entries of
  `posts_created_at_id_idx` (`created_at DESC, id DESC`, so the newest come first), then the same for each post.
- The JSON is written exactly as `json_object()` writes it (SQLite's own `jsonIsOk[]` escaping table, same control
  character forms). `KN_VERIFY=1` compares the B-tree path with the SQL path, byte for byte, for every post id and
  the feed, and exits (0 mismatches on the seed: 500,010 ids; also after the test suite's bodies with quotes,
  backslashes, control characters and non-ASCII).
- Anything unexpected (a column type, a spilled record larger than the scratch buffer, a post whose user row is
  missing) returns to the original SQL query for that request. At start the server checks the column order, sort
  order and collation of every table and index it decodes, and serves everything through SQL if they differ.
- Only cursors, `KeyInfo`s, prepared statements and four root page numbers are kept. No rows, no responses.

**One read snapshot across loop passes** (idea: rust-iouring-rkkautsar). The reader connection keeps its read
transaction open between passes and drops it right after our own writer commits (so a request that arrives after a
201 always sees that write) or when the checkpointer waits for readers. Fewer WAL read-lock round trips.

**Writes and durability.** WAL, `synchronous=NORMAL`. Writes are queued and group-committed once the oldest has
waited 2 ms or 64 are queued. The commit runs on a **committer thread** with its own connection: `BEGIN IMMEDIATE`,
the INSERTs, `COMMIT`; when it returns, the thread writes to an eventfd that ring 0 watches, and only then does the
loop read the results and hand the 201s to the kernel. Meanwhile the loop keeps serving reads, and new writes queue
for the next batch. (Measured reason: with the commit on the loop, a 5-minute hold at 352k users failed on p99
because a few group commits took ~2 s in `pwrite` on a busy disk, and every read waited behind them.) A failed
COMMIT answers every write of the batch with a 500.

**Checkpoints off the loop.** A thread at nice 5 runs a PASSIVE checkpoint every 50 ms on its own connection; once
the WAL has 4,096 frames and all but 128 are copied, a RESTART with a 250 ms busy timeout briefly holds the writer
(the committer thread's `BEGIN` waits it out, off the loop) and the WAL starts over from frame 1.
Idea credit: swift-iouring-akbashev, rust-iouring-kensac.

**SQLite build options**: `SQLITE_THREADSAFE=2`, `SQLITE_ENABLE_QPSG` (plans fixed at prepare time),
`SQLITE_DEFAULT_MEMSTATUS=0`, `SQLITE_OMIT_LOAD_EXTENSION`, `SQLITE_OMIT_DEPRECATED`, `SQLITE_OMIT_SHARED_CACHE`,
`SQLITE_DQS=0`, `SQLITE_USE_ALLOCA`. Pragmas: `mmap_size=0`, `cache_size=-65536` (64 MiB), `wal_autocheckpoint=0`.

## Measured (LOCAL, relative only)

i7-10700K desktop, the server pinned to one core in a 2 GB / no-swap cgroup with `ulimit -n 65535`, kload (a
k6-compatible replay of `bench/load.js`) on other cores; above ~260k users both run in a private network namespace
(the host's conntrack table holds 262,144 entries). A desktop core is faster than the droplet's vCPU, and loopback
is not a NIC, so these numbers rank designs, they are not a score.

| Users | Run | Result | CPU µs/req | CPU | p95 / p99 | cgroup peak |
|---|---|---|---|---|---|---|
| 160,000 | 60 s | PASS | 19.4 (the JVM entry: 41-45) | 33 % | 1.4 / 2.3 ms | — |
| 256,000 | 60 s | PASS | 15.3 | 41 % | 1.2 / 2.4 ms | 1,102 MB |
| 384,000 | 5-min hold | PASS, 0 errors | 14.1 | 57 % | 1.7 / 26.5 ms | 1,657 MB |
| 416,000 | 5-min hold | PASS, 0 errors | 13.3 | 59 % | 2.4 / 733 ms | 1,794 MB |
| 448,000 | 60 s | PASS | 13.3 | 63 % | 2.4 / 416 ms | 1,842 MB |

- Steps (160k users): SQL only 30-44 µs/req → B-tree reads 22-30 (−28-31 %); `unix-excl`, pacing and
  `DEFER_TASKRUN` measured no better (kept as knobs, off); one read snapshot across passes ~−4 %.
- The limit is memory, not CPU: ~4.1 KB of kernel socket memory per connection. Process RSS is 19 MB idle and
  ~100-180 MB under load.
- The p99 at 416k/448k comes from writes (`POST` p95 ~1.6 s): this desktop's disk was shared with other jobs (IO
  pressure 25 %); reads stayed at p99 12 ms because the commit runs off the loop.
- At a 50 % CPU quota: 256k users pass (p99 2.6 ms), 320k is at the edge (p99 457 ms).

## Knobs (all optional; the defaults are what is scored)

`KN_VFS` (SQLite VFS, default `unix`), `KN_BTREE=0` (SQL only), `KN_SNAPSHOT=0` (new read transaction every pass),
`KN_WINDOW_US` / `KN_BATCH_MAX` (group commit), `KN_PACE_NR` / `KN_PACE_US` (after a light pass, wait for this
many completions or this long), `KN_RINGS`, `KN_STATS=1` / `KN_CKPT_LOG=1` (counters on stdout/stderr every 10 s),
`KN_VERIFY=1` (the byte-for-byte check above).

Extra checks besides `test/run.sh`: `test-restart.sh` (a restart right after a stop with open connections comes up
healthy; on Ubuntu's 6.8 kernel the old process's io_uring keeps its listener alive briefly after exit, so `bind()`
is retried for up to 30 s) and `test-rings.sh` (with tiny tables, 2,500 connections spill over 8 rings and all are
answered).

## Credits (ideas only; no files or code copied; all MIT)

- rust-iouring-kensac: rings spilling past the fd cap, 512 accepts in flight, soft `RLIMIT_NOFILE` raised to hard,
  bounded re-arm after `ENOBUFS`, the buffer-ring registration quirk, B-tree cursor reads with schema checks at start.
- c-iouring-pavlyhalim: provided-buffer receive, B-tree read helpers as a pattern.
- kotlin-trikeshed-jnorthrup: Kotlin/Native + SQLite amalgamation built on the box.
- rust-iouring-rkkautsar: one read snapshot across passes.
- swift-iouring-akbashev: checkpointer at nice 5 with a bounded hold.
- zig-iouring-unorig-username (via the JVM entry): the two-step feed idea that led to the B-tree feed.

## Licences of what the build fetches

SQLite: public domain. liburing: MIT (dual MIT / LGPL-2.1; used under MIT). Kotlin/Native compiler and runtime:
Apache-2.0 (its clang/LLVM bundle: Apache-2.0 with LLVM exceptions; glibc sysroot: LGPL). Temurin JDK: GPLv2 with the
Classpath Exception (build time only).
