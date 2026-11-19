# Kotlin on GraalVM (native-image), no framework: io_uring + SQLite B-tree reads through FFM

The Kotlin handlers of [kotlin-nio-3x3xX3N0N](../kotlin-nio-3x3xX3N0N) (HTTP parsing, routing, JWT, JSON, group
commit), in the flat-array form of [kotlin-native-3x3xX3N0N](../kotlin-native-3x3xX3N0N), compiled for the JVM and
then ahead of time with GraalVM `native-image`. They call the same C side as the Kotlin/Native entry (our io_uring
transport and SQLite B-tree read paths, `csrc/`) through the Java Foreign Function & Memory API.

| | |
|---|---|
| Language | Kotlin 2.4.21 (JVM target 25) |
| Runtime | **GraalVM Community 25.5.5 native-image** (JDK 25.0.5), Serial GC, 96 MB heap. `KG_MODE=jit`: the same jar on the GraalVM JDK with the Graal JIT |
| Framework | none (`src/Server.kt`) |
| Native calls | `java.lang.foreign` (FFM) downcalls into `build/libkn.so` (`csrc/`, built by `build.sh` with gcc) |
| io_uring | liburing 2.9 (MIT), fetched by `build.sh` at its release tag, sha256-checked, linked into `libkn.so` |
| SQLite | 3.54.1 amalgamation, unchanged, SHA3-256-checked against sqlite.org, compiled into `csrc/db.c` |
| Nginx or direct | **Direct**: serves `HOST:PORT` itself (`0.0.0.0:80` on the benchmark box) |
| Needs | Linux 6.0+ io_uring (multishot receive, provided-buffer rings, direct descriptors). No epoll fallback |

## Design

**The C side is the Kotlin/Native entry's, unchanged in what it does** (see that README): one thread, up to 8 rings
with sparse direct-descriptor tables (no fd per client, past the 65,535 wall), single-shot accepts, multishot receive
into provided-buffer rings, the Ubuntu 6.8 `resv[0]=1` buffer-ring retry, B-tree cursor plans for `GET /feed` and
`GET /posts/:id` with a schema check at start and SQL as the fallback, one read snapshot across passes, group commit
on a committer thread that wakes the loop through an eventfd, a checkpointer thread at nice 5.

**What is new is the FFM face, `csrc/jv.c` (80 lines), shaped so that Java crosses into C as rarely as possible:**
- **One downcall per busy loop pass.** `jv_step` sends the responses the previous pass staged (a table of slot,
  generation, offset, length in an `int[]`), ends the pass on the database side, reaps every ring, copies each
  completion into an `int[]` (kind, slot, generation, length) and the received bytes, back to back, into one
  `byte[]`, and gives the provided buffers back to the kernel. Java then parses every request in place in that array.
- **One downcall per read plan.** `jv_feed` / `jv_post` write the response body straight into the output array, at a
  gap left for the head; the head is then written into the gap in front of the body, so the body is never moved.
- **One downcall per staged write** (the body and author go straight into the C-side batch) and one for all the
  results of a committed batch.
- **Handles:** every `MethodHandle` is a `static final` made *without* a target address
  (`Linker.downcallHandle(descriptor, options)`, the address is the first argument), in `object H`, which
  native-image initializes at image build time (`--initialize-at-build-time=app.H`), so each call compiles to a
  direct call into a stub generated at build time. The addresses live in `object A`, looked up in `libkn.so` when the
  process starts. The downcall descriptors are registered for the image in `native-image/.../reachability-metadata.json`.
- **`Linker.Option.critical(true)`** on everything that never blocks: no thread-state transition, and the Java
  arrays are passed in place (each wrapped once in a `MemorySegment` at start, plus an int offset per call, so no
  call allocates or copies). **The one call that sleeps (`jv_wait`, waiting for completions) is a plain downcall**:
  a thread parked inside a critical call is still "in Java", so the VM could never reach a safepoint (a SIGTERM
  exit hung in the first version). `jv_step` itself never sleeps; only a pass that finds nothing calls `jv_wait`
  and steps again.
