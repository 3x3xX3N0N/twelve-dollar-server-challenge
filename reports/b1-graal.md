# b1-graal: Kotlin on GraalVM over our io_uring + B-tree C shim (FFM)

Branch `b1-graal` (off `kotlin-native` f047368). New submission: `submissions/kotlin-graal-3x3xX3N0N`
(install.sh, build.sh, start.sh, README.md, .gitignore, test-restart.sh, test-rings.sh). Nothing pushed.

## Result in one paragraph

It works and it is as fast as our Kotlin/Native entry, not faster. **Default: GraalVM native-image**
(`KG_MODE=jit` = the same jar on the Graal JIT). `test/run.sh`: **`passed=42 failed=0`** in both modes. LOCAL, same
rig, interleaved at 160k users: native-image 17.7-18.9 µs/req, Graal JIT 17.6-19.7, Kotlin/Native entry 18.0-19.8,
java-iouring-davidhsv (#393) **13.9**. Highest 60 s pass: **480k users** (3 of 3 runs, at the 2 GB memory edge:
p99 416-971 ms, cgroup peak ~1.97 GB); 448k passes cleanly (p99 72-309 ms). The two Graal modes cost the same CPU
per request. Native-image wins on memory (54-88 MB RSS against 162-370 MB for the JIT). It also wins on ramp
robustness: on one core the JIT's compiler threads compete with the loop, and one of its two 320k runs failed. The
remaining cost is the kernel (62% of samples) and the shared C (27%). Kotlin is 7%, and the FFM stubs don't show in
the profile. So further gains come from the shared C shim / kernel path, not from Graal.

## Design (details in the submission README)

- Kotlin: `src/Server.kt` (the K/N entry's loop/parser/handlers, which are the kotlin-nio handlers ported to byte
  arrays), `Jwt.kt`, `Json.kt` (unchanged from K/N), `Main.kt`, `Native.kt` (FFM).
- C: the K/N entry's `uring.c`, `db.c`, `btree_reads.c`, `kn.h`, plus `jv.c` (80 lines, the FFM face) and one new
  function in `uring.c` (`ur_wait`), built by gcc into `build/libkn.so` with liburing static.
- FFM, as the track asked:
  - static final address-less handles in `object H`, initialized at image build time
    (`--initialize-at-build-time=app.H`); addresses in `object A` at run time; descriptors registered in
    `native-image/META-INF/native-image/app/reachability-metadata.json`.
  - `Linker.Option.critical(true)` with heap arrays passed in place (one `MemorySegment.ofArray` per array at start
    + int offsets, so nothing allocates per call).
  - **One downcall per busy pass** (`jv_step`: send the staged table, end the DB pass, reap all rings, copy events +
    bytes into Java arrays, return buffers). One per feed/post plan, one per staged write, one per finished batch.
  - Zero allocation on the GET path. The write path allocates a few objects (JSON maps, strings): one 0.2 ms
    young GC every ~8 s at 320k.
  - Monomorphic: no virtual call on the request path; events dispatch on an int in one loop with 4 cases; all
    classes are final.
- **Finding: a critical downcall must never block.** The first version slept in `io_uring_enter` inside the critical
  `jv_step`. The thread stays "in Java" there, so no safepoint could be reached and SIGTERM hung (`test/run.sh`
  never finished). The fix: `jv_step` always runs with timeout 0, and only an empty pass calls `jv_wait`, a plain
  (non-critical) downcall, then steps again. davidhsv's README draws the same line.
- native-image flags: `--gc=serial -march=x86-64-v3 -O2 -J-Xmx800m --enable-native-access=ALL-UNNAMED`.
  - `--no-fallback` is deprecated in GraalVM 25.5 and does nothing (no fallback images any more), so it is not passed.
  - x86-64-v3 rather than `-march=native`: on the box's Cascade Lake, native would permit AVX-512, which lowers
    the clock. I can't test that here (my desktop CPU has no AVX-512).
  - Runtime: `-Xms96m -Xmx96m`.
- JIT flags: `-XX:+UseSerialGC -Xms96m -Xmx96m -Xss1m -XX:ReservedCodeCacheSize=64m -XX:MaxMetaspaceSize=64m
  -XX:-UsePerfData -XX:+UseCompactObjectHeaders`. GraalVM CE uses libgraal as its top-tier JIT by default
  (`UseJVMCICompiler=true`, checked).
- install.sh: GraalVM CE 25.5.5 (graal-25.5.5.0.3, JDK 25.0.5) official tarball, sha256
  `c6438dee…34ef` (matches the `.sha256` published next to it), and the kotlinc 2.4.21 zip (sha256
  `7cc140e7…75cd`, GitHub release digest), plus apt `gcc libc6-dev zlib1g-dev make curl unzip openssl`.
  **install.sh itself was not run** (it needs root on a clean box). I downloaded and checked the same URLs and
  checksums by hand.

