# vm-twin: kn-final vs java-iouring-davidhsv (#393) on a twin of the scored box (2026-11-24)

Twin = Vultr `vhp-1c-2gb-intel` (the $12 plan), Intel Xeon Cascade Lake, 1 vCPU, 1,962 MiB, Ubuntu 24.04.5, stock
kernel **6.8.0-149-generic**. The CPU profile matches the scored Xeon Platinum 8260: eIBRS, Meltdown and MDS "not
affected". Load came from a `vhp-8c-16gb-intel` load VM over a free VPC. Nothing pushed, no PR, no GitHub comments.
Scripts, every run (kload JSON, server journal, 5 s monitor samples) and box logs are in `reports/vm-twin/`.

## Verdict

- **Calibration holds.** The JVM entry kotlin-nio-3x3xX3N0N (`c0f58b9`; officially 115k at 79 µs/req) costs
  **80.6 µs/req at 96k and 75.8 at 112k** here, against 79 official. CPU-bound entries measure like the scorer.
- **kn-final and #393 are level on this twin.** They have the same wall and the same box-wide cost, with #393 a
  little cheaper in process CPU:

  | | kn-final | #393 |
  |---|---|---|
  | Highest 60 s pass (start 96k, step 16k) | **160k**; 176k fails 2/2 | **160k**; 176k fails 2/2 |
  | 5-min hold at 160k (highest pass) | FAIL: 24.9 % errors, box OOM, server killed | FAIL: 1.75 % errors, p99 60 s |
  | 5-min hold at 144k (one step down) | **PASS**: 0 errors, p95/p99 24.7 / 57.1 ms | **PASS**: 0 errors, p95/p99 20.6 / 36.1 ms |
  | µs/req at the 144k hold: process (user), box | **25.0** (10.9), 31.8 | **24.4** (10.7), 32.2 |
  | µs/req median over the 96-160k steps: process, box | 23.9, 29.9 | 20.8, 28.9 |
  | RSS peak at the 144k hold | **101 MB** | 209 MB |
  | `test/run.sh` on the twin | 42/42 | 42/42 |

- **The twin is far harsher than the scorer at the top.** #393 scored **240k** officially and fails 176k here, the
  same as kn-final. So 160k / 144k is a **lower bound** for both, not a projection. The twin cannot rank the two
  above ~160k. Below that, they cost the same per request box-wide, and #393 is 0-15 % cheaper in process CPU.
  kn-final's local lead (13.1 vs 12.7-12.9 µs/req, tmpfs) is not visible here.
- **Honest expectation for kn-final's official score: about #393's neighbourhood (~220-240k), not above it**, if the
  scorer's ramp treats it like #393. I did not measure this (assumption). kn-final's p99 runs higher than #393's
  at the same load on the twin (57 vs 36 ms at the 144k hold; 169 vs 62 ms in the 160k step). #393 passed its
  official 240k hold at p99 961 ms, so kn-final may land one step below it.
- **Slow-disk guard: never fired in any passing run.** In every run up to 160k and in the 144k hold: 0 slow
  commits, every commit on the loop, `thread=0 ckslow=0 memslow=0`. The VM disk is fast enough. It fired only inside
  the overload collapses, where commits took 176-288 ms because the CPU was at 100 %, plus the memory trigger at the
  OOM edge.
- **No 6.8 check failed**: install/build/test 42/42 on the 1 vCPU box. The buffer-ring quirk path was taken and
  works. All 11 kn-final starts came up healthy in 0.04-0.14 s, with no bind retry logged. So no fix was needed under the
  task's rule. One **6.8-specific weakness was found** (below). It is shared with #393 and only shows after an
  overload. I did not fix it.

## Rig

