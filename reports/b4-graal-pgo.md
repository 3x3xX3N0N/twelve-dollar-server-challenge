# b4-graal-pgo: does profile-guided optimisation make the Graal build faster?

Branch `b4-graal-pgo` (off `b1-graal` 179edbb). Submission: `submissions/kotlin-graal-3x3xX3N0N` (changed:
`build.sh`, `install.sh`, `README.md`; new: `train/mkdb.c`, `train/Train.kt`). Nothing pushed.
Work dir: `/mnt/nebula/excal/dev0/tdsc-fleet/b4-graal-pgo-work/` (Oracle GraalVM, clang 18, variant builds under
`v/`, `bench.sh` / `abc.sh`, every run in `results.tsv`, micro-benchmark in `micro/`).

## Result in one paragraph

**Native-image PGO (Oracle GraalVM): no.** It doesn't fit the box, and there was nothing for it to gain. The
instrumented image needs more than 2 GB to build (it runs out of builder heap at 800 MB and 1,050 MB, and peaks at
2.2 GB RSS with a 2 GB heap), against a 1.5 GB build cap on a 2 GB box. Oracle GraalVM 25.0.4 also can't initialize
our FFM handles at image build time. That forces run-time handles, which alone cost ~+15 µs/req (CE with run-time
handles costs the same as Oracle). So Oracle images run at 31-35 µs/req against CE's 18.6-19.8, with or without
PGO. On equal footing, Oracle PGO vs Oracle plain is 30.5-33.4 vs 31.9-35.0 µs/req, which is noise.

**C PGO of our shim + SQLite: yes, small, kept as the default.** It's trained inside `build.sh` on a synthetic
database, with gcc. The read micro-benchmark gives feed plan −15 % (5.83-5.87 → 4.95-5.16 µs/call, 5 of 5
alternating pairs) and post plan −3 %. clang 18 with PGO is the same as gcc with PGO; clang without PGO is no
better than gcc. In load runs the gain (~0.5 µs/req expected) is inside this rig's noise. At 160k the default
measured 18.8-20.4 µs/req against 19.7-20.9 for b1's build, with user time 6.7-7.3 against 7.4-7.9. At 448k both
pass (13.2-15.8 vs 13.5-15.3).

- `test/run.sh`: **`passed=42 failed=0`** with the default build. `test-restart.sh` and `test-rings.sh` pass.
- The build fits: 4 min 37 s on one core (training 12.6 s), cgroup peak 1,049 MB in a 1.5 GB scope.
- Highest 60 s pass: 448k (×2). 480k failed once on p99 (1.4 s) at the 2 GB edge, where b1 also only just passed.

## What was built

- **Training at build time** (idea from c-iouring-pavlyhalim #245; no code from it):
  - `train/mkdb.c` (~50 lines) is linked against our `libkn.so`. Using recursive CTEs, it writes a scratch database:
    - the challenge schema;
    - 20,000 users, 50,000 posts and ~200,000 random likes;
    - bodies with quotes, a backslash and non-ASCII text for the JSON escapers;
    - authors skewed to low ids, likes skewed to recent posts;
    - nothing from the seed.
    - It takes ~1 s.
  - `train/Train.kt` is the training client. It runs on the GraalVM JDK and isn't reachable from `app.MainKt`, so
    it isn't in the image.
    - 64 keep-alive connections, each looping over the load test's user loop without think time: feed, a post from
      that feed, 15 % like, 2 % create.
    - Every 64th loop it also sends one of the test suite's error cases (missing or bad token, 404s, bad bodies,
      unknown route, health).
    - 200,000 requests (`KG_TRAIN_REQS`), with zero unexpected statuses in every build.
  - `build.sh` runs it in this order:
    1. instrumented `libkn.so` (`-fprofile-generate`; clang: `-fprofile-generate=dir` + `llvm-profdata merge`);
    2. jar;
    3. native image (unchanged);
    4. mkdb, with its own profile output redirected so it doesn't pollute the profile;
    5. the server on 127.0.0.1:`KG_TRAIN_PORT` (default 3999) + the client under `timeout 900`;
    6. SIGTERM (the profile is written at exit);
    7. `libkn.so` rebuilt with `-fprofile-use -fprofile-partial-training`.
  - If any step fails, the build prints `!! PGO training failed` and builds plain. That path was exercised by
    accident: a first gcc variant didn't find its `.gcda` files and fell back cleanly.
