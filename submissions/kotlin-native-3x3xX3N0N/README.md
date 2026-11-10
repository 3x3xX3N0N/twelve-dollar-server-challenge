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

**Writes and durability.** WAL, `synchronous=NORMAL`. Writes are queued and group-committed on a second connection
once the oldest has waited 2 ms or 64 are queued: `BEGIN IMMEDIATE` (busy timeout 0), the INSERTs, `COMMIT`, and
only then are the 201s handed to the kernel. A failed COMMIT answers every write of the batch with a 500.

**Checkpoints off the loop.** A thread at nice 5 runs a PASSIVE checkpoint every 50 ms on its own connection; once
the WAL has 4,096 frames and all but 128 are copied, a RESTART with a 250 ms busy timeout briefly holds the writer
(whose `BEGIN` simply fails and retries next pass, so the loop never blocks) and the WAL starts over from frame 1.
Idea credit: swift-iouring-akbashev, rust-iouring-kensac.

**SQLite build options**: `SQLITE_THREADSAFE=2`, `SQLITE_ENABLE_QPSG` (plans fixed at prepare time),
`SQLITE_DEFAULT_MEMSTATUS=0`, `SQLITE_OMIT_LOAD_EXTENSION`, `SQLITE_OMIT_DEPRECATED`, `SQLITE_OMIT_SHARED_CACHE`,
`SQLITE_DQS=0`, `SQLITE_USE_ALLOCA`. Pragmas: `mmap_size=0`, `cache_size=-65536` (64 MiB), `wal_autocheckpoint=0`.

## Knobs (all optional; the defaults are what is scored)

`KN_VFS` (SQLite VFS, default `unix`), `KN_BTREE=0` (SQL only), `KN_SNAPSHOT=0` (new read transaction every pass),
`KN_WINDOW_US` / `KN_BATCH_MAX` (group commit), `KN_PACE_NR` / `KN_PACE_US` (after a light pass, wait for this
many completions or this long), `KN_RINGS`, `KN_STATS=1` / `KN_CKPT_LOG=1` (counters on stdout/stderr every 10 s),
`KN_VERIFY=1` (the byte-for-byte check above).

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
