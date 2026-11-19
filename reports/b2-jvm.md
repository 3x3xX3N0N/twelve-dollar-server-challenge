# b2-jvm: Kotlin on plain HotSpot over our own io_uring + B-tree shim (FFM)

Branch `b2-jvm` (off `kotlin-native` f047368), submission `submissions/kotlin-jvm-uring-3x3xX3N0N`.
Commits: 78de721 (port, 42/42), c0caeb4 (tricks), 53fe8d3 (comments), plus the README/report commit.
Server core 13 (HT sibling 5 idle), load cores 0-3 and 8-11, ports 18110-18112. Nothing pushed.

## TL;DR

- **The JVM is not the gap.** The Kotlin/Native entry ported to HotSpot 25 (C2, Serial GC) over FFM costs about
  +5 % CPU per request with identical settings (20.0 vs 19.0 µs/req, two interleaved rounds, same rig). In the
  profile, all Java code plus the FFM stubs and the JIT is ~7 % of samples (~1.1 µs/req). GC: one 0.1 ms young
  collection every ~14 s.
- **The final JVM build is cheaper than the Kotlin/Native entry**: 15.2-17.4 µs/req at 160k vs K/N 18.2-19.8 on the
  same rig. The win comes from three changes that would carry over to K/N as well (none is JVM-specific):
  group commit on the reader connection (one connection, no committer thread), a 256 MiB reader page cache, and a
  10 ms commit window. Plus `-O3 -march=native` for the C.
- **Highest 60 s pass: 416k users** (13.2-15.0 µs/req, p99 12.5 ms, cgroup peak 1,782 MB); 448k was OOM-killed at 2 GB
  (K/N holds 448k: our JVM process is ~190 MB vs ~86 MB, plus the bigger page cache). Cold start (no warm-up) passes
  384k with p99 11.5 ms.