## Numbers (LOCAL; method of the kotlin-native README)

- Server: pinned to core 12 (`taskset` + `AllowedCPUs=12`) in `systemd-run --user --scope -p MemoryMax=2G
  -p MemorySwapMax=0`, `ulimit -n 65535`, in a private user+net namespace (bwrap).
- Load: kload on 0-3,8-11 in its own scope (MemoryMax=6G), joined to the namespace with nsenter.
- Each run: 25 s warm-up at 1,000 users, 30 s ramp, 60 s hold. µs/req = server CPU over the hold / requests in
  the hold.
- Driver: `/mnt/nebula/excal/dev0/tdsc-fleet/b1-graal-work/bench.sh` (from the b2 track's script);
  every row is in `b1-graal-work/results.tsv`.

| Users | Build | Result | CPU µs/req | p95 / p99 | RSS | cgroup peak |
|---|---|---|---|---|---|---|
| 160k | native-image | PASS ×10 | 17.7-18.9 (one 21.6) | 1.1-1.9 / 2.3-3.1 ms | 53-86 MB | 680-722 MB |
| 160k | Graal JIT | PASS ×4 | 17.6, 19.2, 19.7, 18.1 | 1.2-2.1 / 2.3-20 ms | 162-370 MB | 771-1,004 MB |
| 160k | Kotlin/Native (n7 build = c5263b5 + committer wait), interleaved | PASS ×2 | 18.0, 19.8 | 1.2-1.5 / 2.3-2.4 ms | 60 MB | 690 MB |
| 160k | java-iouring-davidhsv #393 (built here, PGO, JDK 27 GA) | PASS | 13.9 (user 5.4) | 4.3 / 7.5 ms | 176 MB | 791 MB |
| 320k | native-image | PASS | 16.0 | 2.5 / 15.2 ms | 68 MB | 1,311 MB |
| 320k | Graal JIT | FAIL then PASS | 17.2 / 16.4 | 1,036/3,752 ms (connect p99 3 s) / 8.9/52 ms | 173-179 MB | 1,402-1,645 MB |
| 384k | native-image | PASS | 15.5 | 1.9 / 4.2 ms | 75 MB | 1,559 MB |
| 448k | native-image | PASS ×2 | 16.1, 14.8 | 6.8-69 / 72-309 ms | 83-87 MB | 1,827-1,840 MB |
| **480k** | native-image | **PASS ×3** (edge) | 14.2, 14.3, 13.8 (final build) | 7.4-82 / 416-971 ms | 88-89 MB | 1,965-1,977 MB |

The tail at 448k/480k is writes (like/create p95 ~1.5 s at 480k; reads p99 ~70 ms). The disk is shared, with IO
PSI at 30-46% during these runs.

Steps / tricks (before → after; kept only if it helped):

| Trick | Before → after | Kept |
|---|---|---|
| Port itself: Graal native-image vs Kotlin/Native over the same C | 18.0-19.8 → 18.1-18.3 µs/req (160k, interleaved) | tie |
| Graal JIT vs native-image | 17.6-19.7 vs 17.7-18.9 µs/req; RSS 162-370 vs 53-88 MB; JIT failed 1 of 2 at 320k | native default |
| C shim `-O2` → `-O3 -march=native` (+ `-mprefer-vector-width=256`) | feed plan 6.25-6.45 → 5.76-6.15 µs/call, post unchanged (micro-benchmark, 5 alternating pairs, pinned) | yes |
| native-image `-march=native` → `x86-64-v3` | not measurable here (the Kotlin part is 7% of CPU); a safety choice for Cascade Lake | yes |
| Blocking wait moved out of the critical call | hang on SIGTERM → clean exit; test-restart 0.14 s | yes (correctness) |
| Pacing: wait for 256 CQEs or 1 ms after a light pass (`KN_PACE_NR=256`) | 160k: 17.7/18.3 → 16.3-17.3 (−9%), p95 1.3 → 3.6-4.8 ms; **448k PASS → FAIL** (reads p99 191 → 963 ms), 480k PASS → FAIL | no (knob) |
| `DEFER_TASKRUN` on top of pacing | 16.3-17.3 → 18.0-18.2 at 160k | no (knob) |

Not measured separately: one downcall per pass vs one per send. The design starts batched. The perf profile shows
the stubs below the noise floor, so the boundary would be <1% either way.

Profile (perf, native-image, 160k, 15 s): 62.2% kernel, 26.8% libkn.so (sqlite3BtreeTableMoveto 5.3%, put_str
2.3%, pcache1Fetch 1.7%, ...), 7.2% Kotlin (`__svm_code_section` 5.4% + the inlined main loop 1.8%), libc 3.8%.

Build (one core, a 1.5 GB scope): 4 min 16 s in all, native-image 3 min 18 s, cgroup peak 1,129 MB (with page
cache), builder RSS 1.04 GB. With 7 cores and `-Xmx1100m`: 41 s, peak 1,294 MB.

## Comparison with #393 and jnorthrup's Graal numbers

- **java-iouring-davidhsv (#393, scored 240k at 29 µs/req)** is ~25% cheaper than us on this rig (13.9 vs ~18
  µs/req at 160k). The split is user 5.4 vs ~7.0 and kernel ~8.5 vs ~11.3, so most of the gap is in the kernel.
  - Its pass shape: ring 0 waits for 256 completions or 1 ms, every ring is drained per pass, `DEFER_TASKRUN`, raw
    syscalls without liburing, one SQLite transaction per pass, C at `-O3 -flto` with PGO (trained during the build).
  - Our pacing knob gets 9% of that at 160k but breaks at 448k, where 7 of our 8 rings wait behind ring 0. davidhsv
    may avoid this by draining every ring without waiting and waiting on ring 0 last. I did not test that structure.
    It is the best follow-up (C shim, shared with the K/N entry).
  - Its p95 is higher (4.3 ms vs 1.2) from the batching wait. That's irrelevant to scoring.
- **jnorthrup (r1 §6)**: Graal native-image 23-25 µs and Graal JIT 38-40 µs (wrk post, SQL reads, his TrikeShed
  ring facade), against K/N 10. His Graal gap came from his JVM-side I/O and SQL path, not from Graal: on the same C
  shim, native-image and Kotlin/Native come out equal here, and the Graal JIT is as cheap as native-image once warm.
  His advice "use graal" is therefore neutral for us: it neither helps nor hurts the CPU cost.

## Deviations from the brief

- **Root disk full.** `/` had ~260 MB free (not from my files; the harness temp dir reported 0 MB). TMPDIR, GraalVM,
  kotlinc, the build output (`build` is a symlink, gitignored) and all runs live in
  `/mnt/nebula/excal/dev0/tdsc-fleet/b1-graal-work/` instead of the worktree.
- `seed/feed.db` and `seed/tokens.json` in the worktree are symlinks to the main checkout's (gitignored), like the
  other tracks.
- Local native-image linking needs `libz.so`. The desktop has only `libz.so.1` and I have no root, so local builds
  pass `KG_NI_EXTRA=--native-compiler-options=-L<dir with a libz.so symlink>`. On the box, install.sh installs
  `zlib1g-dev`.
- The Kotlin code starts from the K/N entry's `Server.kt` (the kotlin-nio handlers already ported to flat arrays and
  io_uring events), not directly from kotlin-nio's `ByteBuffer`/selector code.