| | Server | Load VM |
|---|---|---|
| Plan | `vhp-1c-2gb-intel` ($0.016/h) | `vhp-8c-16gb-intel` ($0.132/h) |
| CPU | Intel Xeon Processor (Cascadelake), 1 vCPU; retbleed: Enhanced IBRS, meltdown/mds: not affected | Cascadelake, 8 vCPU |
| OS | Ubuntu 24.04.5, 6.8.0-149-generic, stock image, no upgrade | same, JRE 21.0.13 |
| Changes to match the scored box | Vultr's 4.8 GB swapfile removed, ufw off (no `nf_conntrack` after the reboot: `conntrack=none` in every sample), apt timers + unattended-upgrades off. No sysctl touched (`tcp_mem` 21768/29027/43536, somaxconn 4096, as shipped) | same + 8 VPC alias source IPs in netplan, `tcp_max_tw_buckets=0` |

- Region `ewr`, VPC 10.78.0.0/24 (MTU 1450, RTT 0.36-0.62 ms), labels `tdsc-vmtwin-2026-11-24`.
- Scorer-like service: `systemd-run` unit, `User=bench`, `LimitNOFILE=65535`, `AmbientCapabilities=CAP_NET_BIND_SERVICE`,
  `HOST=0.0.0.0 PORT=80`. **Every run on a fresh server start and a fresh seed copy**, like the scorer's probes,
  after a 1,000-user warm-up (20 s + 20 s, not counted).
- Load: **kload** (built from `~/code/kload` `0221e76` for JVM 21, run on the load VM), the `bench/load.js` user
  model and thresholds. Step = **60 s ramp (load.js default) + 60 s hold** + 30 s ramp-down; hold = 60 s ramp +
  300 s. kload's self-check: `gen_loop_stalls` was 0 in every counted run except one 176k fail (1).
- µs/req: **process** = the unit's cgroup `cpu.stat usage_usec` over the hold window divided by the hold's requests.
  **box** = all non-idle CPU from `/proc/stat` deltas over the same window, so it includes softirq outside the
  process. Memory comes from 5 s samples (RSS = VmRSS sum, cgroup `memory.current`, `MemAvailable`, slab). Note:
  `/proc/net/sockstat` "inuse" reads ~4 on this kernel even with 160k open, so the tables use "alloc".
- kn-final ran with `KN_STATS=1` (one stats line every 10 s; the counters exist anyway). This is how the guard's
  counters were read. #393 and the JVM entry ran with defaults.