- **Oracle path (knobs only):**
  - `KG_GRAAL=oracle` selects Oracle GraalVM 25.0.4 in `/opt/oracle-graalvm-jdk-25.0.4`. It's installed by
    `KG_GRAAL=oracle install.sh` from `https://download.oracle.com/graalvm/25/archive/graalvm-jdk-25.0.4_linux-x64_bin.tar.gz`,
    sha256 `76007c309f821aaf435bce63162ea0395587fc77350801c81643fe7feea37276`. That digest matches Oracle's
    published `.sha256` for both the archive URL and the `latest` URL. 25.0.4 is the newest Oracle build; 25.0.5
    and 25.0.6 return 404.
  - `KG_PGO=1` builds `--pgo-instrument` with the builder heap `KG_NI_XMX_INST` (default 2g), trains it in the
    same run (`-XX:ProfilesDumpFile`), then builds `--pgo=<profile>`. The final build picks `-O3` by itself.
  - The default `install.sh` does **not** download Oracle GraalVM.
- Bug found on the way: in Kotlin, `port` inside `Socket().apply { }` resolves to `Socket.getPort()` (0). The client
  connected to port 0, and native-image's "connection refused" looked like a server problem at first.

## Numbers (LOCAL; method of b1 / the kotlin-native README)

Rig:
- Server pinned to core 12 (`taskset` + `AllowedCPUs=12`) in `systemd-run --user --scope -p MemoryMax=2G
  -p MemorySwapMax=0`, `ulimit -n 65535`, in a private user+net namespace (bwrap).
- kload (k6-compatible replay of `bench/load.js`) on 0-3,8-11 in its own 6 GB scope.
- Each run: 25 s warm-up at 1,000 users, 30 s ramp, 60 s hold. µs/req = server CPU over the hold / requests in the hold.
- Variants alternated in rounds (`abc.sh`).
- Machine load was 3.4-6.2 from other tracks and IO PSI 15-32 %, so expect ±10 % run-to-run noise.

Variants:
- **ce**: b1's default (CE 25.5.5 native image, gcc shim), rebuilt from this branch.
- **cpgo**: CE + clang 18 PGO.
- **cclang**: CE + clang 18, no PGO.
- **gpgo**: CE + gcc PGO, the new default.
- **opgo**: Oracle 25.0.4 + native-image PGO, with the instrumented image built outside the cap.
- **oplain**: Oracle 25.0.4, no PGO.
- **cert**: CE with run-time handle init, a diagnostic.

