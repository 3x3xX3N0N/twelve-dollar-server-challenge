# PR draft (NOT opened). The owner opens it after reading reports/vm-twin.md

Head: branch `vm-twin` (on top of `b5-native-final`), folder `submissions/kotlin-native-3x3xX3N0N/` only.
Open question for the owner: open this as a new entry (it does not touch `kotlin-nio-3x3xX3N0N` or #377).

---

**Title:** kotlin-native-3x3xX3N0N: Kotlin/Native, io_uring, SQLite B-tree reads, group commit on the loop

**Body:**

Adds `submissions/kotlin-native-3x3xX3N0N/`: the handlers of kotlin-nio-3x3xX3N0N (#83), compiled with Kotlin/Native
instead of the JVM, on one thread over io_uring, with SQLite compiled in. Direct on `HOST:PORT`, no Nginx. Nothing
outside the folder is touched.

- **Passes 42/42**: locally on kernel 7.0, and on a stock Ubuntu 24.04 VM (1 vCPU / 2 GB, kernel 6.8.0-149) built
  from scratch with `install.sh` as root (12 s) and `build.sh` as a normal user (184-201 s on the one vCPU,
  profile training included).
- **What is Kotlin and what is C:** the event loop, connection table, HTTP parsing, routing, HS256 (own SHA-256),
  JSON and the group-commit queue are Kotlin (Kotlin/Native 2.4.21, `linuxX64`, `-opt`; the JDK runs only the
  compiler at build time). `csrc/` is io_uring (liburing 2.9, MIT, fetched at its tag and sha256-checked) and
  SQLite: rings, provided buffers, direct descriptors, the B-tree cursor reads and the WAL VFS. It is compiled with
  the clang and glibc sysroot that ship with Kotlin/Native.
- **io_uring:** accepted sockets are direct descriptors in rings that spill past the 65,535 fd cap (up to 8 rings),
  512 single-shot accepts in flight, multishot receives into provided-buffer rings, and one copy per response. The
  buffer-ring registration is retried with `resv[0]=1` for Ubuntu's 6.8.0-136+ kernels (taken on the VM), and
  `bind()` is retried after a restart on 6.8 (`test-restart.sh`).
- **SQLite:** the unmodified 3.54.1 amalgamation (SHA3-256-checked), WAL, `synchronous=NORMAL`. `GET /posts/:id` and
  `GET /feed` read through SQLite's own B-tree cursor functions, with a schema check at start and a SQL fallback
  (ruling of 2026-10-31). The JSON is byte-for-byte what `json_object()` writes; `KN_VERIFY=1` compares every post
  id and the feed with the SQL path. The WAL VFS uses the public VFS interface only, and no SQLite structure is
  written from outside.
- **Writes:** group commit after 20 ms or 1,024 writes. The commit runs on the loop on the reader's own connection,
  so the reader keeps its page cache; the 201s go out only after `COMMIT` returns. A slow-disk guard moves commits to
  a thread when a commit takes over 50 ms, a checkpoint over 200 ms, or memory passes 90 %. Checkpoints run on a
  thread at nice 5.
- **Profile-guided C, recorded on the box during `build.sh`**: an instrumented build serves a synthetic scratch
  database (nothing from the seed) to a training client for ~8 s, then the C is rebuilt with that profile. Nothing
  is committed (ruling on rule 10, 2026-11-15). Any failure falls back to a plain build.
- **Credit:** rust-iouring-kensac (#264): rings past the fd cap, 512 accepts in flight, bounded re-arm after
  `ENOBUFS`, the buffer-ring quirk, B-tree reads with schema checks. kotlin-trikeshed-jnorthrup: K/N with the
  amalgamation built on the box, the struct-style head parse, batch wake. fsharp-uring-delneg and c-iouring-pavlyhalim:
  the pcache1 `xRekey` method, one `pwrite` per WAL commit, `mlock` of the binary, PGO on a synthetic database.
  rust-iouring-rkkautsar: one read snapshot across passes. swift-iouring-akbashev: the checkpointer at nice 5.
  go-iouring-DblD: the wider write window. java-iouring-davidhsv (#393): committing on the reading connection, and
  its pass structure as a knob. The README lists the rest.

**Numbers, LOCAL (not a score)**: i7-10700K desktop, the server pinned to one core in a 2 GB / no-swap cgroup,
loopback in a private network namespace, kload replaying `bench/load.js`. These are 13.1 µs of CPU per request at
160,000 users and 11.8 at 384,000 (medians of 3 interleaved rounds). It held 384,000 and 416,000 users for 5 minutes
with 0 errors (p99 20-22 ms). The highest 60 s pass was 480,000, at the 2 GB memory wall. java-iouring-davidhsv on
the same rig with the database on tmpfs: 12.9 / 11.2 µs/req.

**Numbers on a twin of the box (VM, not a score)**: Vultr `vhp-1c-2gb-intel` (Cascade Lake, 1 vCPU, 2 GB, Ubuntu
24.04, kernel 6.8.0-149, no swap, no ufw), load from an 8-vCPU VM over a private network, fresh start and seed per
run, 60 s ramp. kotlin-nio-3x3xX3N0N (`c0f58b9`) costs 76-81 µs/req there against its official 79.
- 60 s steps pass from 96,000 to 160,000 users at 26.3 → 22.0 µs/req process (32 → 29 box-wide); 176,000 fails.
- 5-minute hold at 144,000: PASS, 0 errors, p95 24.7 ms, p99 57.1 ms, 25.0 µs/req, RSS 101 MB. 160,000 fails.
- java-iouring-davidhsv on the same VM: the same pattern. Steps pass to 160,000; 176,000 fails; the 144,000 hold
  passes at 24.4 µs/req, p99 36 ms. It scored 240,000 officially, so this VM is much harsher than the box at the top
  and these are lower bounds.

On that VM the ramp is the limit. Near 150,000 connections it drives the CPU to 100 % and TCP memory past `tcp_mem`.
The README describes what the kernel then does on 6.8 (aborted connections whose direct descriptors are not released
at once).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