- Code under test: repo = this branch `3419365` (kn-final; test/, seed/, bench/ byte-identical to upstream main);
  `submissions/java-iouring-davidhsv` from upstream `origin/main` `9768a2dc` (#393 merged); kotlin-nio from branch
  `kotlin-nio-v2` `c0f58b9`. The seed was built on the box (`make-seed.sh`: 29 s, "content sha256 matches"), and the
  load VM used the box's own `tokens.json`.

## Build on the 1 vCPU box (what the scorer does)

| Entry | install.sh (root) | build.sh (user) | test/run.sh |
|---|---|---|---|
| kotlin-nio (calibration) | 9 s | 112 s | 42/42 |
| **kn-final** | 12 s | **201 s** (PGO training ran: "PGO training done; building with the recorded profile"); clean rebuild later 184 s, cgroup `memory.peak` 1,029 MB incl. page cache | **42/42** (174 s incl. its rebuild) |
| #393 | 9 s | 101 s | 42/42 |

systemd's "Memory peak" summary printed nonsense for these units (732 KB), so the only memory figure is the
cgroup `memory.peak` of the rebuild. The README's 584 MB is from a 1.5 GB cgroup locally; it fits on the box either way.

## All counted runs

Process µs/req has the user part in brackets. CPU and softirq are box-wide. "slow" = slow-commit log lines (the guard).

| Run | Users | Result | err % | p95 / p99 ms | hold req/s | CPU | softirq | µs/req process (user) | µs/req box | RSS peak MB | cg peak MB | MemAvail min MB | slab MB | gen stalls | slow | dir |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| calib-nio | 96,000 | PASS | 0.000 | 50.4 / 191.5 | 10,116 | 86 % | 14 % | 80.6 (45.3) | 84.9 | 435 | 544 | 947 | 582 | 0 | 0 | `calib-nio-96000-075858` |
| calib-nio | 112,000 | PASS | 0.000 | 71.2 / 195.6 | 11,833 | 94 % | 15 % | 75.8 (42.4) | 79.1 | 445 | 573 | 888 | 647 | 0 | 0 | `calib-nio-112000-080318` |
| kn | 96,000 | PASS | 0.000 | 9.9 / 21.4 | 10,150 | 33 % | 11 % | 26.3 (12.2) | 32.1 | 66 | 221 | 1253 | 571 | 0 | 0 | `kn-96000-080759` |
| kn | 112,000 | PASS | 0.000 | 10.4 / 21.4 | 11,850 | 36 % | 12 % | 24.9 (12.0) | 30.3 | 68 | 246 | 1191 | 639 | 0 | 0 | `kn-112000-081216` |
| kn | 128,000 | PASS | 0.000 | 13.5 / 22.7 | 13,539 | 40 % | 14 % | 23.9 (11.4) | 29.2 | 70 | 278 | 1030 | 706 | 0 | 0 | `kn-128000-081634` |
| kn | 144,000 | PASS | 0.000 | 21.6 / 117.2 | 15,217 | 45 % | 16 % | 23.4 (10.6) | 29.9 | 75 | 309 | 1083 | 772 | 0 | 0 | `kn-144000-082052` |
| kn | 160,000 | PASS | 0.000 | 33.0 / 169.0 | 16,902 | 49 % | 17 % | 22.0 (9.6) | 28.9 | 78 | 348 | 977 | 838 | 0 | 0 | `kn-160000-082511` |
| kn | 176,000 | FAIL | 4.248 | 13566.0 / 60555.3 | 11,812 | 66 % | 30 % | 41.3 (11.9) | 55.5 | 95 | 820 | 462 | 968 | 1 | 1 | `kn-176000-082929` |
| kn (retry) | 176,000 | FAIL | 5.384 | 60031.0 / 60555.3 | 9,377 | 47 % | 22 % | 35.5 (12.6) | 49.8 | 96 | 852 | 512 | 904 | 0 | 1 | `kn-176000-083350` |
| dav | 96,000 | PASS | 0.000 | 5.0 / 8.2 | 10,163 | 32 % | 10 % | 20.8 (10.7) | 31.1 | 157 | 345 | 1162 | 568 | 0 | – | `dav-96000-083816` |
| dav | 112,000 | PASS | 0.000 | 7.6 / 20.9 | 11,842 | 43 % | 15 % | 24.3 (11.5) | 36.1 | 166 | 340 | 957 | 636 | 0 | – | `dav-112000-084235` |
| dav | 128,000 | PASS | 0.000 | 7.4 / 14.9 | 13,533 | 39 % | 13 % | 20.2 (9.9) | 28.9 | 160 | 361 | 907 | 699 | 0 | – | `dav-128000-084656` |
| dav | 144,000 | PASS | 0.000 | 11.5 / 24.7 | 15,222 | 43 % | 15 % | 20.2 (9.5) | 28.2 | 186 | 418 | 896 | 760 | 0 | – | `dav-144000-085115` |
| dav | 160,000 | PASS | 0.000 | 28.5 / 61.7 | 16,894 | 49 % | 18 % | 21.6 (9.3) | 28.9 | 196 | 449 | 932 | 826 | 0 | – | `dav-160000-085533` |
| dav | 176,000 | FAIL | 5.330 | 28180.5 / 60555.3 | 9,514 | 48 % | 22 % | 32.9 (11.8) | 50.4 | 255 | 1015 | 302 | 876 | 0 | – | `dav-176000-085953` |
| dav (retry) | 176,000 | FAIL | 4.878 | 15007.7 / 60555.3 | 10,547 | 46 % | 21 % | 28.8 (11.1) | 43.9 | 232 | 945 | 397 | 882 | 0 | – | `dav-176000-090411` |
| kn hold 5 min | 160,000 | **FAIL** (OOM kill at 14:13:49) | 24.864 | 10420.2 / 60555.3 | 12,620 | 57 % | 27 % | n/a (process killed) | 45.4 | 108 | 884 | 314 | – | 1 | 2 | `kn-hold5m-160000-090827` |
| dav hold 5 min | 160,000 | **FAIL** | 1.753 | 4554.8 / 60555.3 | 14,479 | 66 % | 28 % | 34.4 (11.9) | 45.5 | 326 | 1075 | 245 | 1084 | 0 | – | `dav-hold5m-160000-091644` |
| **kn hold 5 min** | **144,000** | **PASS** | 0.000 | 24.7 / 57.1 | 15,229 | 48 % | 18 % | **25.0** (10.9) | 31.8 | 101 | 358 | 930 | 673 | 0 | 0 | `kn-hold5m-144000-092533` |
| **dav hold 5 min** | **144,000** | **PASS** | 0.000 | 20.6 / 36.1 | 15,229 | 49 % | 17 % | **24.4** (10.7) | 32.2 | 209 | 463 | 838 | 673 | 0 | – | `dav-hold5m-144000-093351` |
| diag: kn + errno counters, hold | 160,000 | FAIL | 3.537 | 10027.0 / 60555.3 | 12,578 | 71 % | 32 % | 40.2 (11.3) | 56.6 | 95 | 910 | 242 | 1200 | 0 | 1 | `x2-hold5m-160000-094210` |
| diag: + `KN_NBUF=16384 KN_REARM=0`, hold | 160,000 | FAIL (OOM) | 22.195 | 12648.4 / 60555.3 | 12,516 | 60 % | 29 % | n/a (killed) | 47.8 | 201 | 934 | 229 | – | 0 | 3 | `x2nbuf-hold5m-160000-095027` |

kn 144k hold counters: 16,958 commits on the loop, 0 on the thread, 0 slow / ckslow / memslow; 0 timeouts, 0 failed
connects.

## Why both stop at 160-176k on the twin

The wall is the **ramp**, not the steady state. Steady 160k needs 46-50 % CPU for either entry. Linear
extrapolation would put 100 % near 300k (assumption).

1. **Ramp spike.** CPU during the 60 s ramp runs well above the steady value: 56-63 % around 135-160k in passing
   160k runs. In the 176k ramp it reached 66 % at 132k open, 81 % at 142k and 100 % at ~150k (softirq 28 → 63 %).
   Then TCP memory jumped from ~130 pages to 78k-110k pages, past `tcp_mem` max (43,536 pages = 170 MB, derived from
   2 GB RAM). kn's provided buffers ran out (ENOBUFS 0 → 20k → 97k), and dmesg logged `TCP: too many orphaned
   sockets` / `out of memory -- consider tuning tcp_mem`. Both entries show this pattern (timelines:
   `scripts/tl.py <run dir>`).
2. **The kernel aborts connections.** The diagnostic build counts why connections end. In the 160k hold, after each
   spike, ~45k receives completed with **`-ETIMEDOUT` (errno 110)** within 10-20 s, 150k over the hold. There was no
   EOF and no send error. The clients see no FIN. They wait out kload's 60 s timeout and reconnect, so each spike
   comes back 60 s later as a reconnect wave (kernel `tcp_alloc` 160k → 213k → 270k → 313k in the failed kn hold).
3. **On 6.8 the server's closes are not released.** The server closes those slots with `IORING_OP_CLOSE` on the
   direct descriptor, and its open count drops (159k → 106k). The kernel keeps them: `ss` shows ESTAB equal to the
   server's open count, while `tcp_alloc` stays ~50-150k higher. At the end of the diagnostic hold the server had
   processed 138k EOFs and had 44k open, but `ss` showed **130,468 sockets in CLOSE-WAIT**. They were freed only
   when the server's last connections closed.
   - My reading (not verified in the kernel source): on 6.8 a removed fixed file is put only after every *older*
     resource node is released. A multishot receive keeps its node for the connection's lifetime, so closes queue
     behind the long-lived connections. 6.13+ refcounts each file, which would explain why the desktop kernel 7.0
     never showed it.
   - The dead-but-held sockets then eat RAM: slab 1.2-1.4 GB, then a global OOM that killed `server.kexe` (88 MB
     anon) in the 160k hold. #393 shares the direct-descriptor design and the symptom (242k allocated at 160k users,
     82k dead) but survived with less headroom (MemAvailable 245 MB).
4. Bigger receive pools do not help: `KN_NBUF=16384 KN_REARM=0` (#393's pool size) OOM'd the 160k hold faster
   (22 % errors).

Why the scorer is kinder: unknown. #393 passes 240k there with the same kernel and RAM. Plausible differences
(unmeasured): the scorer's 16-core load generators (several hosts) vs one load VM, and the scorer's NIC/virtio cost
per packet (softirq is 17-18 % at 160k here). This run cannot tell them apart.

## What would move kn-final on the real box (ranked, all unmeasured)

1. Release a dead connection's socket without waiting for the 6.8 deferred close. For example, fetch a normal fd
   with `IORING_OP_FIXED_FD_INSTALL` (6.8+) and `close()` it, or re-arm the long-lived multishot receives
   periodically so old resource nodes drain. This removes the OOM and the reconnect leak behind it. Needs a local
   6.8 kernel or a VM to test.
2. Shave the ramp spike: accepts and first requests are what push the box to 100 % around 145-150k. Pausing accepts
   while CPU or ENOBUFS climbs (the 2026-11-10 idea) is still untested.
3. Process CPU: #393 is 0-15 % cheaper per request here, and its system time is lower at 128-144k (10.3-10.7 vs
   12.5-12.8 µs). The local perf split (kernel 8.5 vs 8.8 µs) did not predict that.

## Code changes on this branch

- `csrc/uring.c`: `KN_NBUF` (provided buffers per ring, power of two 64-32768, default 1,024) and `KN_REARM`
  (re-arms per pass after ENOBUFS, default 256, 0 = all) become runtime knobs; defaults unchanged. With `KN_STATS=1`
  the ring-0 line also prints why connections ended: `ends: recv_eof= shuts= send_zero= recv_e<errno>=
  send_e<errno>=`. This is what found the ETIMEDOUT aborts. Built with PGO and run on the VM (the two diagnostic
  holds). `test/run.sh` 42/42 locally (kernel 7.0, PGO build) after the change.
- README: knobs, and a VM-twin section with these numbers.

## Cost and teardown

| Instance | Created → deleted (UTC) | Hours | $/h | Cost |
|---|---|---|---|---|
| server `vhp-1c-2gb-intel` (cd26b91b) | 12:40:51 → 15:00:47 | 2.33 | 0.016 | $0.037 |
| load VM `vhp-8c-16gb-intel` (ac1997e8) | 12:40:52 → 15:00:47 | 2.33 | 0.132 | $0.308 |
| **Total** | | | | **$0.35** (≤ $0.44 if every started hour is billed) |

VPC traffic is free. The holder's trap deleted both instances (HTTP 204), then the VPC (204 on the second try) and the
temporary SSH key (204). A separate systemd --user watchdog unit (`tdsc-vmtwin-watchdog-1795524052`, deadline
16:40:52Z) was armed for the same two ids. After teardown, `GET /instances?label=tdsc-vmtwin-2026-11-24` → **0**, both
ids → 404, VPC → 404. The account's other instances (`litellm-gateway`, `kgb-discord`) were never touched.

## Deviations

- The planned step search was followed (96k, +16k, a fail retried once). The 5-min holds at the highest pass
  (160k) failed for both entries, so I added one more hold each at 144k, the scorer's rule ("stepping down until one
  passes"), and two diagnostic 160k holds with a kn build carrying the errno counters. That build (and the
  `KN_NBUF` build) was compiled on the load VM: nice 19, one core. kload's self-check showed 0 stalls in the runs
  that overlapped it.
- Six queued knob experiments at 176k (`KN_LISTENERS=8`, a 120 s ramp for both entries, `KN_NBUF`) were cancelled
  before they ran, in favour of the holds and diagnostics above.
- One kill of my own shell (a `pkill -f` pattern matched it) cost nothing: the queue it targeted had not started.
