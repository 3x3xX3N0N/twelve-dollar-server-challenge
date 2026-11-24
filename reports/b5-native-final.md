# b5-native-final: commit on the reader, build-time C PGO, and the kernel gap to #393

Branch `b5-native-final` (off `b3-native` 6a0b38b). Submission: `submissions/kotlin-native-3x3xX3N0N`.
Server core 14 (HT sibling 6 idle), load cores 0-3 and 8-11, ports 18140-18149. Nothing pushed.
All numbers are LOCAL (i7-10700K desktop shared with two other build agents and desktop apps), so they rank
designs; they are not a score.

## Result

- `test/run.sh submissions/kotlin-native-3x3xX3N0N`: **`passed=42 failed=0`** (final build, PGO default; also 42/42
  with `KN_COMMITTER=1` and with `KN_PASS=sweep`). `test-restart.sh` PASS (healthy in 0.03 s), `test-rings.sh`
  PASS (also with `KN_PASS=sweep`). PGO fallback exercised (`KN_TRAIN_TIMEOUT=1`: "!! PGO training failed", plain
  build, rc 0).
  `KN_VERIFY=1` on the PGO build: 500,010 post ids + the feed, 0 mismatches. `PRAGMA integrity_check` ok after
  every final run.
- **160k users: 13.4 µs/req final run, 12.5-13.3 in the A/B rounds** (b3 the same afternoon: 14.8-15.2), user CPU
  5.9 → 4.3-4.8 µs/req. **256k: 12.2** (b3: 14.0-16.0 the same day).
- **416k 5-minute hold: PASS, 0 errors, 12.9 µs/req, p95/p99 10.8 / 21.9 ms** (cgroup peak 1,816 MB).
- **Highest 60 s pass: 448k reliably** (12.1 µs/req, p99 22 ms); **480k passes 1 of 2** at the defaults (p99 946 ms,
  then a FAIL at 1,106 ms), and once more with `KN_CACHE_KB=32768` (p99 498 ms): the 2 GB memory wall, ~2,000 MB peak.
- The on-loop commit OOM-killed 448k and 480k until the slow-disk guard also watched memory (see 1.): at the wall,
  reclaim made a commit take 2 s, the loop stopped draining sockets and socket memory overran 2 GB.
- **The kernel gap to java-iouring-davidhsv (#393) is closed**: on tmpfs at 160k our kernel time is 8.46 µs/req
  vs his 8.76; total µs/req in 4 interleaved no-perf pairs 13.0/13.4, 17.5/19.2, 22.4/24.6 (machine load 14 in
  those two), 13.6/12.4: ours lower in 3 of 4. The old
  ~2 µs gap was mostly the page-cache resets (preads), not TCP (table below).
- Build: clean build (deps downloaded again, Kotlin/Native toolchain already in ~/.konan) on one core in a
  1.5 GB no-swap scope: 178 s, cgroup peak 584 MB, max anon 548 MB. Training: 200k requests in 7.7-9.5 s,
  0 unexpected answers in every build.

## Method

`reports/b5-native-final/scripts/bench.sh` = b3's driver (itself from knio-v3 `bench-ns.sh`, the kotlin-native
README method): fresh seed copy; server in `systemd-run --user --scope -p AllowedCPUs=14 -p MemoryMax=2G
-p MemorySwapMax=0`, `ulimit -n 65535`, `taskset -c 14`, inside a fresh user+net namespace (bwrap); kload
(k6-compatible replay of `bench/load.js`) in its **own** scope (`MemoryMax=6G`, CPUs 0-3,8-11) joined with
nsenter. 15 s warm-up at 1k users, 30 s ramp, 60 s hold (or 300 s). µs/req = server utime+stime over the hold /
hold requests. New here: `KNBIN` (run a saved binary, so variants alternate without rebuilding), `DBDIR` (database
on tmpfs, used only for the #393 comparison and the profiles), `COMM`, `PERFARGS`. `ab.sh` alternates variants
round by round. `ksym.py` symbolizes kernel samples although `/proc/kallsyms` is hidden (`kptr_restrict=1`, no
root): System.map from the `linux-modules-7.0.0-43-generic` .deb (`apt-get download`, nothing installed), the KASLR
slide from the outermost kernel frame of the callchains (`entry_SYSCALL_64`), then self time per symbol and
kernel time in buckets by call chain. All rows: `/mnt/nebula/excal/dev0/tdsc-fleet/b5-native-work/results.tsv`
(copy in `reports/b5-native-final/results.tsv`), raw runs in `b5-native-work/runs/`. Binaries: `bin/base` (b3,
6a0b38b), `ol`/`plain` (on-loop commit, no PGO), `pgo`, `pgo3`, `f1` (first final), `f2` (final, = HEAD), `n7`
(the old c5263b5 build b2 compared), all in `b5-native-work/bin/`.

Noise: the desktop's load went from 1 to 16 during the session (another user process, `hermes`, ran on cores 14
and 6 for a while; I paused measuring until load fell below 5). Same-config runs spread ±5-10 %, so every A/B is
interleaved, ≥ 3 rounds at 160k, and small effects are judged by user time or the thread they touch.