- **Hot-path shape:** connections are slots in flat primitive arrays, events dispatch on an int, every class is final,
  and there is no virtual call on the request path, so every call site is monomorphic (the "megamorphism"
  concern does not arise). The GET path allocates nothing. The write path still allocates a few small objects per
  write (the JWT's and body's JSON maps, the trimmed body string): with the Graal JIT and `-Xlog:gc` at 320k users that
  is one young collection of ~26 MB every ~8 s, 0.2 ms each.

**Kotlin keeps every decision**: the event loop, the request parser (end of head, request line, only the
Content-Length / Authorization / Connection / Transfer-Encoding headers), routing, HS256 with the key's pad states
hashed once at start (own SHA-256), `exp` required, every token verified, the body checks (JSON, trim, 500 code
points), status codes, the group-commit window (2 ms or 64 writes) and answering after COMMIT.

**Build flags.** C: `-O3 -march=native -mprefer-vector-width=256` (built on the box, for the box; 256-bit vectors
so Cascade Lake never runs AVX-512 code). native-image: `--gc=serial -march=x86-64-v3 -O2`, builder heap 800 MB.
(`--no-fallback` is deprecated in GraalVM 25.5 and has no effect: there is no fallback image any more.)
SQLite build options and pragmas: as the Kotlin/Native entry (`SQLITE_THREADSAFE=2`, `SQLITE_ENABLE_QPSG`,
`mmap_size=0`, 64 MiB cache, `wal_autocheckpoint=0`, ...).

## Measured (LOCAL, relative only)

i7-10700K desktop. The server is pinned to one core (`taskset`, `AllowedCPUs`) in a `systemd-run` scope with
`MemoryMax=2G`, `MemorySwapMax=0`, `ulimit -n 65535`, inside a private network namespace (no conntrack limit); kload
(a k6-compatible replay of `bench/load.js`) runs on other cores in its own scope (6 GB), after a 25 s warm-up at
1,000 users; 30 s ramp, 60 s hold. µs/req = the server's CPU time over the hold / requests in the hold. A desktop
core is faster than the droplet's vCPU and loopback is not a NIC: these numbers rank designs, they are not a score
(the Kotlin/Native entry measured ~14 µs/req here and ~36 µs/req on a scored-box-like VM).

| Users | Build | Result | CPU µs/req | p95 / p99 | RSS | cgroup peak |
|---|---|---|---|---|---|---|
| 160,000 | native-image | PASS (×10) | 17.7-18.9 (one outlier 21.6); final build 17.7 | 1.1-1.9 / 2.3-3.1 ms | 54-86 MB (idle 11-12) | 680-722 MB |
| 160,000 | Graal JIT (`KG_MODE=jit`) | PASS (×4) | 17.6-19.7 | 1.2-2.1 / 2.3-20 ms | 162-370 MB (idle 141-365) | 770-1,000 MB |
| 160,000 | Kotlin/Native entry, same rig, interleaved | PASS (×2) | 18.0, 19.8 | 1.2-1.5 / 2.3-2.4 ms | 60 MB | 690 MB |
| 160,000 | java-iouring-davidhsv (#393), same rig | PASS | 13.9 | 4.3 / 7.5 ms | 176 MB | 791 MB |
| 320,000 | native-image | PASS | 16.0 | 2.5 / 15.2 ms | 68 MB | 1,311 MB |
| 320,000 | Graal JIT | FAIL, then PASS | 17.2 / 16.4 | 1,036 / 3,752 ms, then 8.9 / 52 ms | 173-179 MB | 1,402-1,645 MB |
| 384,000 | native-image | PASS | 15.5 | 1.9 / 4.2 ms | 75 MB | 1,559 MB |
| 448,000 | native-image | PASS (×2) | 14.8-16.1 | 6.8-69 / 72-309 ms | 83-87 MB | 1,827-1,840 MB |
| 480,000 | native-image | PASS (×3, at the edge); final build 13.8 | 13.8-14.3 | 7.4-82 / 416-971 ms | 88-89 MB | 1,965-1,977 MB |

- **native-image vs Graal JIT: the same CPU per request; native-image is the default.** At 160k the two are
  within this rig's noise. The JIT costs ~130-300 MB more memory (the limit at the top is memory: ~4 KB of kernel
  socket memory per connection). On one core its compiler threads also compete with the loop during the ramp
  (CPU 80-88 % in the ramp vs 50-60 % for native at 320k), and one of its two 320k runs failed on latency
  (connect p99 3 s). native-image starts in ~0.1 s at full speed.