| Users | Variant | Runs | CPU µs/req (user) | p95 / p99 (ms) | RSS | cgroup peak |
|---|---|---|---|---|---|---|
| 160k | ce | PASS ×7 (two series) | 18.6, 18.9, 19.8, 18.3 / 19.8, 20.9, 19.7 (6.7-7.9) | 1.2-2.0 / 2.3-3.5 | 50-54 MB | 680-688 MB |
| 160k | **gpgo (default)** | PASS ×3 | 19.3, 18.8, 20.4 (6.7-7.3) | 1.3-1.9 / 2.3-3.0 | 53 MB | 680-689 MB |
| 160k | cpgo | PASS ×3 | 19.5, 17.0, 18.4 (6.0-6.9) | 1.1-1.5 / 2.2-2.4 | 53-54 MB | 680-690 MB |
| 160k | cclang | PASS ×3 | 17.7, 17.1, 17.1 (6.5-6.8) | 1.1 / 2.2-2.3 | 54 MB | 680-690 MB |
| 160k | oplain | PASS ×3 | 32.6, 31.9, 35.0 (21.1-22.7) | 1.3-1.7 / 2.4-2.7 | 55-56 MB | 675 MB |
| 160k | opgo | PASS ×3 | 33.4, 30.5, 32.8 (18.8-20.5) | 1.4-2.3 / 2.6-6.6 | 51-52 MB | 675-687 MB |
| 160k | cert (diagnostic) | PASS ×2 | 37.3, 34.0 (23.2-24.9) | 1.2-1.5 / 2.4-2.7 | 58 MB | - |
| 448k | ce | PASS ×5 (two series) | 13.8, 15.1, 16.1 / 15.3, 13.5 (5.0-5.8) | 1.8-102 / 3.7-179 | 80-86 MB | 1,810-1,841 MB |
| 448k | **gpgo (default)** | PASS ×2 | 15.8, 13.2 (4.5-5.3) | 2.1-45 / 33-185 | 81-89 MB | 1,830-1,877 MB |
| 448k | cpgo | PASS, PASS, FAIL | 13.8, 15.2, 17.6 (4.9-5.8) | 1.8-140 / 3.7-1,630 | 83-88 MB | 1,820-1,898 MB |
| 448k | cclang | PASS ×3 | 15.0, 16.8, 17.7 (5.6-6.4) | 2.4-54 / 8.1-285 | 79-84 MB | 1,816-1,842 MB |
| 448k | opgo | PASS, FAIL, FAIL | 20.4, 19.7, 21.4 (10.9-11.7), CPU 89-100 % | 61-470 / 268-9,241 | 78-87 MB | 1,810-1,969 MB |
| 480k | gpgo (default) | FAIL | 12.4 (4.2) | 8.3 / 1,188 (memory edge) | 86 MB | 1,967 MB |

Each round drifted upward at 448k as machine load rose. The cpgo 448k FAIL is a write tail (p99 1.6 s at 83 % CPU)
on the shared disk, the pattern b1 saw.

Read micro-benchmark: b1's `rb.c`, 100k `db_feed` + 100k `db_post(random id)` through each `libkn.so`, core 12,
5 alternating rounds, last of 3 passes. Values are ns per call:

| libkn.so | feed | post |
|---|---|---|
| gcc -O3 (ce) | 5,831-6,555 (two series: 5,831-5,870; 5,920-6,555) | 2,590-3,308 |
| **gcc -O3 + PGO (default)** | **4,947-5,163** | 2,498-2,608 |
| clang 18 -O3 | 6,170-6,589 | 2,680-3,364 |
| clang 18 -O3 + PGO | 4,892-5,347 | 2,510-3,363 |

Before → after for every trick (kept only where it helped):

