# b3-native: improving submissions/kotlin-native-3x3xX3N0N in place

Branch `b3-native` (off `kotlin-native` f047368). Server core 14 (HT sibling 6 idle), ports 18120-18129.
All numbers are LOCAL (i7-10700K desktop shared with two other build agents, a profiler, a VM and desktop apps;
run-to-run noise about ±10 %), so they rank designs, they are not a score.

## Result

- `test/run.sh submissions/kotlin-native-3x3xX3N0N`: **`passed=42 failed=0`** (final build). Also `test-restart.sh`
  PASS and `test-rings.sh` PASS (8 rings spill, every connection answered), `PRAGMA integrity_check` ok after every
  measured run.
- **160k users: 14.7-16.8 µs/req (baseline 18.1-19.2), 256k: 14.4 (baseline 17.8), about −18 %.**
- **416k users, 5-minute hold: PASS, p99 23.4 ms** (README before: p99 733 ms). Highest 60 s pass: **480k** (p99
  142 ms, cgroup peak 1,984 MB); a 5-minute hold at 448k fails on p99 at the 2 GB memory wall.
- Cold build (toolchain download included) peaks at ~560 MB anonymous memory inside a 1.5 GB no-swap cgroup.

## Method

`reports/b3-native/scripts/bench.sh <label> <users> [hold] [ramp]` (derived from the knio-v3 `bench-ns.sh` behind the
README numbers): fresh seed copy; server in `systemd-run --user --scope -p AllowedCPUs=14 -p MemoryMax=2G
-p MemorySwapMax=0`, `ulimit -n 65535`, `taskset -c 14`, inside a fresh user+net namespace (bwrap: own loopback, no
host conntrack at 262k, no TIME_WAIT carry-over); kload (k6-compatible replay of `bench/load.js`, branch bench-kload
build in ~/code/kload) in its **own** scope (`MemoryMax=6G`, CPUs 0-3,8-11), joined with `nsenter`. 15 s warm-up at
1k users, then 30 s ramp + 60 s hold (or 300 s). CPU = server process utime+stime over the hold / hold requests.
The script also reports write syscalls per request (`/proc/PID/io` syscw), CPU per thread (threads are named
`kn-commit`, `kn-ckpt`), cgroup peak, and optional `perf record` (PERF=1) and integrity check (INTEGRITY=1).
Raw results: `/mnt/nebula/excal/dev0/tdsc-fleet/b3-native-work/results.tsv` (+ `runs/*/kload.txt`, `server.log`).

Small effects (< 1 µs/req) are below the noise, so they were judged by perf share or by the CPU of the one thread
they touch, in interleaved pairs.

## Baseline reproduced (f047368)

| Users | Result | µs/req | p95 / p99 | README |
|---|---|---|---|---|
| 160k | PASS | 18.1, 19.0, 19.2 | 1.2-2.0 / 2.3-3.6 ms | 19.4 (host loopback; netns is ~1 µs cheaper) |
| 256k | PASS | 17.8 | 1.3 / 2.5 ms | 15.3 (the desktop is busier today) |

Profile at 160k (perf): kernel ~63 %, binary ~33 % (sqlite3BtreeTableMoveto 5.6 %, put_str 2.5 %, pcache1Fetch
1.7 %, ...), Kotlin ~5 % (Server.process 2.0 %, run 1.6 %, HMAC compress 0.6 %). So Kotlin-side parsing tricks can
only win ~2-3 %; the kernel and syscall side and the write path were the places to look.

## Tricks, before/after (160k unless noted)