- **Graal native-image vs Kotlin/Native over the same C: a tie** (18.1-18.3 vs 18.0-19.8, interleaved). A profile at
  160k (perf, native-image): 62 % kernel, 27 % `libkn.so` (SQLite B-tree, the JSON writers), 7 % Kotlin code;
  the FFM stubs do not show.
- The p99 at 448k/480k comes from writes (like/create p95 ~1.5 s at 480k, reads p99 ~70 ms): the desktop's disk is
  shared with other jobs (IO pressure 30-46 %), and the commit runs off the loop, so reads are not held up.

Steps (each kept only if it helped):

| Change | Before → after | Kept |
|---|---|---|
| C shim `-O2` → `-O3 -march=native` | feed plan 6.25-6.45 → 5.76-6.15 µs/call, post 2.40-3.11 → 2.43-3.11 (read micro-benchmark, alternating); not resolvable in load runs | yes |
| Blocking wait as a non-critical downcall | SIGTERM exit hung (no safepoint) → clean exit, restart in 0.14 s | yes (correctness) |
| Pacing `KN_PACE_NR=256 KN_PACE_US=1000` (wait for 256 completions or 1 ms after a light pass) | 160k: 17.7-18.3 → 16.3-17.3 µs/req, p95 1.3 → 3.6-4.8 ms; **448k: PASS → FAIL** (reads p99 191 → 963 ms, 14.8 → 16.9 µs/req), 480k: PASS → FAIL | no (knob): ring 0's wait holds back the other 7 rings |
| `KN_DEFER=1` (`DEFER_TASKRUN`) on top of pacing | 16.3-17.3 → 18.0-18.2 µs/req at 160k | no (knob) |

Build on one core (`taskset -c 12`, a 1.5 GB scope): 4 min 16 s in all (native-image 3 min 18 s), cgroup peak
1,129 MB with page cache, native-image builder RSS 1.04 GB.

## Knobs (all optional; the defaults are what is scored)

`KG_MODE=jit` (Graal JIT instead of the native image), `KG_HEAP` (default `96m`), `KG_JAVA_OPTS` (extra JVM flags in
JIT mode). Build: `KG_NATIVE=0` (no native image), `KG_NI_XMX` (builder heap, default `800m`), `KG_MARCH`,
`KG_NI_O`, `KG_CFLAGS`, `KG_NI_EXTRA`. The C side's knobs, as in the Kotlin/Native entry: `KN_VFS`, `KN_BTREE=0`,
`KN_SNAPSHOT=0`, `KN_WINDOW_US` / `KN_BATCH_MAX`, `KN_PACE_NR` / `KN_PACE_US`, `KN_DEFER=1`, `KN_RINGS`,
`KN_STATS=1`, `KN_VERIFY=1`.

Extra checks besides `test/run.sh`: `test-restart.sh` (a restart right after a stop with 2,000 open connections
comes up healthy) and `test-rings.sh` (with tiny tables, 2,500 connections spill over 8 rings and all are answered).
Both pass in both modes and with pacing on.

## Credits (ideas only; no files or code copied; all MIT)

- kotlin-trikeshed-jnorthrup: static-final, address-less FFM handles initialized at native-image build time,
  `critical(true)`, the per-state / monomorphic call-site discipline, GraalVM native-image for a Kotlin server.
- java-iouring-davidhsv: FFM over an io_uring + B-tree C side from a JVM language, critical downcalls only for what
  never waits, the AVX-512 caution for Cascade Lake.
- Everything the Kotlin/Native entry credits for the C side: rust-iouring-kensac, c-iouring-pavlyhalim,
  rust-iouring-rkkautsar, swift-iouring-akbashev, zig-iouring-unorig-username.

## Licences of what is fetched

SQLite: public domain. liburing: MIT (dual MIT / LGPL-2.1; used under MIT). GraalVM Community: GPLv2 with the
Classpath Exception (the native image links its runtime under that exception). Kotlin compiler and stdlib: Apache-2.0.