- **java-iouring-davidhsv (#393) is still ~18 % cheaper on this rig** (13.0-14.1 vs 15.7-17.4 µs/req, tmpfs DB).
  The profiles put the gap in **kernel time** (system 8.35 vs 10.2 µs/req). User time is close: our C + Java ≈ his
  C + Java. On the shared disk his entry *fails* at 160k (p95 1.27 s) because his COMMIT runs on the loop.
- `test/run.sh submissions/kotlin-jvm-uring-3x3xX3N0N`: **`passed=42 failed=0`** (also with `KJ_COMMITTER=1`).
  `KJ_VERIFY=1`: 500,010 ids + feed, 0 B-tree/SQL mismatches with the -O3 build.

## Design

Everything the K/N entry does (one thread, io_uring direct descriptors over up to 8 rings, multishot recv + provided
buffers, B-tree reads with schema check and SQL fallback in `csrc/btree_reads.c`, read snapshot across passes,
checkpointer thread), with the Kotlin handlers on the JVM. `csrc/uring.c`, `db.c`, `btree_reads.c` are our K/N files.
Changes to them: `ur_poll` split into `ur_enter` + `ur_reap`; `db.c` gained the on-loop commit mode and knobs.

- **FFM boundary** (`src/Native.kt`, `csrc/jvm.c`): one top-level `private val` MethodHandle per C function (static
  final, so C2 constant-folds and inlines the stub), `invokeExact` with exact descriptors (checked with javap: Kotlin
  emits them from argument types + `as` cast). Every non-waiting call is `Linker.Option.critical(true)` with Java
  arrays as heap segments (one cached segment per array, offsets as int params: no per-call segment or slice
  allocation). The waiting call (`kj_enter` = submit + `io_uring_enter` wait), `db_wq_start` and `kj_pass_end` (both
  may run a COMMIT) are ordinary downcalls, so a safepoint never waits on blocking I/O.
- **One crossing per pass for completions**: `kj_reap` writes 5 ints per event into an `int[]` and copies all
  received bytes into one 8 MiB `byte[]`, then returns the provided buffers at once (jnorthrup's `feed_reap` idea).
  SQLite writes feed/post JSON straight into the Java output array; `kj_send` hands a slice to the send path.
- **Loop**: the K/N `Server.kt`, ported (`System.arraycopy` for memcpy, `System.nanoTime` for the clock). Flat
  per-slot arrays, final classes, no interface dispatch on the hot path. JWT: our own SHA-256 with precomputed
  ipad/opad states (from K/N); `exp` required.
- **Group commit on the loop, on the reader connection** (default; `KJ_COMMITTER=1` = K/N's committer thread). End
  the read snapshot, `BEGIN IMMEDIATE` with busy timeout 0 (if a checkpoint RESTART holds the write lock, the batch
  stays staged and `db_pass_end` retries each pass while reads continue), INSERTs, COMMIT, then the eventfd fires
  and the next pass answers the 201s. Window 10 ms or 1,024 writes.
- **Runtime**: `-XX:+UseSerialGC -Xms96m -Xmx96m -XX:+UseCompactObjectHeaders -XX:-UsePerfData`, JDK 25.0.4.1
  Temurin. No AppCDS, no warm-up before bind (measured unnecessary, below). Not Graal.
- **Build**: install.sh = build-essential + Temurin 25 + kotlinc 2.4.21 zip (sha256 pinned, matches the published
  .sha256). build.sh = SQLite 3.54.1 + liburing 2.9 (pinned), gcc → `build/libkj.so`, kotlinc → `build/app.jar`
  (stdlib included). 32 s, peak RSS 626 MB (kotlinc at `-Xmx600m`), far under the 1.5 GB cap. No Gradle.

## Numbers (LOCAL, i7-10700K, relative only)

Method = the kotlin-native README "Measured" method: server pinned to core 13 with taskset inside
`systemd-run --user --scope -p MemoryMax=2G -p MemorySwapMax=0 -p AllowedCPUs=13`, `ulimit -n 65535`, in a private
user+net namespace (bwrap) like knio-v3/bench-ns.sh; kload (k6-compatible replay of bench/load.js) on 0-3,8-11 in
its own scope (MemoryMax=6G), joined to the namespace with nsenter; 25 s warm-up at 1,000 VUs, 30 s ramp, 60 s hold.
µs/req = server CPU (user+sys, all threads) during the hold / hold requests. p95/p99 below are the hold's.
Driver: `/mnt/nebula/excal/dev0/tdsc-fleet/b2-work/bench.sh` (+ `ab.sh` for interleaved A/B); every run's
row is in `b2-work/results.tsv`, raw outputs in `b2-work/runs/`.

**Noise warning**: other agents ran benches and VMs on the same desktop (load 2-11). The same config measured
15.2-17.4 µs/req across the afternoon. All A/Bs are interleaved pairs, ≥ 2 rounds; differences under ~5 % are noise.

### Final build

| Users | Run | Result | µs/req (user) | CPU | p95 / p99 | RSS / cgroup peak |
|---|---|---|---|---|---|---|
| 160,000 | 60 s, disk, ×2 | PASS | 15.6 (5.8), 15.2 (5.8) | 26 % | 4.9 / 10.3 ms | 157 / 766 MB |
| 160,000 | 60 s, tmpfs, ×4 | PASS | 15.7, 17.4, 15.2, 14.5 | 25-29 % | 4.4 / 10.2 ms | 160 / 751 MB |
| 256,000 | 60 s, disk | PASS | 14.2 (5.2) | 38 % | 5.2 / 10.4 ms | 167 / 1,142 MB |
| 384,000 | 60 s, disk | PASS | 13.2 (4.9) | 54 % | 5.9 / 10.9 ms | 185 / 1,652 MB |
| 384,000 | 60 s, disk, **no warm-up** | PASS | 14.1 (5.1) | 57 % | 6.6 / 11.5 ms (whole run 6.2 / 11.3) | 185 / 1,652 MB |
| **416,000** | 60 s, disk | **PASS** | 15.0 (5.4) | 66 % | 7.4 / 12.5 ms | 191 / 1,782 MB |
| 448,000 | 60 s, disk | FAIL: OOM kill (2.1 G peak) | | | one 2.0 s loop stall (COMMIT) before it | |

Per endpoint at 160k: feed p95/p99 0.3/1.5 ms, post 0.2/1.1 ms, like 10.4/12.1 ms, create 10.6/11.8 ms (writes wait
for the 10 ms window). At 416k: reads p99 7.2-7.6 ms, writes 25.7 ms.

### Same-rig comparison (160k users, tmpfs DB, final interleaved batch, 2 rounds)

| entry | µs/req | user µs | p95 / p99 | RSS |
|---|---|---|---|---|
| **kotlin-jvm-uring (this)** | 15.7, 17.4 | 5.9, 6.8 | 4.4 / 10.2 ms | 159 MB |
| same jar/so, K/N settings (`KJ_COMMITTER=1 KJ_CACHE_KB=65536 KJ_WINDOW_US=2000 KJ_BATCH_MAX=64`) | 20.2, 19.7 | 7.5, 7.5 | 1.7 / 2.5 ms | 149 MB |
| kotlin-native-3x3xX3N0N (prebuilt n7 = c5263b5 + the 10 s busy wait, ≈ f047368 minus bind retry) | 19.8, 18.2 | 7.6, 7.0 | 1.3 / 2.3 ms | 59 MB |
| java-iouring-davidhsv #393 (built here: JDK 27.0.1, his build.sh with PGO, in a private netns) | 14.1, 13.0 | 5.4, 5.0 | 4.1 / 7.5 ms | 178 MB |

On the shared disk instead of tmpfs: #393 FAILED 160k (p95 1.27 s, p99 1.83 s; 13.9 µs/req) while ours passed
(p99 10.3 ms). His COMMIT runs on the loop, and this desktop's /mnt/nebula disk is shared and slow (see
local-bench-rig memory notes). Our on-loop commit has the same exposure in principle (see the 448k stall); the
difference may be his per-pass transaction + 5 ms window vs our 10 ms window, or his VFS. Not investigated.

### Before/after per trick (160k, interleaved, µs/req)

| trick | before → after (avg of rounds) | kept |
|---|---|---|
| K/N entry ported as is to HotSpot (FFM critical + heap segments) | K/N 17.4 → JVM 19.1 (first pair); 19.0 → 20.0 (final batch) | baseline |
| commit window 2 → 10 ms, batch max 64 → 1,024 | 17.6 → 16.1 (30 ms: 15.8, p99 28 ms) | yes, 10 ms |
| C `-O2` → `-O3 -march=native` | 17.4 → 17.0 (lower in both rounds) | yes (+ `-mprefer-vector-width=256` for the box) |
| commit on the loop on the reader connection (no committer thread) | 18.0 → 16.8 tmpfs; 18.6 → 17.8 disk | yes |
| + reader page cache 64 → 256 MiB | 16.8 → 15.4 tmpfs | yes |
| 256 MiB cache with the committer thread still committing | 20.6 → 19.4 (noisy) | superseded |
| reader `mmap_size=256 MiB` (64 MiB cache, committer) | 20.6 → 20.7 | no |
| `IORING_SETUP_DEFER_TASKRUN` alone | 17.4 → 17.4 | no (knob `KJ_DEFER`) |
| wait for 32 CQEs / 1 ms after a light pass | 17.4 → 17.1 | no (knob) |
| DEFER_TASKRUN + wait 256 CQEs / 1 ms | 14.85 → 14.35 (sys 9.15 → 8.65) | no (within noise; see follow-ups) |
| AppCDS / warm-up before bind | not built: healthy in 0.35 s with 0.35 s CPU; cold 384k passes p99 11.5 ms | no |
| zero allocation on the write path | not done: 1 young GC per ~14 s, 0.1 ms, ≈ 77 B/req | no |

## Where the time goes (async-profiler 4.6, cpu, 1 ms, 40 s of the hold at 160k)

Kernel symbols are hidden (kptr_restrict=1), so kernel time shows under the user frame that entered the syscall.
Fractions of all samples in the process (all threads) → µs/req of that run.

| bucket | port as is (64 MiB, committer, 2 ms) 19.0 µs | final (on-loop, 256 MiB) 16.1 µs | davidhsv #393 14.9 µs (agent from start, incl. JIT warm-up) |
|---|---|---|---|
| io_uring_enter (kernel: TCP send/recv, task work) | 46.3 % → 8.8 | 57.4 % → 9.2 | 55.0 % → 8.2 |
| `pread` of SQLite pages (`unixRead`) | 9.0 % → 1.7 | **0.0 %** | 0.0 % |
| C user: SQLite + B-tree + JSON in C + liburing | 24.9 % → 4.7 | 32.2 % → 5.2 (now incl. INSERTs) | 22.5 % → 3.4 (C is cursor moves only) |
| Java (+ FFM stubs, arraycopy) on the loop | 6.2 % → 1.2 | 6.5 % → 1.05 | 15.9 % → 2.4 (record decode + JSON writer in Java) |
| committer thread (sqlite, mutex, eventfd) | 9.9 % → 1.9 | — | — |
| checkpointer thread | 2.8 % → 0.5 | 1.5 % → 0.24 | (inside) |
| JIT / GC threads | < 0.3 % | 0.3 % | 5.7 % (startup included) |

Reading:
1. **The JVM costs ~1 µs/req**: Java self time 1.05-1.2 µs including `nep_invoker_blob` and `LambdaForm$MH` frames
   (~0.5 % together; a few downcalls are not fully inlined into the caller but cost nothing measurable). Our
   Java does less than davidhsv's (he decodes records and writes JSON in Java with the Vector API, 2.4 µs). Our C does
   that instead (`put_str`, `bt_post_head`, `bt_feed` ≈ 6 % ≈ 1 µs). **User-side work is about equal: ours C+Java
   ≈ 6.25 µs, his ≈ 5.8-6.1 µs.** His C is LTO + PGO.
2. **The fixed gap was the two-connection design.** The committer thread's COMMITs made the reader drop its page
   cache (SQLite `pagerBeginReadTransaction` → `pager_reset` when the WAL header changed) every 2 ms, so a post
   read cost a `pread` per page (9 %). The committer thread (its own SQLite work, mutex, eventfd) was another 1.9 µs, of which the INSERTs themselves
   moved to the loop (C user rose 4.7 → 5.2 µs). K/N has the same cost.
3. **What is left is the kernel**: system time 10.2 vs 8.35 µs/req (final batch averages). His kernel-facing design
   differs in: `DEFER_TASKRUN` with a 256-CQE/1 ms wait, 8 `SO_REUSEPORT` listeners, 16,384 × 1 KB provided buffers,
   every response of a pass sent after that pass's COMMIT (one send per connection per pass). Only the first was
   tried (−0.5 µs sys, within noise). On the scored VM the kernel side was ×2.7 more expensive for K/N
   (knative-vm-report), so this is where the next real win should be.

## Deviations from the brief

- **Disk**: the root fs (/home, my worktree) was at 0-264 MB free all session (not my files; I deleted nothing of
  others'). Build output, DB copies, TMPDIR, async-profiler, the kotlinc and JDK 27 downloads live in
  `/mnt/nebula/excal/dev0/tdsc-fleet/b2-work/` (the submission's `build` is a symlink there, git-ignored as `/build`).
  `seed/feed.db` and `seed/tokens.json` in the worktree are symlinks to the main checkout's (read only).
- **Load generator**: kload (k6 replay), not k6; private netns for every run (also at 160k), so there is no conntrack
  and no port clash with the other tracks.
- **tmpfs DB** for the cross-entry comparison only (the shared disk made #393 fail); the final-build table is on disk.
- **K/N reference** is the prebuilt `knative/builds/n7` binary (c5263b5 + db.c change), not a fresh f047368 build:
  it differs only by the bind() retry.
- davidhsv's entry was built in `b2-work/dav` (a copy; upstream untouched) with JDK 27.0.1 downloaded to
  `b2-work/opt/jdk-27`. His PGO training binds an ephemeral port, so the whole build ran inside `bwrap --unshare-net`.
- The JWT uses our own Kotlin SHA-256 (from K/N), not `javax.crypto.Mac`. JWT is 1.4 % of samples; not A/B'd.

## Follow-ups (not done)

1. Port the on-loop commit + 256 MiB cache + 10 ms window to the K/N entry (same C files; expect the same ~15-20 %).
2. Kernel side, on a real VM (vhp-1c-2gb-intel): DEFER_TASKRUN + 256-CQE wait (`KJ_DEFER=1 KJ_PACE_NR=256
   KJ_PACE_US=1000`, already in the code), 8 SO_REUSEPORT listeners, smaller provided buffers, one send per
   connection per pass. Locally these cannot be told apart from noise; on the VM syscalls cost more.
3. PGO + LTO for libkj.so with a build-time training run on a synthetic DB (as #393 does; committed profiles are
   forbidden, training on the box is what he does). C user time is 5.2 µs/req.
4. The on-loop COMMIT can stall reads when `write()` stalls (one 2.0 s pass at 448k under memory pressure; one
   run at 160k on tmpfs had hold p99 342 ms whose cause I did not catch, with no stall logging on). Options: keep
   the committer thread but put reads on the writer connection between commits, or cap the WAL write per pass.
   Measure on the VM's disk before choosing.
5. Memory: 256 MiB cache + ~190 MB JVM process cost the 448k rung vs K/N. On the scored box CPU binds first
   (~128-144k for K/N on the VM), so this trade looks right, but a 128 MiB cache is a measured-nothing middle option.

## Open questions for the owner

- Is a 256 MiB SQLite page cache (`PRAGMA cache_size`) acceptable under rule 5? It is SQLite's own pager cache, not an
  application cache, and the leaders use 64 MiB. I think yes, but it is the one setting a reviewer might question.
- Do you want the JVM entry as a submission, or only as the "keep the JVM" baseline? It beats K/N locally only because
  of commit/cache changes that K/N could take too (follow-up 1).
- On-loop commit (cheaper, as #393/kensac do) vs committer thread (immune to slow disk writes): which risk do you
  prefer for the scored box? Both are in the code (`KJ_COMMITTER=1`).