| Trick | Status | Before → after | Kept? |
|---|---|---|---|
| Batch wake: wait on ring 0 for 256 CQEs or 1 ms after a light pass; secondary rings collected after the wait | new loop structure in `ur_poll` | passes 8.2k → 1.9k/s; **15.7 → 14.7, 16.7 → 14.8 µs/req** (2 pairs); reads p95 0.3 → 2.2 ms | **yes** (default) |
| ... with DEFER_TASKRUN on the rings | tried 3 ways | v1 (DEFER on all rings, old ur_poll): −13 % once, but **broke idle servers** (ring 1+ accepts never served: test-rings 0/2,510); v2 (cap sleep at 1 ms): no gain (secondary CQEs cut every wait short, 8.1k → 5.2k passes); v3 (wait on ring 0 alone + drain loop): −7-11 % at 160k but **at 256k reads p95 0.5 → 40 ms, 14.5 → 16.5 µs/req**; each half alone was fine | no (`KN_DEFER=1` knob) |
| jnorthrup header struct: one pass, first char + colon at fixed offset, only Content-Length/Authorization/Connection/Transfer-Encoding decoded | `request1` in Server.kt | `Server.process` 1.51 % → 0.66 % of CPU (~0.15 µs/req); same answers on 9 edge cases (case, tabs, HTTP/1.0, pipelining, split body, chunked) | **yes** (`KN_HDR=0` = old) |
| pcache1 with own `xRekey` (split swap parked at key 0) | `SQLITE_CONFIG_PCACHE2` wrapper in db.c | `pcache1TruncateUnsafe` 0.55 % → 0.25 %; ~2.8k parks per run; integrity ok | **yes** (`KN_PCACHE=0`) |
| One pwrite per WAL commit (VFS shim over the base VFS) | `knwal` VFS in db.c | write syscalls/req **0.50 → 0.145**; committer thread 1.90 → 1.68 and 1.53 → 1.38 µs/req (2 pairs); integrity ok | **yes** (`KN_WALVFS=0`) |
| Group-commit window 20 ms / 1,024 (was 2 ms / 64) | default changed | committer thread **1.38 → 0.76, 1.71 → 0.82 µs/req**, total −1.4/−1.7 µs/req (2 pairs); p95 2.3 → 8.4 ms (limit 500 ms); 10 ms and 40 ms no better | **yes** |
| Bounded passes (`KN_MAX_EV`), 320k users at a 50 % CPU quota | knob | 4096: FAIL (p95 2.8 s) then PASS (p99 196 ms); 1024: PASS p99 774; 512: PASS p99 440 / 518; 256: PASS p99 635 → at the edge the outcome is luck, no reliable effect | knob only, default 4096 |
| Newest-first under backlog | not done | (the bounded-pass result gave no signal to build on) | follow-up |
| 8 SO_REUSEPORT listeners (256k, 15 s ramp) | `KN_LISTENERS` | CPU 14.1/15.9 vs 14.5/14.0 (same); connect p99 0.83/0.71 → 0.49/0.47 ms; 0 failures either way | knob, default 1 (see open questions) |
| mlock of the binary | `mlock_self` in uring.c | 2,224 KB locked; no measurable change locally (code is never reclaimed below the wall here) | **yes** (cheap insurance at the memory wall, `KN_MLOCK=0`) |
| SWAR 8-byte JSON escape; one C call per feed row | **already in the baseline** (`put_str` SWAR; the whole feed is one C call, `bt_feed`) | — | — |
| Precomputed HMAC ipad/opad | **already in the baseline** (`Jwt.kt` inner/outer states) | — | — |
| Build memory | `build.sh` JAVA_OPTS -Xmx1200m → -Xmx800m | cold build: 558 MB max anon in a 1.5 GB cgroup (cgroup "peak" hits 1.5 GB only from reclaimable page cache while unpacking the 1 GB toolchain), no OOM; warm build 559 MB | yes |

## Final numbers (all defaults, 60 s unless noted)

