# bench-final: head-to-head of every build (LOCAL, 2026-11-23)

**Submit `kn-final` (branch `b5-native-final`, `submissions/kotlin-native-3x3xX3N0N`).** Among our builds it is the
cheapest per request in every interleaved comparison: 13.1 µs/req at 160k users and 11.8 at 384k. That is 8-11 %
below kn-b3, 15 % below jvm-uring, 17-26 % below graal-ce and 3.4× cheaper than our open PR #377 (nio-v3). It
passes 42/42 and held 384k users for 5 minutes with 0 errors. Its highest 60 s pass is 480k users (1 of 2 runs),
where it hits the same 2 GB memory wall as kn-b3. On tmpfs it is level with the reference java-iouring-davidhsv
(#393): 12.2 vs 12.9 µs/req at 160k, 11.7 vs 11.2 at 384k, one run each, inside the rig noise.

Why CPU per request decides it: on the scored-box-like VM (2026-11-10, `knative-vm-report.md`), the K/N entry ran
out of **CPU** at ~128k users (36-37 µs/req, ×2.7 local). It did not run out of memory. So the build that needs the
fewest µs per request scales furthest on the real box. The 448k-512k memory edge seen here is a desktop-only limit.

## Ranked table

All rows: server on core 14 (sibling 6 not used by us), 2 GB / no-swap scope, `ulimit -n 65535`, private network
namespace, kload on cores 0-3,8-11, DB on the shared disk. µs/req = server-scope CPU (cgroup `cpu.stat`, all
threads and processes) over the 60 s hold divided by the requests in the hold. Main matrix = 3 interleaved rounds
(A B C … A B C …) per load level; p95/p99 and µs/req are medians over the 3 rounds. RSS = the largest sampled sum of
the server processes' VmRSS (every 5 s); "cg" = the scope's `memory.peak` (incl. kernel socket memory and page cache).

| # | Build | 42/42 | µs/req 160k: med (min-max) | µs/req 384k: med (min-max) | p95 / p99 ms 160k | p95 / p99 ms 384k | RSS peak (cg peak) at 384k | Highest 60 s pass | 5-min hold 384k |
|---|---|---|---|---|---|---|---|---|---|
| 1 | **kn-final** (b5-native-final 3419365) | 42/42 | **13.06** (12.53-14.29) | **11.84** (11.67-12.34) | 8.5 / 20.4 | 8.9 / 20.4 | 106 MB (1,591 MB) | **480k** (1 of 2; 2nd p99 1,044 ms). 448k pass (p99 635 ms). 512k OOM ×2 | PASS ×2: 11.91 µs, p95/p99 9.2 / 20.4 ms, RSS 131 MB, cg 1,682 MB; 1st run (box load 5-6.6) 13.85 µs, 38 / 161 ms |
| 2 | kn-b3 (b3-native 6a0b38b) | 42/42 | 14.66 (14.41-15.18) | 12.80 (12.50-13.67) | 8.8 / 20.1 | 9.4 / 20.9 | 83 MB (1,571 MB) | **480k** (2 of 2, p99 709 / 725 ms: just under the 1 s limit). 512k OOM ×2 | PASS ×2: 13.16 / 12.77 µs, 9.8 / 20.9 and 9.7 / 20.6 ms, RSS 82 MB, cg 1,635 MB |
| 3 | jvm-uring (b2-jvm 9640ede) | 42/42 | 15.32 (14.77-16.13) | 13.91 (12.17-13.97) | 4.3 / 10.2 | 5.9 / 10.9 | 188 MB (1,654 MB) | **384k**. 416k: OOM-killed ×2 at the 2 GB wall during the ramp | PASS: 14.04 µs, 6.2 / 11.2 ms, RSS 251 MB, cg 1,785 MB |
| 4 | graal-ce (b4-graal-pgo 6e470e5, CE + C PGO) | 42/42 | 17.71 (16.70-18.85) | 14.23 (13.64-14.69) | 1.5 / 2.5 | 1.3 / 2.9 | 75 MB (1,562 MB) | ≥ 384k (not stepped) | not run (not top 3) |
| 5 | graal-ce `KG_CPGO=0` | 42/42 | 18.66 (16.95-19.48) | 15.02 (14.16-15.46) | 1.5 / 2.4 | 1.8 / 3.8 | 76 MB (1,559 MB) | ≥ 384k (not stepped) | not run |
| ref | java-iouring-davidhsv #393 (origin/main 56ee469a) | 42/42 | 12.68 (12.09-13.35), **FAIL ×3** | 13.29 (11.95-13.44), **FAIL ×3** | 1,483 / 1,909 | 1,188 / 1,827 | 417 MB (2,106 MB) | none on the shared disk. On tmpfs: 160k PASS 12.91 µs, 3.9 / 7.4 ms; 384k PASS 11.22 µs, 5.7 / 8.8 ms | not run |
| 7 | nio-v3 (kotlin-nio-v3 640beef = PR #377) | 42/42 | 45.13 (42.41-45.45) | 36.72 (36.49-38.73), **FAIL ×3** (8.8 % errors) | 7.5 / 48.9 | 1,892 / 3,555 | 536 MB, 3 JVMs (1,977 MB) | 160k (384k fails: 3 workers × 65,535 fds = 196k connections max) | not run |

Ranking: highest pass first, then µs/req. #393 is the reference, not one of our candidates. On this disk it fails
every run, so by the rules it would rank below everything that passes. On tmpfs it is as cheap as kn-final.

### Side comparison: DB on tmpfs (one run each, same interleaving, 22:40-22:53)

| Build | 160k µs/req | 160k p95 / p99 | 384k µs/req | 384k p95 / p99 | cg peak 384k |
|---|---|---|---|---|---|
| kn-final | 12.19 | 7.3 / 19.1 | 11.65 | 8.4 / 19.6 | 1,573 MB |
| #393 | 12.91 | 3.9 / 7.4 | 11.22 | 5.7 / 8.8 | 1,736 MB |
| jvm-uring | 13.81 | 4.0 / 10.0 | 12.51 | 4.6 / 10.4 | 1,634 MB |

#393 commits on its loop with no fallback. On the shared disk (IO PSI 0-50 % from other jobs) every endpoint,
reads included, sat at p95 1.2-1.6 s. That is loop stalls behind slow WAL writes and fsyncs, the same failure b2-jvm
saw. kn-final also commits on the loop, but its slow-disk guard and the 20 ms window kept it passing. The guard
never fired in any run here: no commit took more than 50 ms.

## Reading the numbers

- **kn-final vs kn-b3** (on-loop commit on the reader connection + C PGO, b5): −11 % at 160k and −7.5 % at 384k
  (medians); the min-max ranges at 160k do not overlap. kn-b3 is the slightly safer build at the 480k memory wall
  (2 of 2 vs 1 of 2; both runs near p99 1 s). On the real box that region is never reached.
- **K/N vs JVM (HotSpot + FFM, same C shim)**: the JVM port costs ~2 µs/req more and ~80-120 MB more RSS. The RSS
  is what ends it at 416k. Its p99 is lower (10 ms vs 20 ms) because its commit window is 10 ms instead of 20 ms.
  That latency is far under the 1 s threshold, so it buys nothing in the score.
- **Graal native-image**: 2-5 µs/req more than K/N on the same shim. C PGO is worth ~0.8-1 µs/req (5 %). Its p99 is
  the lowest of all (2-4 ms); again that does not score.
- **nio-v3 (#377, what is submitted today)**: 3.4× the CPU of kn-final, and capped at 196k connections by 3 ×
  `RLIMIT_NOFILE`.
- 384k costs fewer µs/req than 160k for every io_uring build: more completions per loop pass.

## Method

- Builds: every build was made from a fresh worktree under `/mnt/nebula/excal/dev0/tdsc-fleet/bench-wt/<name>`. The
  worktrees are detached at the branch heads above. graal-ce and graal-nocpgo are two worktrees of the same commit.
  #393 is a `git archive` copy of `origin/main:submissions/java-iouring-davidhsv` from the read-only upstream
  clone (that clone has no `origin/pr/393` ref; #393 is merged as 56ee469a). Each build ran its own `build.sh`
  (nice 10, core 14, 3 GB scope; script `bench-final/scripts/build.sh`). Toolchains were the copies already on disk:
  - K/N 2.4.21 in `~/.local/opt`;
  - system JDK 25.0.5.1 for jvm-uring and nio-v3 (Gradle);
  - GraalVM CE 25.0.5.0.3 and kotlinc 2.4.21 from `b1-graal-work`;
  - JDK 27.0.1 from `b2-work/opt/jdk-27` for #393.
  #393 was built with its PGO training inside `bwrap --unshare-net`, because the training binds an ephemeral port.
  The kn-final and graal-ce training runs used ports 18151 and 18152.
- Build wall time and cgroup peak (deps downloaded again, shared machine):
  - kn-final: 1:55, 585 MB
  - kn-b3: 0:48, 559 MB
  - jvm-uring: 0:52, 633 MB
  - graal-ce: 4:40, 1,248 MB
  - graal-nocpgo: 3:48, 1,079 MB
  - nio-v3: 0:47, 1,350 MB
  - #393: 1:08, 342 MB
- Tests: `test/run.sh <dir>` for each build (it rebuilds in place), PORT 18153, core 14: **42/42 for all seven**
  (`bench-final/tests.txt`).
- Load: `bench-final/scripts/bench.sh`, derived from `reports/b5-native-final/scripts/bench.sh` (the README
  "Measured" method). Each run: fresh seed copy, 1,000-VU 15 s warm-up (not scored), 30 s ramp, 60 s hold (300 s for
  the holds), kload with `--json`; PASS = load.js thresholds (p95 < 500 ms, p99 < 1 s, failures < 1 %). The scope's
  `cpu.stat` replaces per-PID ticks so that nio-v3's 3 JVMs and every thread count.
- Order (`runs.log`):
  - main matrix: `rr.sh 3 160000 384000 -- kn-final kn-b3 jvm-uring graal-ce graal-nocpgo nio-v3 dav`;
  - nio-v3 round-1 makeup;
  - step search: `step.sh 416000 32000 kn-final jvm-uring kn-b3`, where a fail is retried once and drops the build
    only if the retry also fails;
  - 5-min holds at 384k;
  - tmpfs side runs;
  - a second hold pair (kn-b3, kn-final) and a 480k confirmation pair.
- Machine state: load average 1.0-6.6 at run starts and ends. IO PSI avg10 0-50 % (other agents' disk jobs). The
  owner's desktop apps (Spotify, Discord) were seen on core 6, the HT sibling of the server core, at 14-21 % CPU.
  Conntrack was not involved (private netns).

## Deviations

- Two driver bugs cost nio-v3 its round-1 slots. Under `set -e`/pipefail, the process lookup failed for multi-process
  servers (one `true` was missing, and `head -1` took a SIGPIPE). I fixed the driver and re-ran the two round-1 nio-v3
  runs after round 3, so nio-v3 still has 3 runs per level, but those two are out of order.
- kn-final's 160k median excludes the smoke run at 20:22 (12.36 µs/req, PASS) that validated the driver. Including
  it, the median is 12.79.
- I ran **two** 5-min holds for kn-final and kn-b3, not one. kn-final's first hold (box load rising to 6.6) passed
  with p99 161 ms. Reads and writes were slow alike and the guard never fired, so I repeated the pair at load ~2:
  p99 20 ms. jvm-uring has one hold.
- I added an extra 480k pair (kn-b3, kn-final) to check how reliable the highest pass is.
- The step search covers only the top 3 by the matrix (kn-final, kn-b3, jvm-uring). graal-ce is 4th on µs/req at
  both levels.
- Builds ran in a 3 GB scope, not the 1.5 GB box cap; the peaks above are all under 1.5 GB.
- The main table uses the shared disk (the README method); the tmpfs table is extra.

## Follow-ups

1. Re-run kn-final on the 6.8 Vultr VM (`vultr-vm-bench-rig`) before opening the PR. The local µs/req ranking is
   what matters there, but the last real-VM number (128k) predates b3 and b5.
2. If the 480k wall matters: kn-b3's lower RSS (82 vs 106-131 MB) is the only edge it has. The difference is kn-final's
   on-loop commit staging and PGO layout. Not worth trading 1 µs/req for.
3. #393 on the scored box scored 240k at 29 µs/req. Our kn-final is level with it locally on tmpfs, so a VM pair
   (kn-final vs #393 on the same VM) would show whether we can beat it officially.

## Open questions for the owner

- Replace PR #377 (nio-v3) with kn-final, or open kn-final as a new entry? The numbers say nio-v3 is not competitive
  (3.4× the CPU, 196k connection cap).
- The on-loop commit is the right default on the box (dedicated disk), but on a noisy disk it shows up as p99
  (161 ms in one hold here). Keep the guard thresholds (50 ms / 200 ms / 90 % memory) as they are?

Files: `reports/bench-final/` (scripts, `results.tsv` = every run, `runs.log`, `tests.txt`); run directories with
kload JSON, server logs and memory samples in `/mnt/nebula/excal/dev0/tdsc-fleet/bench-final-work/runs/`.
