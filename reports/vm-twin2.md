# vm-twin2: calibrating the twin at the top, then kn-final's real ceiling (2026-11-24)

Branch `vm-twin2` (off `vm-twin` 78294ce). Server = Vultr `vhp-1c-2gb-intel` (Cascade Lake, 1 vCPU, 1,961 MiB, Ubuntu
24.04.5, no swap, no ufw/conntrack, apt timers off), load from **four** `vhp-4c-8gb-intel` VMs in the same datacenter
(`ewr`) over a VPC. Nothing pushed, no PR, no GitHub comments. Scripts, every run (per-generator kload JSON with
histograms, merged verdict, server journal, 5 s server and generator samples incl. nstat/NIC counters) and box logs
are in `reports/vm-twin2/`.

## Verdict

- **Why the old twin was wrong above ~160k: the server VM's NIC lost packets outside the guest.** With the stock
  single virtio queue (256 RX descriptors, not resizable), the server's packet rate flattened at **~30k pps RX** from
  ~90k open connections on, while its CPU was still 36-40 % idle. Then RTO timeouts went from 0 to ~30k/s (1.2M per
  run), there were 100k `TCPAbortOnTimeout`, receive queues piled up past `tcp_mem`, and the run collapsed. The
  guest saw no drop (`rx_dropped`, softnet drops: 0), so the loss is in the host, consistent with the RX ring
  overflowing between NAPI polls on one vCPU. It hits any entry: the ETIMEDOUT aborts and CLOSE-WAIT pile-up of
  vm-twin were the consequence, not the cause. The scorer evidently does not lose packets like this: Arjay's #393
  comment shows 250-280k failing on p99 **with 0 errors** (only 320k on refused connections).
- **Calibration found: give the VPC NIC 4 queues** (`ethtool -L enp8s0 combined 4`; max 8, guest default 1 = one per
  vCPU). Same box, same kernel, no sysctl, no submission change. RTO timeouts drop from 1.27M to 0-20 per run, and
  #393 fails at the top the way the scorer reports it: on latency with 0 errors, with the CPU near the limit.