| Users | Result | µs/req | CPU | p95 / p99 | RSS | cgroup peak |
|---|---|---|---|---|---|---|
| 160k | PASS | 16.8 (14.7, 14.8 in the batch-wake pairs) | 28 % | 8.8 / 20.1 ms | 62 MB | 693 MB |
| 256k | PASS | 14.4 | 39 % | 8.8 / 20.1 ms | 70 MB | 1,067 MB |
| 384k | PASS | 13.8 | 56 % | 9.8 / 20.9 ms | 80 MB | 1,568 MB |
| 416k, 5-min hold | PASS, 0 errors | 14.3 | 63 % | 13.2 / 23.4 ms (reads p99 14 ms, writes p99 39 ms) | 88 MB | 1,771 MB |
| 448k | PASS | 14.0 | 66 % | 12.1 / 22.4 ms | 90 MB | 1,824 MB |
| 448k, 5-min hold | FAIL (p99 1.27 s, max 20 s) | 14.9 | 70 % | 104 / 1,270 ms | 96 MB | 2,084 MB (wall) |
| **480k** | **PASS** | 15.1 | 77 % | 26 / 142 ms | 103 MB | 1,984 MB |

Per-thread at 256k: loop 13.05, committer 0.66, checkpointer 0.66 µs/req.

## Bugs found and fixed on the way

- My first batch-wake default (DEFER_TASKRUN on every ring) left an idle server unable to serve connections accepted
  by rings 1+ (a deferred ring posts nothing, so no eventfd, while the loop sleeps on ring 0). Caught by
  `test-rings.sh`, not by the 42 tests or the load runs (traffic kept waking the loop). Fixed; DEFER is off.
- `ur_poll`'s "any ring has CQEs ready, don't wait" check silently disabled pacing as soon as a second ring existed
  (that is probably why the README measured pacing as no better). The wait is now on ring 0 alone.
- README said 4,096 provided buffers per ring; the code has 1,024 since 27cda18. Corrected.

## Deviations

- TMPDIR and all run directories (DB copies, logs) are on `/mnt/nebula/excal/dev0/tdsc-fleet/b3-native-work`, not
  in the worktree: the root disk had 260 MB free (my first 249 MB seed copy into the worktree filled it; I deleted
  it at once and used a symlink `seed/feed.db` → the main checkout's seed, which is gitignored). /mnt/nebula's IO
  pressure (PSI 25-45 %) is in the write latencies.
- All runs in a private network namespace (the README's 160k row used host loopback; netns is ~1 µs/req cheaper).
- kload instead of k6 (needed above ~260k users; same script logic).
- Once I ran `test-rings.sh` with its default port 3099 (outside my block) by mistake; nothing was listening there,
  the run just failed; re-run on 18125.
- The desktop was heavily shared (load 4-8, a 600 % JVM job on the load cores, qemu and kwin sometimes on core 14).

## Follow-ups

- Real-VM check (Vultr vhp-1c-2gb, kernel 6.8): the 6.8 kernel is where batch wake / COOP vs DEFER behaviour,
  the 20 ms window and the WAL VFS should be re-measured; local gains in kernel-side work may differ there (the
  previous VM run cost ×2.7 the local µs/req and was CPU-bound at ~128k).
- Understand why DEFER_TASKRUN + a 256-CQE wait stalls reads at 256k on 7.0 (maybe min-wait semantics or the
  local-work cap); it might be the larger win on 6.8 if it behaves there.
- Newest-first scheduling under backlog for the p99 at the CPU edge (only worth it if the VM run is CPU-bound).
- Remaining Kotlin byte loops (SHA-256 compress 0.7 %, base64, POST JSON parse) could move to C; < 1 % each.
- Memory per connection is the local limit (~4.1 KB kernel socket memory): a 5-minute hold at 448k hits 2 GB.

## Open questions for the owner

1. `KN_LISTENERS=8` (SO_REUSEPORT) is a knob, default 1: no CPU gain locally, connect p99 −0.3 ms, and a restart on
   6.8 could let the dying process's listener share the port for a moment. Default it on for the VM test?
2. The 20 ms group-commit window moves write p95 from ~2 to ~20 ms (well inside 500 ms). OK as the scored default?
3. Custom WAL VFS and PCACHE2 wrapper: both use public APIs as the rulings allow (r6), but they are more surface for
   a reviewer. Keep both on?