| Trick | Before → after | Kept |
|---|---|---|
| gcc C PGO trained in build.sh | feed 5.83-5.87 → 4.95-5.16 µs/call (−15 %), post −3 %; load: 160k 19.7-20.9 → 18.8-20.4, 448k tie | **yes (default)** |
| clang instead of gcc | no PGO: feed +5-10 % (worse); with PGO: equal to gcc PGO. In load runs cclang won at 160k and lost at 448k in every round (noise) | knob `CC=clang` |
| Oracle GraalVM 25.0.4 instead of CE 25.5.5 | 160k 18.6-19.8 → 31.9-35.0 µs/req (run-time FFM handles forced, see below) | knob `KG_GRAAL=oracle` |
| Oracle native-image PGO on top | 31.9-35.0 → 30.5-33.4 (noise); 448k 2 of 3 FAIL | knob `KG_PGO=1` (doesn't fit the box) |
| FFM handles initialized at build time (diagnostic, the b1 design) | run-time init 34.0-37.3 → build-time 18.3-19.8 µs/req (CE) | yes, already the default |

## Build fit (1 vCPU, 1.5 GB build cap)

All runs used one core (`taskset -c 12`, nice 10) in a `MemoryMax=1536M`, `MemorySwapMax=0` scope.

| Build | Wall time | cgroup peak | Result |
|---|---|---|---|
| CE, no PGO (b1 default) | 3 min 41 s | 1,038 MB | ok |
| **CE + gcc C PGO (default)** | **4 min 37 s** (training 12.6 s) | **1,049 MB** | ok |
| CE + clang C PGO | 4 min 12 s (training 12.1 s) | 1,045 MB | ok |
| Oracle native-image, plain (`-O2`, run-time init) | 4 min 7 s (image alone) | builder RSS 1.38 GB | ok, tight |
| Oracle `--pgo-instrument`, heap 800 MB | 10 min 8 s, then OOM (Java heap) | 1,351 MB | **fails** |
| Oracle `--pgo-instrument`, heap 1,050 MB | ~10 min, then OOM | 1,429 MB | **fails** |
| Oracle `--pgo-instrument`, heap 2 GB, 4 GB scope | 5 min 3 s | 2,085 MB (RSS 2.2 GB) | ok, but more than the box's RAM |
| Oracle `--pgo=<profile>` final image, heap 800 MB | 3 min 12 s | 1,164 MB | ok (picks `-O3`) |

`-Ob` is refused together with `--pgo-instrument` ("Native Image needs to control the optimization level for
instrumented builds"). Training the instrumented Oracle image took 10.6 s for 200k requests.

## Rules check

- **README rule 10 / LEADERBOARD ruling (2026-11-15) on PGO**, quoted from LEADERBOARD.md (upstream `origin/main`,
  "Rule flags from code review"): *"go-lowlevel #91 builds with committed PGO profiles … **Arjay's ruling
  (2026-11-15, rule 10):** profile-guided optimization is fine when `build.sh` records the profile on the box during
  the build (a training run on a scratch database); a committed profile recorded somewhere else is not."*
  - Our profile is recorded by `build.sh` on the box, during the build, from a scratch database it generates.
  - Nothing is committed: `build/` is gitignored, and the `.profraw`/`.gcda`/`.iprof` files live under `build/pgo`.
- The same section names the precedent: *"zig-iouring-harshitkhandelwal208 #460 committed a clang profile at
  `122da96`; since `b118b95` build.sh records it on the box with a training run on a scratch database instead
  (settled, merged)."* c-iouring-pavlyhalim #245 (merged, 295k) trains at build time on its own synthetic DB and
  carries no flag.
- SYNTHESIS.md / r6 anti-pattern list: *"committed PGO profiles"* are forbidden. That is the case we avoid.
- **Training failures are scored as build failures.** LEADERBOARD "failures": *"C #396 — build failed …: the
  build's PGO training step (`src/train.sh`) never finished … The build hit the rig's 90-minute timeout (exit 124)
  and the app never ran."* Several #415/#441 runs note *"its PGO training client hit its own 300-second timeout, so
  `build.sh` fell back to a plain (non-PGO) build"*. Our guards:
  - the training client runs under `timeout 900`;
  - the client gives up a connection after 1,000 failed connects;
  - the server gets SIGTERM, then SIGKILL after 30 s;
  - any failure falls back to the plain build;
  - the health wait is bounded (60 s).
- Rule 2/3 (SQLite file at `$SQLITE_PATH`, schema untouched): the scratch database is a separate file under
  `build/train`, deleted after training. The scored database is not touched at build time.
- Rule 11 (nothing acts on the box outside the entry's own files): the training uses only `build/` and a loopback
  port (3999 by default, `KG_TRAIN_PORT`), during the build.
- Build cap: the default build peaks at 1,049 MB in a 1.5 GB scope. `KG_PGO=1` does not fit, so it is a knob, never
  the default.
- No code from other entries: `mkdb.c` and `Train.kt` are new. pavlyhalim's build-time training idea is credited in
  the README.

## Deviations

- Root disk full (~1 GB free): GraalVM, clang, builds, TMPDIR and runs are all under the work dir. The worktree's
  `submissions/.../build` is a gitignored symlink there.
- No root and no clang on the desktop: clang 18.1.8 is Ubuntu's `.deb`s (`apt-get download`, `dpkg -x`) in the
  work dir. That's the same major version as Ubuntu 24.04's default `clang`.
- The Oracle PGO variant was built step by step (the instrumented image outside the cap, training by hand with the
  same commands as `build.sh`, the final image inside the cap), because the instrumented step can't fit. The full
  `KG_PGO=1` path in `build.sh` was not run end to end after `KG_NI_XMX_INST` was added. Its pieces are the
  commands I ran by hand.
- Oracle images use run-time initialization of `app.H` (`KG_NI_BUILDINIT=0`), the only way Oracle 25.0.4 builds our
  code. So "Oracle + PGO" in the table is not the b1 design on Oracle's compiler. The `cert` diagnostic shows the
  cost is the handle init, not the compiler.
- `install.sh` was not run (it needs root on a clean box). The Oracle URL and checksum were downloaded and checked
  by hand. The default `install.sh` is unchanged apart from comments and the optional Oracle block.
- b1's local build quirks again: `KG_NI_EXTRA=--native-compiler-options=-L<libz.so dir>`, seed symlinks.

## Follow-ups

1. Oracle GraalVM based on Graal 25.5+ (when Oracle ships one) may accept the build-time FFM handles. Then retry
   Oracle `-O3` / PGO on equal footing. The instrumented build would still need > 2 GB, so it would need a
   smaller image or a pre-trained ("adopted") profile, which the rules forbid unless made on the box.
2. C PGO + LTO (`-flto` across db.c/uring.c/jv.c) for the shim; davidhsv #393 does PGO + LTO.
3. Train with more connections and the server's real ring count, so that `uring.c`'s multi-ring paths get
   representative counts. Today 64 connections fit in ring 0.
4. A real-VM check (vhp-1c-2gb-intel) of the full default build: build time on a real vCPU, and training
   wall-clock with the client and server sharing it.

## Open questions for the owner

- **Oracle GraalVM licence (GFTC): not decided here.** Facts from the `LICENSE.txt` shipped in the 25.0.4 tarball:
  - It grants a licence "to (a) internally use the unmodified Programs for the purposes of developing, testing,
    prototyping and demonstrating your applications, and running the Program for Your own personal use or internal
    business operations; and (b) redistribute the unmodified Program … provided that You do not charge Your
    licensees any fees".
  - Native Image output: "those portions of a Program included in otherwise unmodified software that is produced as
    output resulting from running the unmodified Program (such as may be produced by use of GraalVM Native Image)
    shall be deemed to be an unmodified Program".
  - Conditions: keep notices, export control, no reverse engineering.
  - Questions for you:
    - Is installing it on the challenge's box, and running a native image built with it in a public, scored but
      unpaid contest, "personal use / demonstrating your applications"?
    - Does install.sh's download count as redistribution? (It fetches from Oracle's own URL; we don't host it.)
    - Is it acceptable to the challenge's rules (open toolchains)?
  - It is moot for performance today: the knob is slower and its PGO doesn't fit.
- Keep the C PGO default? The micro-benchmark gain is clear (−15 % feed plan). The load-run gain is unresolved
  here (~2-3 % expected). It costs ~1 min of build time and a training step that could, in principle, fail; the
  fallback is a plain build. I kept it per "keep whatever wins". `KG_CPGO=0` reverts to b1's build exactly.
- Also apply the same build-time C PGO to the Kotlin/Native entry? It uses the same `csrc/`, and `train/` would
  port with a K/N-side client or this JVM one.