## 1. Commit on the reader's own connection (b2's finding), slow-disk guard

**What**: `db_wq_start` commits the staged batch on the loop on the reader connection (`rd_end`, `BEGIN IMMEDIATE`
with busy timeout 0, the INSERTs, `COMMIT`) and returns 2, and `Server.kt` answers the batch at once (no eventfd
round trip). If a checkpoint RESTART holds the write lock, the batch stays staged and `db_pass_end` retries every
pass (returns 1 when done). Statements are prepared on both connections (`wstmts`), so the committer thread is a
knob (`KN_COMMITTER=1`) and the fallback.

**Slow-disk guard** (the risk b2 and the old README describe: on-loop commits of ~2 s in `pwrite` on a busy disk
failed a 352k hold): an on-loop commit over 50 ms, a checkpoint pass over 200 ms, or memory use at 90 % of the cgroup
limit (else of RAM, from `/proc/meminfo`), checked every 50 ms on the checkpointer thread, sends the next commits to
the committer thread (own connection; the loop keeps serving reads) for 10 s, extended while commits or checkpoints
stay slow, doubled when slowness persists late in a period (max 5 min). So a slow spell costs at most one loop stall
(the commit that detects it). Test (`KN_TEST_WAL_DELAY_US=200000`, a sleep in every WAL write): 1 commit on the loop
(407 ms, the only `GET /feed` over 50 ms in 20,649), then 66 on the thread over ~22 s with every feed < 50 ms.
I did not build a bounded hold *inside* the write (a write in progress can't be preempted, and the commit must be
in the kernel before the 201). On this rig the time triggers fired once in ~40 runs below 416k (68 ms, IO PSI ~50 %).

The memory trigger came from the final rows: the first final build (time triggers only) passed the 416k hold, but
448k and 480k were **OOM-killed** 60 s in, each right after one on-loop commit of 2,071 / 2,033 ms (cgroup at
1.8-1.9 GB: reclaim stalls the write, the loop stops reading sockets, kernel socket memory grows past the limit).
Same day, same rig: b3's binary and this build with `KN_COMMITTER=1` both passed 448k (cgroup peak 1,823 / 1,847 MB).
With the memory trigger: 448k PASS (p99 22 ms; 3,662 commits on the loop, 279 on the thread, 49 trigger ticks),
the 416k hold never triggered it (peak 88.7 %) and kept every commit on the loop (14,980). The process RSS is
~15-25 MB higher than b3's at 448k+ (117 vs 89-103 MB); a 32 MiB reader cache did not change it, so it is not
the now-warm page cache; not investigated further.

| 160k, disk, 60 s | rounds | µs/req | committer thread | kept |
|---|---|---|---|---|
| b3 (committer thread) | 3 | 15.2, 14.8, 14.8 | 0.70-0.72 | |
| commit on the reader, on the loop | 3 | **14.9, 14.1, 14.0** | 0 | **yes** |
| + reader cache 256 MiB (b2) | 3 | 14.7, 14.3, 14.4 (vs 64 MiB 14.1, 14.4, 13.8 same rounds) | | no (`KN_CACHE_KB`) |
| + window 10 ms (b2) vs 20 ms (PGO build) | 3 | w10 14.3, 13.5, 15.1 vs w20 14.0, 14.0, 13.4; p99 10.3 vs 20.4 ms | | no (`KN_WINDOW_US`) |

