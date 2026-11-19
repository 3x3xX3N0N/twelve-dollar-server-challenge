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
- **Batch wake**: after a light pass the loop waits on ring 0 alone for 256 completions or 1 ms (or the group-commit
  deadline), then collects every ring. At 160k users: 8.2k → 1.9k loop passes a second, −6-11 % CPU per request,
  reads p95 0.3 → 2.2 ms. (`DEFER_TASKRUN` is a knob, off: together with this wait it failed reads at 256k users.)
- 512 single-shot accepts in flight (multishot accept into a direct table lost connections for another entry).
- Multishot receive into a provided-buffer ring (1,024 × 2 KB per ring): an idle connection owns no buffer. Buffers go
  back after each pass. A receive that runs out of buffers (`ENOBUFS`) is re-armed later, at most 256 per pass.
- Each response is copied once into a send request; a short write resubmits the rest; output behind an in-flight send
  is queued so the order on the wire is kept. A `Connection: close` ends with `shutdown`, and the slot is closed when
  the receive sees the end.
- The soft `RLIMIT_NOFILE` is raised to the hard one at start. `TCP_NODELAY` and `TCP_DEFER_ACCEPT` on the listener.
  One listener by default; `KN_LISTENERS=8` opens 8 `SO_REUSEPORT` listeners (measured: same CPU, connect p99
  0.7-0.8 → 0.5 ms at 256k; not the default because a restart on Ubuntu's 6.8 kernel could share the port with the
  old process's listener while that one is torn down).
- The binary's own code and read-only data (~2.2 MB) are `mlock`ed at start, so near the memory wall reclaim cannot
  page the loop's code out (no swap on the box: only file pages can be reclaimed).
- Ubuntu's 6.8.0-136+ kernels refuse a buffer-ring registration whose reserved words are zero (an inverted check,
  Launchpad #2162843): the registration is retried once with `resv[0]=1`.

**Kotlin does the rest** (`src/`): the event loop, the request parser, routing and every handler are the JVM entry's
code, ported (byte arrays instead of `ByteBuffer`, io_uring events instead of selector keys). Connections are slots
in flat arrays (no object per connection). The request head is parsed in one pass: each line is scanned once for its
CR and decoded only if its first character and the colon at the fixed offset of its name say it is Content-Length,
Authorization, Connection or Transfer-Encoding (any case, as before); parse time halved (1.5 → 0.7 % of CPU). JWTs: HS256 with the key's inner/outer pad states hashed once at start
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
waited 20 ms or 1,024 are queued (was 2 ms / 64: the committer thread's CPU per request about halved, p95 2 → 8 ms;
reads never wait for it). The commit runs on a **committer thread** with its own connection: `BEGIN IMMEDIATE`,
the INSERTs, `COMMIT`; when it returns, the thread writes to an eventfd that ring 0 watches, and only then does the
loop read the results and hand the 201s to the kernel. Meanwhile the loop keeps serving reads, and new writes queue
for the next batch. (Measured reason: with the commit on the loop, a 5-minute hold at 352k users failed on p99
because a few group commits took ~2 s in `pwrite` on a busy disk, and every read waited behind them.) A failed
COMMIT answers every write of the batch with a 500.

**One `pwrite` per commit.** A VFS of our own over the base VFS (public `sqlite3_vfs` API) changes only the WAL
file's writes: SQLite writes each frame as two writes (24-byte header, page); writes that continue where the last one
ended are gathered and go to the file when the commit frame's page arrives (its header's database-size field is
non-zero), inside SQLite's own call, so the commit is in the kernel before SQLite publishes it in the WAL index and
before `COMMIT` returns. Any other write, and every read, sync, truncate, lock, file control and close, writes the
buffer first. Write syscalls 0.50 → 0.145 per request.

**Page cache.** SQLite's own pcache1 through `SQLITE_CONFIG_PCACHE2` with one method of ours, `xRekey`: a B-tree
split swaps two pages through the lock-byte page's number (262,145), after which pcache1's next truncate walked its
whole hash table; here the page waits out the swap under key 0, which SQLite never gives a page.
`pcache1TruncateUnsafe` 0.55 → 0.25 % of CPU. `PRAGMA integrity_check` is ok after every measured run.

