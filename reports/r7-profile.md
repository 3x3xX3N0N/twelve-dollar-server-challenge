# r7-profile: where do kotlin-nio's 79 µs per request go?

2026-11-19. Measurement only: the entry was not changed. Entry: `submissions/kotlin-nio-3x3xX3N0N` at 640beef
(kotlin-nio-v3, the same code as the PR #377 head). `test/run.sh`: **42/42 passed**.

## TL;DR

At 18.7k req/s on one pinned core (88% busy), the server spends **47 µs of CPU per request locally**. Upstream
measured 79 µs on the scored box, about 1.7× slower per request; the split below should carry over roughly in
proportion (see Caveats).

| category | µs/req (local) | share | ≈ scored box (×1.67) |
|---|---:|---:|---:|
| **SQLite reads** (feed + post, all layers, without json_object) | **20.1** | 43% | 33.6 |
| **socket write syscall** (kernel TCP send; on loopback it also carries the client's receive path) | **11.5** | 25% | 19.3 |
| **JSON building** (json_object inside SQLite 3.8 + feed assembly / response bytes in Kotlin 0.8) | **4.6** | 10% | 7.7 |
| **SQLite writes / WAL** (like, insert, BEGIN, COMMIT + checkpointer thread 0.6) | **4.3** | 9% | 7.2 |
| socket read syscall | 2.0 | 4% | 3.3 |
| epoll_wait + pacing park (futex) | 1.4 | 3% | 2.3 |
| NIO selector / channel Java side | 1.4 | 3% | 2.3 |
| auth (JWT HMAC-SHA256, likes + posts only) | 0.4 | 0.8% | 0.7 |
| HTTP parse | 0.3 | 0.6% | 0.5 |
| routing | 0.1 | 0.3% | 0.2 |
| GC (Serial young pauses) | 0.08 | 0.2% | 0.1 |
| JIT + other JVM | 0.4 | 0.8% | 0.7 |
| **total** | **46.6** | 100% | 78 |

- **The feed is the problem.** `GET /feed` is 46% of requests, but SQLite work for it costs **≈ 39 µs per feed
  request** locally (18.1 µs averaged over all requests), plus json_object. `GET /posts/:id` costs ≈ 12.6 µs of
  SQLite per request.
- **The kernel takes 44% of all cycles** (perf: 95k kernel vs 120k user cycles per request). One socket write per
  request costs 11.5 µs. SQLite adds about 5.9 µs of syscalls per request: 2.4–3 `pread64` (the page cache is
  re-read after other connections' commits), 3.9 `fcntl` (WAL read-mark locks, 2 per statement) and 0.4 `pwrite64`.
- **Our own Kotlin code is almost nothing.** HTTP parsing, routing, JWT and response building together come to
  about 1.5 µs/req.
- **GC is negligible** (0.08 µs/req, 0.15% of wall time), although we allocate **6.0 KB per request**. 92% of that
  is `byte[]` from the feed path: about 11 KB per feed request, because each response is allocated three times.
- **No megamorphic call site matters.** itable/vtable stubs are 0.1% of samples, nearly all inside sqlite-jdbc's
  `SafeStmtPtr` lambdas.

## Setup

- **Host:** i7-10700K (Comet Lake, ~4.7 GHz under load), Linux 7.0, OpenJDK 25.0.5. The scored box is a 1 vCPU
  Xeon Platinum 8260 VM.
- **Server:** `start.sh` as shipped (WORKERS=3, SerialGC, -Xmx320m, CompactObjectHeaders). It runs in its own
  `systemd-run --user --scope` with `AllowedCPUs=15`, `taskset -c 15`, `MemoryMax=2G`, `MemorySwapMax=0` and
  `ulimit -n 65535`. CPU 15's hyperthread sibling (CPU 7) was left idle. Port 18080; fresh copy of the seed DB
  per run.
- **Load:** k6 v2.3.0 on CPUs 0-6 and 8-13, running `bench/load.js` with every `sleep()` multiplied by THINK. The
  copy is `reports/r7-profile/scripts/load-think.js`, a one-line diff from load.js; the request mix and order are
  unchanged.
  - Why scale the think time: hitting 85% of this fast core with the unscaled script needs about 200k VUs. k6
    uses ~345 KB per VU (6.2 GB measured at 18k VUs), so that doesn't fit on this rig.
  - Operating point: **THINK=0.1, 18,000 VUs → 18.7k req/s, 85–88% of the core, 0 errors**, p95 ≈ 40 ms.
    Each run: 30 s warm-up at half the VUs, then a 30 s ramp and a 150 s hold; the measurement window is the
    middle 90 s.
  - After the OOM incident, k6 runs in **its own scope** with `MemoryMax=6G` (`run.sh` → `k6scope`).
- **Request counts:** read from k6's REST API at the start and end of the window. CPU: server cgroup `usage_usec`
  and per-process utime/stime.

| run | what | req/s | CPU | µs/req (user + sys) |
|---|---|---:|---:|---:|
| perfstat | `perf stat -p` of the 3 JVMs | 18,676 | 88.3% | 47.3 (26.5 + 20.8) |
| cpu | async-profiler 4.6, `-e cpu -i 1ms --threads`, shipped SQLite lib | 18,677 | 88.1% | 47.2 |
| cpu-sym | same, with an unstripped libsqlitejdbc.so (see below) | 18,720 | 87.3% | 46.6 |
| alloc | async-profiler `-e alloc --alloc 64k` | 18,749 | 87.8% | 46.8 |
| inline | `-XX:+PrintCompilation -XX:+PrintInlining` | 18,895 | 80.0% | 42.3 (30 s window) |
| strace | `strace -f -c` as the parent of start.sh, 8k VUs (saturated by strace) | 7,698 | 100% | n/a |

The profilers added no measurable overhead (47.2 / 46.6 / 46.8 vs 47.3 µs with only perf stat counting). Run-to-run
noise is about ±1–2 µs on this shared desktop.

**SQLite symbols.** The shipped libsqlitejdbc.so is stripped (GCC 4.1.2, `-Os`), so 34% of samples landed in one
unnamed blob. `scripts/build-sqlite-sym.sh` rebuilds it from sqlite-jdbc 3.53.4.0 and amalgamation 3530400 with
the same `SQLITE_*` defines and `-Os`, plus `-g -fno-omit-frame-pointer` (GCC 15.2). It is loaded with
`-Dorg.sqlite.lib.path`. Its cost is the same within noise (46.6 vs 47.2 µs/req), so the SQLite-internal split
below comes from that run. The top-level split agrees between the two runs within 0.5 µs per category.

**Kernel frames are unnamed:** `kptr_restrict=1` and no tracepoint access for this user. Kernel time therefore
shows under the user frame that made the syscall (e.g. `SocketDispatcher.write0`). That is enough to attribute it
by syscall, but not to see inside TCP.

## 1. CPU per request by category

Source: `scripts/categorize.py` on `flame/cpu-sqlite-symbols.collapsed.gz`, scaled to the measured 46.6 µs/req.
Values are averaged over all requests. Request mix per k6 iteration: 1 feed, 1 post read, 0.15 like, 0.02 create,
so per request type it is 46.1% / 46.1% / 6.9% / 0.9%.

### Syscalls and the event loop (16.4 µs/req, plus 5.9 µs of SQLite syscalls counted under SQLite)
| item | µs/req | notes |
|---|---:|---|
| `write` (socket) | 11.54 | 1.00 call/req; ~11.5 µs per call |
| `read` (socket) | 1.99 | 1.01 calls/req |
| `epoll_wait` | 1.06 | 0.13 calls/req at saturation; more when lighter |
| pacing `parkNanos` (futex) | 0.29 | 0.24 futex/req, most of them timeouts |
| NIO Java side: selector dispatch, `IOUtil`/`SocketChannelImpl` read/write wrappers | 1.39 | 0.27 µs is `Integer.equals` + `HashMap.getNode` in `EPollSelectorImpl`'s boxed fd→key map |
| accept / close / epoll_ctl | 0.01 | connections are keep-alive |

### HTTP parse, routing, auth (0.8 µs/req)
| item | µs/req |
|---|---:|
| HTTP head scan (`Server.request`, `ieq`) + input buffering | 0.27 |
| routing (`route`, `eq`, `parseId`) | 0.14 |
| JWT verify (HMAC-SHA256 + base64 + claim check), on 7.8% of requests | 0.39 (≈ 5 µs per authed request) |

### SQLite reads (23.9 µs/req including json_object; 20.1 without)
By statement (line-level profile of `Db.feedRange`, stripped-lib run):

| statement | µs/req | per feed request |
|---|---:|---:|
| `feedIds`: `SELECT id FROM posts ORDER BY created_at DESC,id DESC LIMIT 20` | 4.2 | 9 µs |
| `feedLikes`: `SELECT post_id FROM likes WHERE post_id BETWEEN ?1 AND ?2` | 2.4 | 5 µs |
| `feedRows`: `posts JOIN users` + `json_object` over the id range | 12.3 | 27 µs |
| `post`: one row + `json_object` + correlated `count(*)` | 5.8 | 12.6 µs per post request |

By SQLite layer (`scripts/sqlite_split.py`, µs per average request):

| layer | feed | post | sum |
|---|---:|---:|---:|
| B-tree (seek, cursor, cell parse; `sqlite3BtreeTableMoveto` for the users JOIN) | 2.43 | 0.61 | 3.04 |
| JSON functions (`jsonObjectFunc`, `jsonAppendString`); inclusive json_object = 3.44 + 0.38 | 2.16 | 0.19 | 2.35 |
| **kernel `pread64`** (pages re-read from the OS page cache) | 1.31 | 0.95 | 2.26 |
| **kernel `fcntl`** (WAL read-mark lock and unlock per statement) | 1.46 | 0.68 | 2.14 |
| JDBC Java layer (sqlite-jdbc `ResultSet`/`PreparedStatement`, `SafeStmtPtr` lambdas, column-name lookups) | 2.04 | 0.38 | 2.42 |
| VDBE interpreter (`sqlite3VdbeExec` self) | 1.79 | 0.36 | 2.15 |
| pager + page cache (`pcache1Fetch`; `pcache1TruncateUnsafe` 0.24 = cache resets) | 1.38 | 0.64 | 2.02 |
| JVM upcalls from JNI (`NewByteArray`, `SetByteArrayRegion`, `NewObject`, `NewDirectByteBuffer`) | 1.17 | 0.39 | 1.56 |
| statement lifecycle (`sqlite3_step` entry, reset, halt, `DbMaskAllZero`, mutexes) | 1.06 | 0.28 | 1.34 |
| VDBE value ops (Mem, column/bind) | 0.99 | 0.25 | 1.24 |
| WAL index / shm (read txn begin: `walTryBeginRead`, `walFindFrame`) | 0.54 | 0.30 | 0.84 |
| SQLite allocator | 0.31 | 0.16 | 0.47 |
| string/concat (`group_concat`/`||`/stringify) | 0.32 | 0.04 | 0.36 |
| NativeDB.c glue + misc | 0.4 | 0.2 | 0.6 |
| **total** | **18.1** | **5.8** | **23.9** |

Read-transaction setup (`sqlite3PagerSharedLock`, inclusive) is **2.2 µs/req**. It includes the WAL read lock
(fcntl), wal-index checks and, after any commit by any of the 6 connections, a full reset of this connection's page
cache. That reset is why every request does about 2.4–3 `pread64`: interior B-tree pages are fetched again from
the OS page cache after each commit, and with 3 workers committing groups every ~2 ms that is nearly always.
The feed opens **three** separate autocommit read transactions per request.

### SQLite writes / WAL (3.7 µs/req on the loop + 0.6 µs checkpointer)
| item | µs/req | notes |
|---|---:|---|
| like (`postExists` + `INSERT ... ON CONFLICT DO NOTHING`) | 1.93 | ≈ 28 µs per like. **0.69 µs/req is sqlite-jdbc's `updateGeneratedKeys`**, which prepares and runs `SELECT last_insert_rowid()` on every executeUpdate (`sqlite3Parser` at runtime) |
| COMMIT | 1.02 | 0.73 is the WAL `pwrite64` (0.42 pwrite/req) |
| BEGIN IMMEDIATE | 0.46 | includes SQLITE_BUSY → `SQLException` construction (`fillInStackTrace`) when another worker holds the lock, ~0.07 |
| insertPost (+ RETURNING json_object) | 0.30 | ≈ 33 µs per create |
| checkpointer thread (worker 0, nice 5) | 0.61 | PASSIVE every 50 ms; fsync 0.004/req |

### JSON building (4.6 µs/req)
- json_object inside SQLite, inclusive: 3.82 (feed 3.44 = 20 rows per feed, ≈ 0.37 µs per row; post 0.38).
  `jsonAppendString` alone is the #4 hot leaf.
- Kotlin feed assembly (`feedRange` own code + arraycopy): 0.37–0.70. Response head + copy into `obuf`
  (`putResponse`): 0.11. `likeBody`: ~0.

### GC, JIT, other
- GC: 283–286 young collections per 90 s window over the 3 JVMs, 131–135 ms of pauses = **0.08 µs/req** (0.15% of
  wall). No old-gen collections.
- C1/C2 compiler threads: 0.22 µs/req (steady state). Other JVM threads: ~0.

## 2. Syscalls per request

From `strace -f -c` on the whole run (warm-up + main, 1,158,116 requests). strace saturated the core at 7.7k req/s,
so the batching-sensitive counts (`epoll_wait`, `futex`) are lower than in an unsaturated run.

| syscall | per request | caller |
|---|---:|---|
| **fcntl** | **3.91** | SQLite WAL read locks: 2 per read statement (feed = 3 statements, post = 1) |
| **pread64** | **2.40** | SQLite page reads after cache resets |
| read | 1.01 | socket |
| write | 1.00 | socket |
| pwrite64 | 0.42 | WAL frames at COMMIT |
| futex | 0.24 | pacing park (parkNanos), 42% ETIMEDOUT |
| epoll_wait | 0.13 | (saturated) |
| accept, close, epoll_ctl, get/setsockopt, shutdown | 0.08 together | the warm-up/ramp connections |
| fsync | 0.004 | checkpointer |
| **total** | **≈ 9.2** | |

Unsaturated cross-check from `/proc/<pid>/io` during the 18.8k req/s window: `syscr` 4.06/req (socket read 1 +
pread ≈ 3.05) and `syscw` 1.45/req (socket write 1 + pwrite 0.45). So without strace, pread is closer to 3 per
request.

perf stat (90 s window, per request):

| counter | per request |
|---|---:|
| cycles user / kernel | 120.4k / 95.4k (kernel 44%) |
| instructions user / kernel | 108.2k / 61.1k |
| IPC user / kernel | **0.90 / 0.64** |
| L1-icache misses | **11.8k** |
| iTLB misses | 194 |
| cache-misses (LLC) | 1,548 |
| branch-misses | 484 |
| context switches | 0.16 |

Low IPC and ~12k i-cache misses per request point to a big, cold instruction footprint per request: JVM → JNI →
SQLite VDBE → kernel TCP, every time.

## 3. Allocations per request

- Total: **6.0 KB/req**. GC-log estimate over the window: 5,996–6,040 B/req in three runs. async-profiler's
  estimate: 5.9 KB/req.
- 92.6% `byte[]`, 2.7% `DirectByteBuffer`, 1.4% `String`.
- By site (alloc profile, bytes per average request):

| B/req | site |
|---:|---|
| 1,728 | `Db.feedRange`: the output `ByteArray(size)` (size estimated for 10-digit like counts) |
| 1,673 | `NativeDB.column_blob` → `byte[]` per feed row (20 per feed) |
| 1,643 | `Arrays.copyOf` in `feedRange`: the final trim `out.copyOf(o)`, taken on every feed because the estimate always overshoots |
| 121 + 29 | `NativeDB.column_name_utf8` → `DirectByteBuffer`: sqlite-jdbc re-reads column names on every executeQuery |
| 94 + 81 + 82 | `Db.post`: blob, `copyOfRange`, `utf8ByteBufferToString` (column names) |
| 69 + 43 + 27 | column-name `String`s / `String[]` in `feedRange` |
| 29 | boxed `Long` in `setLong` |
| 19 | `Json.str` (POST bodies) |

So a feed response (~3.6 KB) is allocated three times: per-row blobs, the oversized buffer, the trimmed copy. It is
then copied once more into the direct `obuf`.

## 4. Top 20 hot frames (self time, unstripped-SQLite run)

Kernel time is shown against the Java frame that made the syscall.

| # | self % | µs/req | frame |
|---:|---:|---:|---|
| 1 | 24.4% | 11.35 | [kernel] via `SocketDispatcher.write0` (socket write) |
| 2 | 12.6% | 5.88 | [kernel] via `NativeDB.step` (SQLite pread / fcntl / pwrite) |
| 3 | 4.9% | 2.26 | `sqlite3VdbeExec` |
| 4 | 4.0% | 1.87 | [kernel] via `SocketDispatcher.read0` |
| 5 | 3.5% | 1.65 | `jsonAppendString` (SQLite json_object escaping) |
| 6 | 2.9% | 1.36 | `sqlite3BtreeTableMoveto` |
| 7 | 2.2% | 1.00 | [kernel] via `EPoll.wait` |
| 8 | 1.1% | 0.53 | `pcache1Fetch` |
| 9 | 0.8% | 0.39 | `nio.Db.feedRange` |
| 10 | 0.8% | 0.35 | `sqlite3VdbeMemStringify` |
| 11 | 0.8% | 0.35 | `sqlite3GetVarint` |
| 12 | 0.7% | 0.35 | `sqlite3DbMaskAllZero` |
| 13 | 0.7% | 0.31 | [kernel] via `NativeDB.reset` (fcntl unlock at statement end) |
| 14 | 0.6% | 0.30 | `NativeDB.step` (JNI transition) |
| 15 | 0.6% | 0.29 | `jbyte_disjoint_arraycopy` |
| 16 | 0.6% | 0.27 | `java.lang.Integer.equals` (EPollSelectorImpl fd→key HashMap) |
| 17 | 0.5% | 0.24 | `sqlite3_step` |
| 18 | 0.5% | 0.24 | `pcache1TruncateUnsafe` (page-cache reset after foreign commits) |
| 19 | 0.5% | 0.21 | `sqlite3BtreeIndexMoveto` |
| 20 | 0.5% | 0.21 | `nio.Server.request` (all of our HTTP parsing) |

## 5. Megamorphic call sites and inlining

- Dispatch stubs: 81 of 77,015 CPU samples (0.1%, ~0.05 µs/req) are in itable/vtable stubs. 57 of them are in
  `SafeStmtPtr.safeRunConsume` and 17 in `JDBC3Statement.withConnectionTimeout`: sqlite-jdbc routes every
  step/column/reset through lambdas (`SafePtrIntFunction`, `SafePtrConsumer`, `Callable`). C2 reports
  `SafeStmtPtr$SafePtrIntFunction::run ... failed to inline: virtual call` and
  `AutoCloseable::close ... no static binding` from `DB::execute`.
- Our own code has no megamorphic site on the hot path. `Consumer<SelectionKey>` (`onKey`) has one receiver.
  `Server.process`, `accept` and `close` are not inlined into the select loop ("already compiled into a big method" /
  "too big"), which costs a call each, not a megamorphic dispatch.
- The NIO internals (`ByteBuffer::position/put/flip` "no static binding") show up in tier-3 C1 compiles. In the CPU
  profile the Java side of NIO is 1.4 µs/req in total.
- Verdict: megamorphism is not worth chasing. The sqlite-jdbc layering itself (Java layer 2.8 + JNI upcalls
  1.7 + glue 0.4 ≈ **5 µs/req**) is.

## 6. Per-request cost depends on load

THINK=0.1, same binary, each run on its own fresh DB:

| req/s | CPU | µs/req |
|---:|---:|---:|
| 1,268 (1.2k VUs) | 10% | 82.4 |
| 3,172 (3k VUs) | 19% | 59.8 |
| 10,586 (10k VUs) | 53% | 50.0 |
| 18,700 (18k VUs) | 88% | 45–47 |

Fixed per-pass costs (epoll, the pacing park, group commits with fewer writes each) get spread over more requests
as load rises. The scored box ran at 96% CPU, so the high-load row is the relevant one.

## Caveats

- **Loopback.** The server's 11.5 µs `write` includes the client side's TCP receive and wake-up, which runs in the
  sender's context on loopback. The server's `read` (2 µs) is correspondingly cheap. On the scored box the server
  pays TX through the NIC driver, RX softirq for incoming requests and ACKs, and virtualisation exits instead. The
  total kernel network cost (≈ 13.5 µs locally) is the meaningful number; how it splits between read and write
  isn't.
- **Connection count.** THINK=0.1 means 18k open connections instead of ~115k at the scored load. Effects that grow
  with connection count (epoll set size, socket memory, cache footprint) are under-represented. The planned check
  (unscaled `load.js` at 12k VUs vs THINK=0.1 at 1.2k VUs, same req/s) is invalid: the root filesystem was 100% full
  (503 MB free, not from this task), and that run hit `SQLITE_FULL` on 4.3% of requests. I didn't rerun it on a full
  disk. All other runs have 0 errors and no SQLITE_FULL in their logs.
- **CPU.** A 4.7 GHz desktop core vs the 8260 VM. The ×1.67 column scales everything uniformly; kernel-heavy parts
  (syscalls, with eIBRS/VM exits) probably scale worse than that.
- **Symbolised SQLite.** Built with GCC 15 instead of 4.1.2. Total cost is equal within noise, but per-function
  shares inside SQLite may differ slightly.
- **strace.** It saturates the core, so `epoll_wait`/`futex` counts are lower bounds and `pread` reads a bit low (2.4
  vs ~3.05 from `/proc/io` unsaturated).

## Follow-ups (ranked by expected gain; local µs/req, ×1.67 for the scored box)

1. **Cache the feed response bytes across requests (up to ~18–20 µs/req, ~40%).** Every user gets the same feed
   between commits. The cache would be invalidated by a cheap cross-process change check, e.g.
   `PRAGMA data_version` on the read connection, or the WAL-index change counter / `sqlite3_total_changes` plus a
   shared counter for the other workers. That removes 3 statements, 20 json_objects, 3 read transactions, ~6 fcntl,
   ~2 preads and ~11 KB of allocation per feed hit. Check first that the SPEC's freshness rules (new post on top,
   like counts "at once") hold with cross-worker invalidation.
2. **Fewer read transactions and fewer cache resets (2–5 µs/req, if 1 isn't done).** Run the 3 feed statements in
   one read transaction (saves 2 of 3 read-txn setups and 4 of 6 fcntl per feed). Fewer committing processes/connections
   (WORKERS=3 means 3 writers resetting 6 page caches) would cut the ~3 preads/req. That one trades off against the
   fd cap that motivated 3 workers, so re-measure mmap for page reads too.
3. **Bypass sqlite-jdbc (≈ 5 µs/req).** Call sqlite3 through FFM: step/column_blob straight into our buffers, no
   JNI `NewByteArray` upcalls, no per-query column-name fetch, no `SafeStmtPtr` lambdas, no `SQLException` for BUSY.
   Partial step: `SQLiteConfig.setGetGeneratedKeys(false)` (or the equivalent URL option) removes the per-like
   `SELECT last_insert_rowid()` prepare, **0.7 µs/req**, trivial.
4. **Build feed rows without json_object (≈ 2–3 µs/req, if 1 isn't done).** Select the raw columns and write JSON in
   Kotlin. Only `body` needs escaping, and usernames could be cached. json_object costs ~0.37 µs per row.
5. **Feed allocation (≈ 0.3–0.6 µs/req plus less GC/cache pressure).** Size the output exactly or write directly into
   `obuf`, and drop the always-taken `copyOf`. Reuse per-row buffers.
6. **Kernel network path (unknown, up to several µs).** Already at 1 read + 1 write per request. What's left is
   smaller responses (feed ≈ 3.6 KB) or a different I/O model (io_uring, as in the kotlin-native branch). This has to
   be measured on the VM, not on loopback.
7. **Selector overhead (≈ 0.3–0.5 µs/req).** `EPollSelectorImpl`'s boxed `Integer` fd→key map; only a custom
   epoll via FFM avoids it.
8. Not worth it: HTTP parse/routing (0.4), JWT (0.4), GC (0.08), megamorphic sites (0.05).

## Files

- `reports/r7-profile/flame/` (async-profiler HTML; open in a browser):
  - `cpu.html` / `cpu-reversed.html`: CPU, shipped SQLite lib, per-thread roots, 3 workers merged.
  - `cpu-sqlite-symbols.html` / `-reversed.html`: CPU with the unstripped SQLite.
  - `alloc.html`: allocation samples.
  - `*.collapsed.gz`: the merged stacks the tables were computed from.
- `reports/r7-profile/scripts/`:
  - `run.sh`: driver. Server scope 2G, k6 in its own 6G scope; modes base/cpu/alloc/strace/perfstat/inline.
  - `load-think.js`: load.js plus THINK.
  - `merge.sh`: JFR → merged collapsed.
  - `categorize.py`: categories.
  - `sqlite_split.py`: SQLite layers.
  - `gcwin.py`: GC/allocation in the window.
  - `inlining.py`: C2 inline failures.
  - `build-sqlite-sym.sh`: unstripped libsqlitejdbc.
- Not committed (in the worktree only): `tools/` (async-profiler 4.6 tarball sha256
  `1e79ed54…da36`, sqlite-jdbc checkout, amalgamation, symbol build) and `tmp/runs/` (raw JFRs, logs).
