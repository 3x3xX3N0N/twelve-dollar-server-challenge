# PR draft (NOT opened). The owner opens it after reading reports/vm-twin2.md

Head: branch `vm-twin2` (on top of `vm-twin` / `b5-native-final`), folder `submissions/kotlin-native-3x3xX3N0N/` only.
Open question for the owner: open this as a new entry (it does not touch `kotlin-nio-3x3xX3N0N` or #377).

---

**Title:** kotlin-native-3x3xX3N0N: Kotlin/Native, io_uring, SQLite B-tree reads, group commit on the loop

**Body:**

Adds `submissions/kotlin-native-3x3xX3N0N/`: the handlers of kotlin-nio-3x3xX3N0N (#83), compiled with Kotlin/Native
instead of the JVM, on one thread over io_uring, with SQLite compiled in. Direct on `HOST:PORT`, no Nginx. Nothing
outside the folder is touched.

- **Passes 42/42**: locally on kernel 7.0, and on stock Ubuntu 24.04 VMs (1 vCPU / 2 GB, kernels 6.8.0-149 and
  6.8.0-117) built from scratch with `install.sh` as root (5-17 s) and `build.sh` as a normal user (184-240 s on
  the one vCPU, profile training included).
- **What is Kotlin and what is C:** the event loop, connection table, HTTP parsing, routing, HS256 (own SHA-256),
  JSON and the group-commit queue are Kotlin (Kotlin/Native 2.4.21, `linuxX64`, `-opt`; the JDK runs only the
  compiler at build time). `csrc/` is io_uring (liburing 2.9, MIT, fetched at its tag and sha256-checked) and
  SQLite: rings, provided buffers, direct descriptors, the B-tree cursor reads and the WAL VFS. It is compiled with
  the clang and glibc sysroot that ship with Kotlin/Native.
- **io_uring:** accepted sockets are direct descriptors in rings that spill past the 65,535 fd cap (up to 8 rings),
  512 single-shot accepts in flight, multishot receives into provided-buffer rings (4,096 × 2 KB per ring; a
  receive that runs out is re-armed in the same pass), and one copy per response. The
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
- **Credit:** rust-iouring-kensac (#264): rings past the fd cap, 512 accepts in flight, re-arm after
  `ENOBUFS` (bounded per pass there; the `KN_REARM` knob here), the buffer-ring quirk, B-tree reads with schema
  checks. kotlin-trikeshed-jnorthrup: K/N with the amalgamation built on the box, the struct-style head parse,
  batch wake. fsharp-uring-delneg and c-iouring-pavlyhalim: the pcache1 `xRekey` method, one `pwrite` per WAL
  commit, `mlock` of the binary, PGO on a synthetic database.
  rust-iouring-rkkautsar: one read snapshot across passes. swift-iouring-akbashev: the checkpointer at nice 5.
  go-iouring-DblD: the wider write window. java-iouring-davidhsv (#393): committing on the reading connection, and
  its pass structure as a knob. The README lists the rest.

**Numbers, LOCAL (not a score)**: i7-10700K desktop, the server pinned to one core in a 2 GB / no-swap cgroup,
loopback in a private network namespace, kload replaying `bench/load.js`. These are 13.1 µs of CPU per request at
160,000 users and 11.8 at 384,000 (medians of 3 interleaved rounds). It held 384,000 and 416,000 users for 5 minutes
with 0 errors (p99 20-22 ms). The highest 60 s pass was 480,000, at the 2 GB memory wall. java-iouring-davidhsv on
the same rig with the database on tmpfs: 12.9 / 11.2 µs/req.

**Numbers on a twin of the box (VM, not a score)**: Vultr `vhp-1c-2gb-intel` (Cascade Lake, 1 vCPU, 2 GB, Ubuntu
24.04, kernel 6.8.0-117, no swap, no ufw, no sysctl), load from four 4-vCPU VMs with one source IP each over a
private network, fresh start and seed per run, 60 s ramp. The VM's NIC needs 4 queues (`ethtool -L`) or the host
drops packets above ~30k/s and every entry collapses near 160k. With that, java-iouring-davidhsv (#393) fails at
the top the way it does on the box (on p99, 0 errors), but lower: it holds 176,000 here against 240,000 officially.
So these numbers compare the two entries, not the leaderboard.

| | this entry | java-iouring-davidhsv (#393) |
|---|---|---|
| 176,000, 5-min hold | PASS, 0 errors, p95 / p99 42 / 281 ms, 41.6 µs/req box-wide, RSS 146 MB | PASS, 0 errors, 71 / 913 ms, 42.5 µs/req, RSS 343 MB |
| 184,000, 60 s step | FAIL on p99 1.16 s, 0 errors | FAIL on p99 1.43 s, 0 errors |
| 192,000, 60 s step | FAIL on p99 2.7 s, 0 errors | FAIL on p99 3.1 s, 0 errors |

kotlin-nio-3x3xX3N0N costs 91 µs/req on that VM (79 official), so it runs a little slower than the box.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