- **What did not matter** (each measured with #393 at 176k, all FAIL with 6-9 % errors before the NIC change):
  four load generators with one source IP each like the scorer (instead of one VM with 8 IPs); generator CPU (peak
  7-11 %), memory (>= 6.5 GiB free), conntrack (none) and drops (0) all fine; the scorer's documented kernel
  **6.8.0-117** instead of 6.8.0-149 (same collapse; kept for all later runs); the public network instead of the VPC
  (worse: 7.1 % errors). The scorer's sysctls are stock ("no kernel tuning"): `tcp_mem` 22038/29386/44076,
  somaxconn 4096, `tcp_max_syn_backlog` 128 here, untouched. k6 itself was not run (it needs ~0.3 MB per VU; the
  account's fee cap allowed only 4 × 8 GB generators); kload is k6-equivalent per its validation.
- **The calibrated twin still runs at ~0.73 × the scorer at the top.** #393 holds **176k** for 5 min here (p99 913
  ms, 0 errors) against **240k** officially (p99 961 ms), and fails 192k on p99 like it fails 250k there. This server
  instance is also ~15 % slower than the scorer for the CPU-bound JVM calibration entry (91 µs/req vs 79 official;
  last session's instance 80.6), plus the multi-queue NIC costs some per packet. So rank against #393, not in
  absolute users.
- **kn-final (as committed before this session) fails where #393 passes**: 160k 60 s step FAIL on p99 1.2 s (0
  errors), while #393 passes it (p99 444 ms). Its highest 60 s pass is **144k**. Cause: provided buffers. At the end
  of the ramp, and again when the ramp-down starts, one pass gets more requests than the ring's 1,024 buffers;
  23k receives end with `ENOBUFS`, and re-arming 256 per pass leaves the last ones waiting 30-90 passes (seconds).
- **Fix, kept: 4,096 buffers per ring and re-arm every starved receive in the same pass** (`NBUF_DEFAULT` 4096,
  `REARM_DEFAULT` 0 in `csrc/uring.c`; the knobs still override). At 160k: p99 1,204 → 317 ms (both knobs), 477
  (buffers only), 561 (re-arm only). Same CPU (41.7-43.8 µs/req box). RSS +4-8 MB. `test/run.sh` 42/42 on the box
  (6.8.0-117, PGO build) and locally (7.0).
- **With the fix, kn holds 176k for 5 min with a much wider margin than #393**: p99 281 vs 913 ms, box 41.6 vs 42.5
  µs/req, RSS 146 vs 343 MB. Both fail the 184k 60 s step on p99 (kn 1.16 s, #393 1.43 s) and the 192k step
  (2.7 s / 3.1 s), all with 0 errors. **On the twin they tie**: same highest hold (176k), same first failing step
  (184k), same box cost per request. kn has the lower tails at every load and a third of the RSS.
- **Projected official score: ~240k, rank 45** (1 + the 44 LEADERBOARD rows above 240,000; 4 rows sit at
  240,000 including #393). It rests on kn tying #393 here, the calibration being a common factor for both entries
  (assumption), and #393's official 240k. kn's lower p99 at equal load hints that it could hold one of the scorer's
  finer steps above #393 (250k would be rank 38); the twin's 8k resolution cannot show that, so I don't claim it.
  Before the fix, kn-final's 144k on the twin would map to ~196k (rank 79).

## Rig

| | Server | Load generators |
|---|---|---|
| Plan | `vhp-1c-2gb-intel` ($0.016/h) | 4 × `vhp-4c-8gb-intel` ($0.066/h each) |
| CPU | Intel Xeon (Cascadelake) @ 2.89 GHz, 1 vCPU; retbleed eIBRS, meltdown/mds not affected | Cascadelake, 4 vCPU each |
| Kernel | 6.8.0-149 (stock image) for the first runs, then **6.8.0-117** (Ubuntu's package, the kernel the LEADERBOARD names for the scored box) | 6.8.0-149 |
| Network | VPC 10.79.0.0/24, MTU 1450, virtio_net; VPC NIC set to **4 combined queues** from run `calib-nio-q4` on (max 8) | 1 source IP per generator on the VPC (like the scorer's one IP per generator) |
| Tuning | none (`tcp_mem` 22038/29386/44076 on 6.8.0-117, somaxconn 4096, syn backlog 128, port range as shipped) | somaxconn 65535, ports 1024-65535, `tcp_tw_reuse` 1, `tcp_max_tw_buckets` 0 |

- Service as the scorer describes it: `systemd-run` unit, `User=bench`, `LimitNOFILE=65535`,
  `CAP_NET_BIND_SERVICE`, `HOST=0.0.0.0 PORT=80`, fresh seed copy and fresh start per run, 1,000-user warm-up (20 s +
  20 s, not counted).
- Load: kload `23d2825` (`~/code/kload`; this session added `hist`/`hist_hold` sparse histograms to `--json`). Each
  generator runs a quarter of the VUs; the four start within ~1 s; `scripts/merge.py` merges the histograms bucket by
  bucket, so p95/p99 are over all requests exactly as one k6 run would compute them. 60 s ramp + 60 s hold +
  30 s ramp-down per step; holds are 60 s + 300 s. `gen_loop_stalls` 0 in every counted run.
- µs/req: **process** = the unit's cgroup `usage_usec` over the hold / hold requests (with more than one NIC queue more
  softirq runs in the process's context and is counted here); **box** = all non-idle CPU from `/proc/stat` over
  the same window. Box is the comparable one across NIC settings.
- Code: kn-final = this branch's `78294ce` build; kn2 = `fbe5eff` (new defaults), and kn-final's behaviour on the
  kn2 build via `KN_NBUF=1024 KN_REARM=256` ("knold"; only defaults changed). #393 = upstream `9768a2dc`
  `submissions/java-iouring-davidhsv`, tree `de045a7`, identical to the scored commit `0813a89`. kotlin-nio =
  `c0f58b9` (identical on this branch).
- Builds on the box (1 vCPU): #393 install 16 s / build 126 s / 42/42; kn-final install 17 s / build 240 s with PGO
  / 42/42; kotlin-nio 42/42; kn2 rebuild 203 s with PGO, 42/42 (on 6.8.0-117).

## Calibration runs

All with the 1,000-user warm-up first; 60 s ramp + 60 s hold unless noted. "RTO" = server `TcpExtTCPTimeouts`
over the whole step, "retrans" = `TcpRetransSegs`. Server 1 (`d13c0e5c`) was replaced after two runs because the
JVM calibration entry cost 94 µs/req on it; server 2 (`d434b148`, same CPU model, ~5 % faster single-thread in a
sha256 / Python loop fingerprint) carried every later run.

| Run | Server, kernel | NIC queues | Load | Entry, users | Result | err % | p95 / p99 ms | hold req/s | box CPU | µs/req box (process) | RTO | retrans |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `c-dav-4g-vpc` | 1, 6.8.0-149 | 1 | 4 gens, VPC | #393, 176k | FAIL | 6.43 | 25,035 / 60,555 | 9,351 | 97 % | 103.6 (65.5) | 944,935 | 891,971 |
| `c-nio-4g-vpc` | 1, 6.8.0-149 | 1 | 4 gens, VPC | kotlin-nio, 96k | FAIL | 0 | 1,663 / 2,146 | 9,705 | 100 % | 102.9 (94.2) | 1,513 | 49,801 |
| `c2-nio-149` | 2, 6.8.0-149 | 1 | 4 gens, VPC | kotlin-nio, 96k | PASS | 0 | 216 / 387 | 10,072 | 97 % | 95.9 (**90.3**) | 293 | 31,747 |
| `c2-dav-149` | 2, 6.8.0-149 | 1 | 4 gens, VPC | #393, 176k | FAIL | 7.26 | 37,487 / 60,555 | 11,206 | 56 % | 49.8 (33.6) | 1,167,467 | 1,147,479 |
| `c2-dav-117` | 2, **6.8.0-117** | 1 | 4 gens, VPC | #393, 176k | FAIL | 9.17 | 60,031 / 61,003 | 11,654 | 56 % | 48.3 (32.8) | 1,271,351 | 1,247,074 |
| `c2-dav-117-pub` | 2, 6.8.0-117 | 1 (public NIC has 1 max) | 4 gens, **public** | #393, 176k | FAIL | 7.06 | 60,031 / 60,555 | – (server ssh timed out; verdict from the merged kload JSON) | | | | |
| `c2-dav-117-q8` | 2, 6.8.0-117 | **8** | 4 gens, VPC | #393, 176k | FAIL (latency) | **0** | 528 / 1,614 | 18,372 | 88 % | 47.8 (43.1) | **1** | 618 |
| `c2-dav-117-q2` | 2, 6.8.0-117 | **2** | 4 gens, VPC | #393, 176k | **PASS** | 0 | 123 / 561 | 18,549 | 75 % | 40.5 (31.2) | 5,336 | 50,529 |
| `c2-dav-117-q4` | 2, 6.8.0-117 | **4** | 4 gens, VPC | #393, **240k** | FAIL (global OOM kill at 226k open in the ramp, CPU 100 % from ~209k) | 80.4 | 1,794 / 7,635 | | | | 20 | 49,807 |
| `calib-nio-q4` | 2, 6.8.0-117 | 4 | 4 gens, VPC | kotlin-nio, 96k | PASS | 0 | 461 / 692 | 10,068 | 97 % | 96.2 (**91.2**) | 5 | 258 |

What the 5 s samples show (`scripts/tl2.py <run>`), #393 at 176k on one queue (`c2-dav-117`): RX climbs with the
ramp to 31k packets/s at ~92k open, then stays at 26-31k/s while the offered load keeps growing. RTOs start
(139/s → 26k/s), CPU is 62-64 % (not saturated), socket memory goes 0 → 107k pages (`tcp_mem` max 44k), receive
pruning, then `TCPAbortOnTimeout` 2-5k/s. Guest drop counters (`rx_dropped` on both NICs, softnet drops) stay 0.
On 4 queues RX goes to 54k/s with 0 RTOs until the CPU itself saturates. The VPC NIC exposes 8 channels; the
public NIC 1 (so the public network cannot be fixed this way, and it was worse). The RX ring is 256 entries and
cannot be resized. My reading (not verified on the host): the host drops packets when the guest's 256-slot RX ring
is full, which on one vCPU takes only ~8 ms of NAPI delay at 30k packets/s. More queues give 4 × 256 slots and
separate host workers.

Generators: CPU peak (busiest generator, 5 s samples) 7-11 % in every counted run, except 26 % in the 240k run
after the server was OOM-killed and every VU reconnected; MemAvailable >= 6.5 GiB, no conntrack module, 0 softnet
drops, at most 57k sockets each; kload self-check 0 stalls in all 45 runs. Not the limit.

Not changed, and why: the scorer's sysctls are stock ("no kernel tuning", LEADERBOARD); the twin's are stock too
(`tcp_mem` is derived from RAM and differs by 1 %). The scorer's generators are 16-core and run k6; kload's CPU here
is 10 % of 4 cores, and its user model and thresholds are k6's (validated in kload's README). Ramp: `load.js`
defaults (60 s), as the scorer uses them ("2-minute probes": the hold length, not the ramp). The JVM calibration
holds within 15 %: 90.3 µs/req on one queue, 91.2 on four, against 79 official. Last session's instance gave 80.6,
so this host is slower for CPU-bound code. That is part of why #393's ceiling here (176k) is below its official
240k. The rest is plausibly the extra per-packet cost of virtio on this host (softirq 28-37 % of the box at 160-192k).

## kn-final vs #393 on the calibrated twin (6.8.0-117, NIC 4 queues)

Fresh server + warm-up per run; 60 s ramp. Highest 60 s pass from 160k in 16k steps (stop at the first FAIL, no
retry), then the 5-min hold there; the 184k midpoint added at the end for both.

| Run | Users | Result | err % | p95 / p99 ms | hold req/s | box CPU | softirq | µs/req box (process, user) | RSS peak MB | cgroup peak MB | MemAvail min MB | RTO | dir |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| kn-final | 160,000 | FAIL | 0.000 | 150.5 / 1204.2 | 16,870 | 75 % | 30 % | 44.4 (37.2, 11.5) | 95 | 381 | 869 | 11 | `kn-160000-154300` |
| #393 | 160,000 | PASS | 0.000 | 60.2 / 444.4 | 16,878 | 72 % | 28 % | 42.9 (34.0, 11.7) | 225 | 535 | 790 | 8 | `dav-160000-154729` |
| #393 | 176,000 | PASS | 0.000 | 342.0 / 790.5 | 18,480 | 80 % | 32 % | 43.2 (35.2, 11.7) | 264 | 569 | 808 | 8 | `dav-176000-155156` |
| #393 | 192,000 | FAIL | 0.000 | 1302.5 / 3129.3 | 19,729 | 88 % | 37 % | 44.5 (37.4, 10.8) | 430 | 844 | 500 | 7 | `dav-192000-155624` |
| kn2 | 160,000 | PASS | 0.000 | 28.5 / 362.5 | 16,884 | 72 % | 28 % | 42.9 (35.9, 11.5) | 101 | 371 | 946 | 0 | `kn2-160000-162214` |
| kn2 | 176,000 | PASS | 0.000 | 99.8 / 346.1 | 18,549 | 79 % | 32 % | 42.5 (36.1, 11.0) | 107 | 405 | 951 | 0 | `kn2-176000-162643` |
| kn2 | 192,000 | FAIL | 0.000 | 337.9 / 2703.4 | 20,048 | 87 % | 36 % | 43.6 (37.9, 11.0) | 111 | 448 | 713 | 0 | `kn2-192000-163110` |
| kn-final (old knobs on kn2 build) | 144,000 | PASS | 0.000 | 19.6 / 116.2 | 15,214 | 66 % | 25 % | 43.2 (35.4, 11.7) | 78 | 309 | 971 | 0 | `knold-144000-163538` |
| #393 hold 5 min | 176,000 | PASS | 0.000 | 71.2 / 913.4 | 18,565 | 79 % | 30 % | 42.5 (35.6, 12.3) | 343 | 705 | 670 | 8 | `dav-hold5m-176000-164007` |
| kn2 hold 5 min | 176,000 | PASS | 0.000 | 42.2 / 280.6 | 18,589 | 77 % | 31 % | 41.6 (36.0, 11.3) | 146 | 487 | 871 | 0 | `kn2-hold5m-176000-164837` |
| kn-final hold 5 min | 144,000 | PASS | 0.000 | 18.0 / 99.8 | 15,226 | 66 % | 26 % | 43.7 (36.4, 11.9) | 100 | 355 | 1054 | 0 | `knold-hold5m-144000-165704` |
| kn2 | 184,000 | FAIL | 0.000 | 234.5 / 1155.1 | 19,263 | 85 % | 33 % | 44.1 (37.5, 11.6) | 107 | 408 | 772 | 0 | `kn2-184000-170539` |
| #393 | 184,000 | FAIL | 0.000 | 317.4 / 1433.6 | 19,246 | 84 % | 36 % | 43.5 (35.7, 11.0) | 344 | 665 | 689 | 6 | `dav-184000-171008` |

Summary:

| | kn2 (new defaults, `fbe5eff`) | #393 | kn-final (old defaults) |
|---|---|---|---|
| Highest 60 s pass (from 160k, +16k) | **176k** (192k FAIL p99 2.7 s; 184k FAIL p99 1.16 s) | **176k** (192k FAIL p99 3.1 s; 184k FAIL p99 1.43 s) | **144k** (160k FAIL p99 1.2 s) |
| 5-min hold at that pass | **PASS**: 0 errors, p95 / p99 42 / 281 ms | **PASS**: 0 errors, 71 / 913 ms | **PASS**: 0 errors, 18 / 100 ms |
| µs/req in the hold: box (process, user) | **41.6** (36.0, 11.3) | 42.5 (35.6, 12.3) | 43.7 (36.4, 11.9) |
| RSS peak / cgroup peak in the hold | **146 / 487 MB** | 343 / 705 MB | 100 / 355 MB |
| ENOBUFS in the hold / slow-disk guard | 11,033 / fired once (57 ms commit at the ramp-down start) | (not exposed) | 10,636 / never |

Every run on the calibrated twin had 0 errors; every failure is on p99. `TCPTimeouts` (RTOs) were 0-13 per run
(vs ~1.2M per run before the NIC change). The guard fired in kn-final's failing 160k step (64 ms) and once in kn2's
176k hold; never in kn2's 60 s steps.

## kn-final's failure and the fix

kn-final at 160k (`kn-160000-154300`), per-generator 10 s lines (kload's progress) and the KN_STATS lines:

- 50-60 s (end of the ramp): p95 18 → 234 ms; 60-70 s: **p95 2,671 / p99 3,228 ms**; from 80 s on the hold is fine
  (p99 23-123 ms). kn's counters: `enobufs` 0 → 4,308 → **23,006** across those 10 s, every one re-armed later
  (`rearms` = `enobufs`), plus one 64 ms commit on the loop (guard: commits to the thread for 10 s).
- 120-130 s (the ramp-down starts and ~15k connections close within 10 s): another 8k `ENOBUFS` (23,125 → 31,081)
  and p99 1,171 ms.
- #393 has the same two bursts, shorter (p95 553 ms at 70 s, 285 ms at 130 s). It uses a 16k-buffer pool.
- So a pass that gets more requests than the ring has buffers (1,024 × 2 KB) ends thousands of multishot receives
  at once, and re-arming at most 256 per pass makes the last of them wait 30-90 passes. That is a design choice from
  the local rig (never an `ENOBUFS` at 384k on loopback), where passes are short.
- The 6.8 deferred close (vm-twin) is still there for both entries: after the clients close, ~130k sockets stay
  allocated until the server's last connections go, then are freed in one burst. It now happens after the scored
  window (the end of the ramp-down), with no error or OOM, so I left it alone.

Knob runs (60 s steps at 160k, same build, fresh server each):

| Run | `KN_NBUF` | `KN_REARM` | Result | p95 / p99 ms | ENOBUFS | box µs/req (process) | RSS MB |
|---|---|---|---|---|---|---|---|
| `kn` (kn-final defaults) | 1024 | 256 | FAIL | 150.5 / 1,204 | 31k | 44.4 (37.2) | 95 |
| `knx-nbuf4k` | 4096 | 256 | PASS | 81.4 / 477 | 3,253 | 43.1 (36.6) | 103 |
| `knx-rearm0` | 1024 | all | PASS | 63.7 / 561 | 141,751 (re-armed at once, many fail again) | 43.8 (37.1) | 96 |
| `knx-nbuf4k-rearm0` | 4096 | all | **PASS** | **33.0 / 317** | 0 | 41.7 (34.9) | 99 |
| `kn2` (new build, new defaults) | 4096 | all | PASS | 28.5 / 363 | 391 | 42.9 (35.9) | 101 |

Kept both as the defaults (`fbe5eff`): `NBUF_DEFAULT` 4096, `REARM_DEFAULT` 0 (= all in the same pass). The
knobs `KN_NBUF` / `KN_REARM` still override. One run each, so the ordering between the single-knob runs is within
noise, but each beats the old default by 2.5×+ on p99, and the combination is best. Not tried for time: closing
on ETIMEDOUT and accept pacing. There were no ETIMEDOUT receives once the NIC stopped dropping (`TCPAbortOnTimeout`
0 in every calibrated kn run), and accepts were not the burst.

After the change: `test/run.sh` **42/42 on the box** (6.8.0-117; install 5 s, build 203 s with "PGO training done;
building with the recorded profile", tests 199 s) and **42/42 locally** (kernel 7.0, PGO build). README knob
defaults and the design bullet were updated. The comment-only credit edit in `uring.c` came after the tests; see
Deviations.

## Cost and teardown

| Instance | Created → deleted (UTC) | Hours | $/h | Cost |
|---|---|---|---|---|
| attempt 1: server + 2 × `vhp-8c-16gb-intel` (01530499, 07855229, 37056b69) | 18:51:08 → 18:51:11 (the third 8c VM was refused by the account's monthly-fee cap; the trap deleted all three) | ~0 | | ~$0 (≤ $0.28 if a started hour is billed) |
| server 1 `vhp-1c-2gb-intel` (d13c0e5c) | 18:53:25 → 19:25:16 (replaced: slow host) | 0.53 | 0.016 | $0.008 |
| server 2 `vhp-1c-2gb-intel` (d434b148) | 19:25:21 → 22:13:34 | 2.80 | 0.016 | $0.045 |
| 4 × `vhp-4c-8gb-intel` (5a085a01, 0e09d355, 8c9ff247, c59f7b64) | 18:53:26 → 22:13:38 | 4 × 3.34 | 0.066 | $0.881 |
| **Total** | | | | **$0.93** (≤ $1.40 if every started hour is billed) |

VPC traffic is free; one public-network run moved ~2.5 GB over public IPs (inside the plans' allowance). Teardown:
`touch stop` → the server holder deleted d434b148 (204), the fleet holder deleted the four generators (204; d13c0e5c
already 404), then the VPC (204 on the second try) and the SSH key (204). Two systemd --user watchdog units
(`tdsc-vmtwin2-watchdog-1795546408` for the fleet, `tdsc-vmtwin2-watchdog-s2` for server 2, deadline 23:53:28Z =
5 h after creation) were armed for exactly those ids and exited by themselves at 22:13:44 / 22:13:54 ("all gone").
After teardown: `GET /instances?label=tdsc-vmtwin2-2026-11-24` → **0**; all 9 instance ids → 404; both VPCs → 404.
No other instance was listed or touched. The key was read only from `VULTR_API_KEY` by `grep` (scripts/api.sh) and
handed to curl on stdin.

## Deviations

- **Fleet shape.** The account's monthly-fee cap refused a third 8-vCPU generator, so the scorer's 4 generators were
  4 × 4 vCPU. kload needed 7-11 % of them, so this did not matter. It also ruled out k6 itself (~0.3 MB per VU; 60k
  VUs per generator would not fit in 8 GB).
- **Server replaced once** (server 1 cost 94 µs/req on the JVM calibration entry). Server 2 still runs ~15 % above
  the official JVM cost (90-91 vs 79). I kept it and calibrate against #393 instead of re-rolling hosts.
- **Kernel switched to 6.8.0-117** (the scorer's, per LEADERBOARD) after the 6.8.0-149 baseline. It did not change
  the failure. All later runs are on -117.
- **The NIC queue change is a rig change the scorer may not literally have.** I do not know the scored box's NIC.
  What I know is its result: no mass loss at ≥ 250k. The twin's default drops packets above 30k pps without the guest
  seeing it. I chose 4 queues (8: no loss but more CPU per packet; 2: some loss left) from three #393 runs.
- **Steps without retry** (vm-twin retried a FAIL once), to fit the time. The 184k midpoint was added for both
  entries because both passed 176k and failed 192k.
- **One run lost its server snapshots** (`c2-dav-117-pub`: the server's ssh shares the loaded public NIC). Its
  verdict comes from the merged kload JSON. step.sh now retries snapshots and bounds every generator ssh.
- **kn-final's numbers after the rebuild** ("knold" rows) are the kn2 build with `KN_NBUF=1024 KN_REARM=256`, its
  old defaults. Only defaults changed in `fbe5eff`. The first kn-final 160k run was on the original build.
- **Comment-only edit after the tests:** the credit line in `csrc/uring.c` (and the README / PR text) now says
  kensac's re-arm was "bounded per pass there; KN_REARM here". Re-tested locally afterwards: `test/run.sh` 42/42 (PGO build, kernel 7.0).
- Not done (time): closing on ETIMEDOUT and accept pacing from the task's fix list. Neither applied after
  calibration: 0 ETIMEDOUT aborts, and the bursts are receives, not accepts.