- The K/N baseline is the owner's prebuilt n7 binary (`/mnt/nebula/excal/research/knative/builds/n7`, c5263b5 +
  the 10 s committer wait), copied and run read-only. It is not a rebuild of f047368, which only adds the bind retry.
- davidhsv's entry was copied into my work dir and built with its own build.sh, using local JDK 27 GA instead of
  its pinned 27.0.1. Its PGO training binds an ephemeral port, so it ran inside a private network namespace
  (bwrap) to keep out of other tracks' ports. No code from it was used.
- One short functional test (the test suite, ~10 s) ran pinned to core 4, my core's HT sibling, before I noticed.
  All benchmarks used core 12 only.
- `--no-fallback`: not passed (deprecated, no effect in 25.5).

## Follow-ups

1. **Pass structure like #393** (C shim, helps K/N too): drain every ring with `submit_and_get_events` and no
   wait, then wait on ring 0 for N or 1 ms. Or move all connections' completions to one waitable ring. Then retry
   pacing at 448k. Expected: most of the 25% kernel-side gap.
2. One SQLite read transaction per pass instead of the snapshot kept across passes (davidhsv), and LTO for the shim.
   PGO trained during the build only if the rules allow it (no committed profile).
3. Zero-allocation write path: a known-schema body/JWT reader into the C batch. It saves the 0.2 ms young GC every
   8 s; tiny.
4. A real-VM run (vhp-1c-2gb-intel, see the memory notes). That would check the build on one vCPU, the AVX
   choice, and the 6.8 kernel quirks, which the C side already handles for K/N.
5. native-image `-O3` and `-march=native` on a Cascade Lake VM, if the Kotlin share ever matters (7% today).

## Open questions for the owner

- Submit this or K/N? Same CPU and same top end here. Graal brings a 350 MB toolchain download and a 3-4 min build
  on the box. K/N has a smaller runtime story (no JVM concepts). I'd submit whichever the C-shim work lands in first.
  The Kotlin side is the same code.
- GraalVM CE is fine licence-wise (GPLv2+CPE). Oracle GraalVM (GFTC) has PGO and a stronger optimizer, but PGO
  needs a profile, and a committed one is forbidden. Worth trying?
- Is `KG_MODE=jit` worth keeping as a knob? It's ~10 lines in start.sh and no extra build step.