**Checkpoints off the loop.** A thread at nice 5 runs a PASSIVE checkpoint every 50 ms on its own connection; once
the WAL has 4,096 frames and all but 128 are copied, a RESTART with a 250 ms busy timeout briefly holds the writer
(the committer thread's `BEGIN` waits it out, off the loop) and the WAL starts over from frame 1.
Idea credit: swift-iouring-akbashev, rust-iouring-kensac.

**SQLite build options**: `SQLITE_THREADSAFE=2`, `SQLITE_ENABLE_QPSG` (plans fixed at prepare time),
`SQLITE_DEFAULT_MEMSTATUS=0`, `SQLITE_OMIT_LOAD_EXTENSION`, `SQLITE_OMIT_DEPRECATED`, `SQLITE_OMIT_SHARED_CACHE`,
`SQLITE_DQS=0`, `SQLITE_USE_ALLOCA`. Pragmas: `mmap_size=0`, `cache_size=-65536` (64 MiB), `wal_autocheckpoint=0`.

## Measured (LOCAL, relative only)

i7-10700K desktop shared with other jobs, the server pinned to one core in a 2 GB / no-swap cgroup with
`ulimit -n 65535`, inside a private network namespace (no host conntrack); kload (a k6-compatible replay of
`bench/load.js`) in its own cgroup on other cores. A desktop core is faster than the droplet's vCPU, and loopback is
not a NIC, so these numbers rank designs, they are not a score. Run-to-run noise on this machine is about ±10 %.

| Users | Run | Result | CPU µs/req | CPU | p95 / p99 | cgroup peak |
|---|---|---|---|---|---|---|
| 160,000 | 60 s | PASS | 14.7-16.8 (before this round: 18.1-19.2; the JVM entry: 41-45) | 25-28 % | 8.8 / 20.1 ms | 693 MB |
| 256,000 | 60 s | PASS | 14.4 (before: 17.8) | 39 % | 8.8 / 20.1 ms | 1,067 MB |
| 384,000 | 60 s | PASS | 13.8 | 56 % | 9.8 / 20.9 ms | 1,568 MB |
| 416,000 | 5-min hold | PASS, 0 errors | 14.3 | 63 % | 13.2 / 23.4 ms (before: 2.4 / 733 ms) | 1,771 MB |
| 448,000 | 60 s | PASS | 14.0 | 66 % | 12.1 / 22.4 ms | 1,824 MB |
| 448,000 | 5-min hold | FAIL (p99 1.27 s) | 14.9 | 70 % | 104 / 1,270 ms | 2,084 MB (the wall) |
| 480,000 | 60 s | PASS | 15.1 | 77 % | 26 / 142 ms | 1,984 MB |

- Where it goes (perf, 160k): ~63 % kernel (TCP, io_uring), ~30 % SQLite's B-tree and pager, ~5 % Kotlin.
- Earlier steps (160k users): SQL only 30-44 µs/req → B-tree reads 22-30; one read snapshot across passes ~−4 %.
- The limit is memory, not CPU: ~4.1 KB of kernel socket memory per connection; a 5-minute hold at 448k reaches the
  2 GB wall. Process RSS is 20 MB idle and ~60-100 MB under load.
- Writes now stay at p99 ~40 ms at 416k (before, they were the p99 at 416k/448k: `POST` p95 ~1.6 s on a shared disk).
- Build: a cold build (Kotlin/Native toolchain download included) peaks at ~560 MB anonymous memory inside a 1.5 GB
  no-swap cgroup.

## Knobs (all optional; the defaults are what is scored)

`KN_VFS` (base SQLite VFS, default `unix`), `KN_WALVFS=0` (stock WAL writes), `KN_PCACHE=0` (stock pcache1),
`KN_BTREE=0` (SQL only), `KN_SNAPSHOT=0` (new read transaction every pass), `KN_WINDOW_US` / `KN_BATCH_MAX` (group
commit, default 20000 / 1024), `KN_PACE_NR` / `KN_PACE_US` (batch wake, default 256 / 1000; `KN_PACE_NR=1` = off),
`KN_DEFER=1` (`DEFER_TASKRUN` rings), `KN_MAX_EV` (events per pass, default 4096), `KN_LISTENERS` (1-8),
`KN_HDR=0` (the old two-pass head parser), `KN_MLOCK=0`, `KN_RINGS`, `KN_STATS=1` / `KN_PROF=1` / `KN_CKPT_LOG=1`
(counters on stdout/stderr every 10 s), `KN_VERIFY=1` (the byte-for-byte check above).

Extra checks besides `test/run.sh`: `test-restart.sh` (a restart right after a stop with open connections comes up
healthy; on Ubuntu's 6.8 kernel the old process's io_uring keeps its listener alive briefly after exit, so `bind()`
is retried for up to 30 s) and `test-rings.sh` (with tiny tables, 2,500 connections spill over 8 rings and all are
answered).

## Credits (ideas only; no files or code copied; all MIT)

- rust-iouring-kensac: rings spilling past the fd cap, 512 accepts in flight, soft `RLIMIT_NOFILE` raised to hard,
  bounded re-arm after `ENOBUFS`, the buffer-ring registration quirk, B-tree cursor reads with schema checks at start.
- c-iouring-pavlyhalim: provided-buffer receive, B-tree read helpers as a pattern.
- kotlin-trikeshed-jnorthrup: Kotlin/Native + SQLite amalgamation built on the box; the head parsed as a struct
  (first character, then verify at fixed offsets); batch wake (256 completions or 1 ms).
- fsharp-uring-delneg: the pcache1 `xRekey` method; one `pwrite` per WAL commit; `mlock` of the binary.
- c-iouring-pavlyhalim: the pcache1 truncate diagnosis, the WAL write-coalescing VFS, `mlock` of the binary.
- go-iouring-DblD: a wider write window (reads never wait for it).
- rust-iouring-rkkautsar: one read snapshot across passes.
- swift-iouring-akbashev: checkpointer at nice 5 with a bounded hold.
- zig-iouring-unorig-username (via the JVM entry): the two-step feed idea that led to the B-tree feed.

## Licences of what the build fetches

SQLite: public domain. liburing: MIT (dual MIT / LGPL-2.1; used under MIT). Kotlin/Native compiler and runtime:
Apache-2.0 (its clang/LLVM bundle: Apache-2.0 with LLVM exceptions; glibc sysroot: LGPL). Temurin JDK: GPLv2 with the
Classpath Exception (build time only).