Reasoning:
- Why so much less than b2's −1.2-1.6 µs: b3 had already cut commits to one per 20 ms, and with 64 MiB the reader
  rarely missed after a reset on this workload's hot set; the gain is the thread's 0.7 µs/req and the preads.
- 256 MiB: rule 5 says "SQLite's own page cache and mmap are fine", so the size is allowed (it is the pager's cache,
  every request still reads through the B-tree). But it bought nothing measurable here at 160k and costs up to
  ~270 MB at the memory wall (the local limit at 448k+), so 64 MiB stays the default.
- 10 ms window: halves write p95/p99 (8.4 → 4.5, 20 → 10 ms) for ~+0.5 µs/req (more, smaller commits). Both are far
  inside the 500 ms / 1 s limits and CPU is what scores, so 20 ms stays; 10 ms is one env var away.

## 2. Build-time C PGO (b4's approach, K/N toolchain)

**What** (`build.sh`, `train/`): the Kotlin/Native clang 21 bundle ships `llvm-profdata` and
`libclang_rt.profile.a`, so no extra packages: `build_c gen` (`-fprofile-generate`), link the server with the
profile runtime (`-linker-options "-u__llvm_profile_runtime …profile.a"`), `train/mkdb.c` (b4's synthetic DB, our
code) makes a scratch DB, the instrumented server serves it to `train/train.c` (new: a C port of b4's `Train.kt`,
pthreads, own SHA-256/HMAC to sign tokens with the run's random secret), SIGTERM makes the instrumented server write
its profile (`uring.c`: a weak `__llvm_profile_write_file`; in the real build it is NULL and SIGTERM keeps its
default), `llvm-profdata merge`, `build_c use`, link again (cinterop + kotlinc-native run twice: +~45 s).

**Rules**: LEADERBOARD "Rule flags from code review", Arjay's ruling (2026-11-15, rule 10): *"profile-guided
optimization is fine when `build.sh` records the profile on the box during the build (a training run on a scratch
database); a committed profile recorded somewhere else is not."* Profile only in `build/pgo` (gitignored), scratch DB
in `build/train` (deleted), loopback port 3999 (`KN_TRAIN_PORT`) during the build only, nothing outside the entry's
files. Time limits: mkdb `timeout 300`, server `timeout -s KILL 1200`, client `timeout 600` (+ it gives up after
1,000 failed connects), health wait 60 s, SIGTERM then SIGKILL after 30 s; any failure → `!! PGO training failed`
and the plain build. Tested with `KN_TRAIN_TIMEOUT=1` (falls back, rc 0). A first version chained `build_c gen &&
link_kn`, so a compile error in my own code went on to a failed training and a failing fallback instead of stopping
at once; now a compile error stops the build (set -e).

| Measure | plain (-O2) | PGO (-O2, default) | PGO + `-O3 -march=native` |
|---|---|---|---|
| `KN_VERIFY` feed plan, µs/call (5 pairs) | 6.13-6.21 | **4.91-5.11** (one 6.21) | 4.93-5.01 |
| post plan, µs/call | 2.47-2.80 | 2.36-2.63 | 2.55-2.72 |
| 160k load, µs/req (user) | 13.2 (5.0), 13.1 (5.0) | **12.6 (4.3), 13.1 (4.5)** | 12.9 (4.5), 13.1 (4.7) |

Kept: PGO at -O2 (user CPU −0.5-0.7 µs/req, the total gain is inside the sys-time noise; `KN_CPGO=0` = plain).
-O3/-march=native: no gain over PGO alone, so not the default (`KN_CFLAGS`). Build fits easily (above).

## 3. davidhsv's pass structure vs b3's batch wake; where the kernel time goes

**What** (`KN_PASS=sweep`, `uring.c` `poll_sweep`): every ring `DEFER_TASKRUN`; per pass, sweep rings 1..n first
(submit + `GETEVENTS` without waiting; skipped when nothing is queued and the kernel flags no task work; a second
enter asking for 4,096 completions with a zero timeout if `IORING_SQ_TASKRUN` is still set, because newer kernels
run only a small batch per non-waiting enter), then wait on ring 0 for 256 CQEs or 1 ms after every non-empty pass
(`KN_PACE_ALWAYS`), then collect every ring. Idle with >1 ring: the ring-0 sleep is capped at 1 ms so deferred rings
are still swept. `test-rings.sh` passes with it.

| | rounds | batch wake (default) | sweep | |
|---|---|---|---|---|
| 160k, disk | 3 | 13.2, 13.3, 12.5 | 13.0, 11.9, 12.2 (p95 9.7 vs 8.4 ms) | −0.6 µs/req |
| 256k, disk | 2 | 14.0, 16.0 (p95 8.5 ms) | 15.4, 17.7 (p95 13.6, **69 ms**; p99 220 ms) | +1.5 µs/req |

The same shape b3 saw with DEFER: fine at 160k, worse at 256k (4 rings). At 256k ring 0 holds a quarter of the
connections, so the 256-CQE wait always runs into the 1 ms timeout and every pass pays it; the reads of the other
rings wait a pass longer. Kept as a knob; batch wake stays the default. Profiles say DEFER's real saving is small
(task work 0.58 → 0.35 µs/req).

**Kernel time per request, 160k, tmpfs DB, perf 999 Hz with call graphs, 20 s of the hold** (µs/req = bucket share
× that run's µs/req; perf adds ~5 %; buckets by the first matching frame in the chain, loopback delivery first):

| bucket | n7 (≈ f047368, what b1/b2 compared) | b3 | **b5 batch (default)** | b5 sweep | #393 |
|---|---|---|---|---|---|
| softirq / net rx (loopback delivery to both sockets) | 3.28 | 3.30 | 3.19 | 3.41 | 3.47 |
| TCP send | 2.59 | 2.44 | 2.40 | 2.43 | 2.66 |
| TCP recv | 1.27 | 1.06 | 1.24 | 1.17 | 1.30 |
| **file read/write (SQLite `pread`/`pwrite`)** | **1.38** | 0.58 | 0.26 | 0.22 | 0.22 |
| other kernel (syscall entry/exit, audit, ring switch) | 0.91 | 0.48 | 0.35 | 0.26 | 0.27 |
| io_uring task work / CQE posting | 0.76 | 0.68 | 0.58 | 0.35 | 0.34 |
| io_uring submit (issue) | 0.50 | 0.44 | 0.43 | 0.51 | 0.46 |
| futex / sched (committer thread wakeups) | 0.16 | 0.05 | 0.01 | 0.00 | 0.04 |
| **kernel total** | **10.85** | 9.03 | **8.46** | 8.35 | **8.76** |
| user total | 6.65 | 5.47 | 4.44 | 4.65 | 5.64 |
| run µs/req | 17.5 | 14.5 | 12.9 | 13.0 | 14.4 |

Where the ~2.1 µs went (n7 → #393): 1.16 µs file I/O (preads after each foreign COMMIT reset the reader's page
cache, plus 2 pwrites per frame before b3's WAL VFS), 0.64 µs "other" (more syscalls: one enter per completion
before b3's batch wake, `pread`'s own entry/exit with audit on this desktop, eventfd/futex of the committer), 0.42 µs
task work (COOP vs DEFER), 0.12 µs futex. TCP itself (send + recv + loopback delivery) is the same in every build
(7.1-7.4 µs) and is ~85 % of what remains. b3 removed ~1.8 µs of it, this round another 0.6; what is left is
the TCP stack. Top kernel self symbols are the same in both entries (`__inet_lookup_established`, AppArmor's
`aa_inet_msg_perm`/`aa_dfa_match_len` per send/recv, `io_issue_sqe`, `rep_movs_alternative` copies). A small item:
`__io_uring_add_tctx_node_from_submit` → `xa_load` (0.44 %) runs on every enter that switches rings.

Clean (no perf) tmpfs pairs at 160k, b5 vs #393: 13.0 / 13.4, 17.5 / 19.2, 22.4 / 24.6 (load 14 during these
two), 13.6 / 12.4. #393's latency is lower (p95 4 vs 8 ms) because his writes wait 5 ms, ours 20 ms.

## Final numbers (defaults, disk DB, 60 s unless noted)

| Users | Run | Result | µs/req (user) | CPU | p95 / p99 | RSS | cgroup peak |
|---|---|---|---|---|---|---|---|
| 160k | 60 s | PASS, integrity ok | 13.4 (4.8); A/B rounds 12.5-13.3 | 23 % | 8.3 / 20.4 ms | 73 MB | 703 MB |
| 256k | 60 s | PASS, integrity ok | 12.2 (4.3) | 33 % | 8.6 / 19.6 ms | 85 MB | 1,083 MB |
| **416k** | **5-min hold** | **PASS, 0 errors**, integrity ok | 12.9 (4.7) | 57 % | 10.8 / 21.9 ms (reads p99 7 ms, writes 27-28 ms) | 133 MB | 1,816 MB |
| **448k** | 60 s | **PASS**, integrity ok | 12.1 (4.3) | 58 % | 10.9 / 22.1 ms | 117 MB | 1,851 MB |
| 480k | 60 s | PASS (p99 946 ms), then FAIL (p99 1,106 ms) | 12.4-12.9 | 63-65 % | 39 / 946, 22 / 1,106 ms | 117-118 MB | 1,997-2,002 MB |
| 480k | 60 s, `KN_CACHE_KB=32768` | PASS | 12.9 | 66 % | 54 / 498 ms | 120 MB | 1,995 MB |

First final build (no memory trigger, otherwise identical): 160k 12.8, 256k 12.0, 416k 5-min hold PASS 12.3 µs/req
p99 21.1 ms; 448k and 480k OOM-killed (above).

## Deviations

- Root disk had room this time; runs, DB copies and TMPDIR still live on `/mnt/nebula/.../b5-native-work` (the
  seed is a gitignored symlink to the main checkout's).
- Server core 14 was shared for a while with another user's `hermes` process (75 % on 14, 60 % on 6); I could not
  stop it (not mine) and paused measuring until load < 5. The three "shm" pairs taken during that spell are marked.
- One bench run broke because I edited `bench.sh` while bash was executing it (the plain run of round 1 of the PGO
  A/B); the other rounds ran.
- My first slow-disk test left its server running for ~40 min (a `pkill -f` pattern matched my own shell, so the
  `kill` never ran); it was idle on port 18142 (my block) and is killed by PID now. It ran during the first A/Bs,
  idle (no traffic), on core 14.
- The first final chain ran only the 416k hold: `$v` in my `bash -c "…"` loop was expanded by the outer shell
  (empty). Re-run from a script file.
- #393 is b2's build (`b2-work/dav`, JDK 27.0.1, his build.sh with PGO), not rebuilt; same as b2's comparison.
- `perf` without kernel symbols: System.map from the .deb, slide computed (see Method); all kernel names in the
  table come from that mapping.

## Follow-ups

1. Real-VM check (vhp-1c-2gb-intel, 6.8): the on-loop commit on a real VM disk (does the guard fire?), PGO build
   time on a real vCPU, and whether sweep/DEFER behave differently on 6.8 (b3's open item).
2. Sweep with a ring-0 wait scaled to the ring count (wait for 256 / nrings) might keep the 160k gain without the
   256k loss; not tried.
3. The remaining kernel time is TCP (~7 µs/req locally, AppArmor socket hooks ~0.5 µs of it; the box may not run
   AppArmor on sockets the same way). Nothing more to take on the io_uring side locally (0.9 µs/req total).
4. A newest-first / bounded pass for the 448k+ tail (memory, not CPU, is the local limit).
5. Why RSS is ~15-25 MB higher than b3's at 448k+ (not the reader cache: 32 MiB changed nothing).

## Open questions for the owner

1. On-loop commit (default) + guard vs committer thread (`KN_COMMITTER=1`): the guard bounds a slow spell to one
   stall, but that one stall can be as long as the disk makes it. OK as the scored default?
2. PGO is on by default (+~50 s build, a training run on 127.0.0.1:3999). The fallback is a plain build. Keep?
3. 20 ms vs 10 ms window: 10 ms halves write latency for ~+0.5 µs/req (measured within noise). Your call.
4. The memory trigger (90 %) is tuned on this rig's cgroup, where `memory.current` includes the DB's page cache. On
   the box (no cgroup limit, so `MemAvailable`) it should only fire near the wall, where CPU, not memory, binds first
   (~128-144k on the VM). Fine to leave on, or would you rather have `KN_COMMITTER=1` as the plain safe default?
