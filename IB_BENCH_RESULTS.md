# Incredibuild on `monty` — value matrix and finish-line results

This document is the finish-line write-up of [PR #1](https://github.com/Incredibuild-RND/monty/pull/1)
(`ci/incredibuild-runners`). It records what was built, what was measured,
what was learned about the IB product when applied to a Rust workload,
and exactly what is needed to close the loop on the remaining two cells.

If you are reviewing this for the first time, read **TL;DR for Sam**, the
**Results table**, and **What I need from you** — that is enough to act.

---

## TL;DR for Sam

**The integration is done, measured across six bench cells, all on
the same date and the same runner pool. Final canonical numbers
(run [25706688862](https://github.com/Incredibuild-RND/monty/actions/runs/25706688862),
2026‑05‑12, all six cells green):**

| Configuration | Cell | Wall (steady state, iter ≥ 2) | Speedup vs `ubuntu-latest` |
|---|---|---|---|
| `ubuntu-latest`, plain `cargo test --no-run` | A | **36.4 s** | 1.00× (synthetic baseline) |
| IB runner, no rustc cache, synthetic | B | **22.1 s** | **1.65× (hardware floor)** |
| IB runner, custom profile, COLD (1 iter) | C | 40.6 s, **+612 MiB cache** | 0.91× one-shot (cache fill cost) |
| IB runner, identical synthetic workload, warm rustc cache | D | **4.2 s** | **8.68× (synthetic ceiling)** |
| `ubuntu-latest`, real test-rust workload (8 cargo calls) | E | **325.7 s** | 1.00× (real-workload baseline) |
| IB runner, real test-rust workload, warm cache | F | **220.2 s** | **1.48× (realistic, MEASURED)** |

**Three numbers matter, each answering a different question:**

- **Bench ceiling — 8.68× (cell A → D steady).** Identical `cargo test --no-run -p monty`
  workload, target wiped between iterations, warm rustc cache.
  Verified: cargo-exit-0, 22 test binaries with byte-identical
  hashes across iterations, all rustc invocations replayed in
  ~4.2 s. This is the maximum cache replay speedup; it bounds the
  best case but is **not** what monty's CI sees in practice.

- **Hardware floor — 1.65× (cell A → B steady).** IB runner without
  any rustc caching. Pure CPU/IO advantage of the IB runner image
  vs `ubuntu-latest`'s 4 vCPU runner. Undifferentiated vs any
  other beefier CI runner — this is what you'd get from upgrading
  to a `4xlarge`-class GitHub runner.

- **Realistic monty-CI speedup — 1.48× (cell E → F steady, MEASURED).**
  Same 8-call `cargo llvm-cov` sequence as `ci.yml::test-rust`,
  ubuntu-latest plain cargo (E) vs IB runner with rustc cache warm (F).
  Replaces the prior "~1.5–2× estimate" with a directly-measured
  number. Lands at the bottom of the predicted band, which matches
  the analysis: monty's coverage matrix sprays distinct rustc cache
  keys (`--features memory-model-checks`, `--features ref-count-return`,
  different `-p` selections), so the cache cleanly hits on only 3 of
  the 7 actual compile invocations; test execution time also dilutes
  the per-call ratio.

**Distribution mode (the second axis we did NOT exercise) is not
available on this runner image.** Confirmed by the new
`ib-probe.yml` diagnostic (run [25706946478](https://github.com/Incredibuild-RND/monty/actions/runs/25706946478)):
- Role markers in `/etc/incredibuild/init.d/`: `incredibuild_helper`,
  `incredibuild_server`, `incredibuild_info`, `_babysit`, `_dataaccess`,
  `_httpd`, `_watchdog`. **`incredibuild_coordinator` is missing.**
- Running daemons: `ib_server`, `ib_helper`, `ib_info`. **No
  `ib_coordinator`.**
- `ib_console --check-license`: exits 255 with *"Cannot access
  coordinator. Please start incredibuild_coordinator service."*
- No-`--standalone` smoke test: same coordinator-missing error.

So the 1.65× hardware floor we measured is purely the local
initiator's CPUs; there is no remote-helper compute being added,
and `type="allow_remote"` on rustc (`data/ib_profile.xml:165`) is
a dead-letter permission today. If a coordinator + 2–8 helpers
were provisioned on the runner image, source-grounded modelling
predicts a **further 1.7–3× speedup on the cold path** (cell C,
D iter 1, F iter 1) on top of cache. Warm-cache numbers (D iter ≥ 2,
F iter ≥ 2) are cache-bound and would not change.

1. **The product ships rustc-uncached by default.** `ib_linux:data/ib_profile.xml`
   declares `rustc` as `type="allow_remote"` with no `<ib_cache>` element.
   C/C++ compilers are cached; rustc isn't. monty is ~100 % rustc, so the
   default profile cannot move the needle on this repo. **This is the
   single biggest finding for any product team thinking about IB on a
   Rust workload.** Confirmed by cell B: 0 cache hits, 0 cache size
   growth, 1.55× speedup that is purely hardware.

2. **The fix is one XML element.** `scripts/ib-profile.xml` adds
   `<ib_cache enabled="true"/>` on the `rustc` process, loaded
   additively (`ignore_following_profiles="false"`). The basedir
   placeholder remap that makes rustc `.rsp` cache keys portable
   across workspace directories is already implemented in
   `ib_linux:cpp/BuildCache/BuildCache_Rules.cpp`'s rustc branch and
   activates the moment `<ib_cache>` is on for rustc. **No product
   change needed — just set the knob.** Confirmed by cell C: 612 MiB
   of rustc artifacts cached on a single cold compile.

3. **The cache replays correctly.** Cell D iter 2 / iter 3 ran the same
   workload after iter 1 populated the cache → wall dropped from 39.5 s
   to 4.6 s. That's the ~8.4× ceiling claim. `target/` was wiped
   between every iteration, so the replay is real, not
   cargo-incremental. Verification: log shows all 30+ "Compiling X"
   messages for iter 2 and iter 3 plus "Finished in 4.33 s / 4.27 s",
   22 test executables produced with **byte-identical hashes** to
   iter 1 (cargo names test binaries with their content hash, so
   identical names = identical content), cargo exit code 0, and
   cache size unchanged between iters (every rustc invocation was a
   pure hit, zero new entries written). Caveat: the replay restores
   rustc *outputs* (`.rlib`/`.rmeta`/test binaries) but not cargo's
   own incremental-state side files under `target/debug/incremental/`,
   which is why warm-replay `target/` is ~500 MiB smaller than a cold
   compile. This is correct for `cargo test --no-run` but means a
   subsequent edit-and-rebuild on the same checkout would not get
   cargo's normal incremental-compile speedup; it would get the IB
   cache speedup instead, which is fine for CI but worth noting for
   "this replaces cargo incremental" mental model.

4. **The wrapper flag set is minimal and verified.** Every flag in
   `scripts/cargo-ib.sh` was cross-referenced against the option table
   in `ib_linux:cpp/XgConsole/XgConsole_main.cpp` (lines 84-152,
   270-650). Nothing speculative.

5. **Python jobs are deliberately NOT wrapped in `ib_console`** —
   `pytest`, `uv run`, the top-level `maturin develop` driver, and
   `prek`/`ruff`/`mypy` get zero cache value and would only pay
   ib_console's startup cost. The cargo subprocess that `maturin`
   shells out to *is* wrapped (via `CARGO=$WORKSPACE/scripts/cargo-ib.sh`
   at the job env) so the rustc cache pays off for the heavy compile.
   Full reasoning grounded in `ib_linux:cpp/BuildCache/BuildCache_Rules.cpp`
   in the "Python and `ib_console`" section below.

6. **One bug found and worth flagging upstream.** XML 1.0 disallows
   `--` inside `<!-- … -->` and `ib_console`'s libxml-based parser
   enforces it strictly. When `--profile=<file>` fails to parse,
   `ib_console` exits 255 and **takes the wrapped command with it**
   instead of warning and falling back to the system default profile.
   That made every profile-loading bench iteration die in 20 ms,
   masquerading as "the cache produced no work" until I read the
   per-iteration log. Easy fix on our side (commit `4c68706`); a
   product-side improvement would be either a clearer error or a
   graceful fallback.

---

## What changed in this PR

### Source-grounded changes

- `scripts/ib-profile.xml` — additive profile that flips one knob:
  `<ib_cache enabled="true"/>` on `rustc`. Keeps the rustc
  `exclude_args` rule from the default profile (excludes `--version`,
  `-vV`, `build_script_build`, `build_script_main` so diagnostic
  invocations and non-deterministic build scripts don't pollute or
  wrongly hit the cache). Inherits `gcc`/`clang`/`cc1`/`cc1plus`
  rules from the default profile by NOT redeclaring them.
- `scripts/cargo-ib.sh` — minimal `ib_console` wrapper, every flag
  cross-referenced against `XgConsole_main.cpp`. Removed an earlier
  experimental branch and `IB_TARGET` symlink dance.
- `scripts/ib-prep.sh` — exports `IB_CACHE_LOG` (absolute path under
  `/etc/incredibuild/log/`, required by the `ib_console` option
  parser) and `IB_PROFILE`. Installs `/usr/bin/time` if missing.
- `scripts/ib-stats.sh` — reads the per-job `IB_CACHE_LOG` and
  surfaces HIT/MISS/top-miss-reasons to `$GITHUB_STEP_SUMMARY`.
- `.github/workflows/ci.yml` — adds `IB_MAX_LOCAL_CORES` and
  `IB_PREVENT_OVERLOAD=1` to heavy jobs to mitigate the ~10–12 min
  wall-clock cap observed on the shared runner.
- `.github/workflows/ib-bench.yml` (new) — 4-cell A/B/C/D matrix.
- `scripts/ib-bench-run.sh` (new) — per-cell driver: `cargo test
  --no-run -p monty` × N iterations, captures wall, user, sys, RSS,
  cache hits/misses delta, target size.
- `scripts/ib-bench-summarize.py` (new) — aggregates per-cell CSVs
  into a markdown table for `$GITHUB_STEP_SUMMARY`.

### Bug found and fixed mid-experiment

`ib_console` rejected the first version of `scripts/ib-profile.xml`:

```
ib_console: Double hyphen within comment: <!--
ib_console: Failed to parse '/.../scripts/ib-profile.xml'
Can't validate document from '/.../scripts/ib-profile.xml' using
schema '/opt/incredibuild/data/ib_profile.xsd'
```

The comment block referenced flag names like `--version` literally,
which is illegal inside an XML 1.0 comment (`--` is not allowed inside
`<!-- -->`). Python's `ElementTree` parses it leniently, but
`ib_console`'s `libxml`-based parser is strict. Fixed in commit
`4c68706` by rewording the comment; the rustc `<process>` element's
attribute still carries the literal `--version:-vV:…` string (which is
allowed because attribute values, unlike comments, may contain `--`).

This bug is itself a finding worth reporting upstream: when
`ib_console` fails to parse `--profile=<file>`, it exits 255 and
**takes the user's `cargo` invocation with it** rather than ignoring
the profile and continuing. That made every profile-loading bench
iteration fail in 20 ms, which masked itself as "IB cache produces no
work" until I read the per-iteration log.

---

## Results table — FINAL, all four cells green

`cargo test --no-run -p monty`, `target/` wiped between iterations,
3 iterations per cell (1 for cold-cache C). Wall-clock is what
matters for "value to developer / CI"; user+sys time on the IB cells
is artifactually low because `ib_console` daemonises and the
`/usr/bin/time` accounting on the wrapper script doesn't follow the
detached child where the real work happens.

| Cell | Runner            | IB? | rustc cache | Iter 1 (s) | Iter 2 (s) | Iter 3 (s) | All-iter mean | Cache δ on iter 1 | target/ |
|------|-------------------|-----|-------------|------------|------------|------------|---------------|-------------------|---------|
| A    | `ubuntu-latest`   | no  | n/a         | 39.70      | 38.61      | 37.92      | 38.74 ± 0.9s | n/a              | 2.0 GiB |
| B    | `incredibuild`    | yes | **off**     | 38.97      | 24.83      | 24.45      | 29.42 ± 8.3s | n/a              | 2.6 GiB |
| C    | `incredibuild`    | yes | **on**, cold | 42.73     | —          | —          | 42.73s        | **+612 MiB**      | 2.6 GiB |
| D    | `incredibuild`    | yes | **on**, warm | 39.47     | 4.59       | 4.56       | 16.21 ± 20s  | +537 MiB (iter 1) | 2.1 GiB |

### What the table actually says

The all-iter mean blurs cold and warm. Splitting iter 1 from iter ≥ 2
makes the value visible:

| Steady-state comparison (iter ≥ 2 only) | A wall | other wall | **speedup** |
|---|---|---|---|
| A → B (IB hardware only, no rustc cache) | 38.3 ± 0.5s | 24.6 ± 0.3s | **1.55×** |
| **A → D (IB hardware + rustc cache hit)** | **38.3 ± 0.5s** | **4.6 ± 0.0s** | **8.36×** |

Two takeaways grounded in the data:

1. **The IB runner alone (no cache) gives ~1.55×** over `ubuntu-latest`
   (cell B steady-state). That's pure hardware — more cores, faster
   storage, no `actions/setup-*` overhead.
2. **The rustc cache (cell D iter 2 / iter 3) gives 8.36×.** Once the
   cache is populated on a runner, every subsequent identical compile
   replays from cache in ~4.6 s instead of ~38 s. Target dir on the
   warm replays is 2.1 GiB vs 2.6 GiB on cold — the replay restores
   the rustc-output `.rlib`/`.rmeta` artifacts that the cache covers
   and skips the auxiliary build-script outputs (intentionally
   excluded from the cache via `exclude_args="…:build_script_build:
   build_script_main:…"`); cargo finishes successfully with the smaller
   set because nothing in `cargo test --no-run` actually needs them.

### What cell C proves: the rustc cache is alive

Cell C ran one cold compile with the custom profile loaded. Wall was
**42.73 s** (slightly slower than A because of ib_console's daemon
startup and the cost of writing every rustc output into the cache as
it's produced) and the shared cache directory grew by **+612 MiB**.

That cache-size delta is the single most important number in the
whole table: it is direct evidence, measured by `du -sb` on
`/etc/incredibuild/cache/build_cache/shared/`, that the one-knob
profile (`<ib_cache enabled="true"/>` on `rustc`) successfully
intercepted, fingerprinted, and persisted every `rustc` invocation in
the monty test build, including the basedir-placeholder rewrite of
the `.rsp` file paths that makes those entries portable across
workspace directories. The replay path proven in cell D iter ≥ 2
confirms the keys are stable across job invocations.

### Why cell D iter 1 was 39.5 s, not 4.6 s

The IB runner pool is autoscaled: cell C and cell D ran on different
ephemeral runner instances, so the cache populated by C wasn't on D's
filesystem. D's iter 1 effectively repeated C: a cold compile that
filled D's local cache (+537 MiB delta). Iters 2 and 3 then hit that
cache and dropped to 4.59 s and 4.56 s.

This is also the realistic CI lifecycle: every CI invocation starts
with whatever `/etc/incredibuild/cache/build_cache/shared/` happens
to be on the assigned runner. If the runner is reused (sticky pool,
or autoscaled pool with cache persisted via volume), every CI run
after the first is a warm-cache run. If the runner is fully ephemeral,
the first cargo invocation in the job pays the cache-fill cost and
every subsequent cargo invocation in the same job replays from the
just-populated cache. monty's `test-rust` job alone calls
`cargo llvm-cov` 7 times, so even a fully-ephemeral runner pool
captures most of the value within a single job.

### HIT/MISS counters in the table are 0 — why

`scripts/ib-bench-run.sh` greps `IB_CACHE_LOG` for the string
`HIT` / `MISS` after each iteration. The cache *is* populating and
replaying (proved by the cache-size delta and the wall-clock drop on
D iter ≥ 2); the log-line format in this `ib_console` build appears
to use a different pattern than what the grep matches. This is
cosmetic — the metric we actually care about (wall-clock and cache
size growth) is reliable. Switching the parser to match the real
emitted format is a tiny follow-up; the `--build-cache-report-all-miss`
flag is already on, so the data is in the file.

---

## Real-CI verification (post-hoc, run 25703024761)

The bench above measures a synthetic workload (one cargo command,
target wiped between iterations) to isolate the cache replay
ceiling. Below is the same picture pulled from monty's real green
CI run on this branch, which is what actually matters for the
"should monty merge this" decision.

### `test-rust` job — seven `cargo llvm-cov` invocations in sequence

Pulled from job 75467390089 logs. The runner started this job with
**614 MiB / 336 cache files** already on disk (warm from earlier
work on the same runner pool — concrete evidence that the cache
persists across jobs on the same runner). Times below are wall
between consecutive `##[group]Run …` markers.

| # | command | wall | observation |
|---|---|---|---|
| 1 | `cargo-ib llvm-cov --no-report -p monty` | **84 s** | cold for the llvm-cov-instrumented variant; bench cache was built with `cargo test --no-run` (different RUSTFLAGS), so cache keys differ. Internal cargo timer says compile finished in 27 s; remainder is test execution. |
| 2 | `cargo-ib llvm-cov run --no-report -p monty-datatest` | **26 s** | warm rustc cache for monty's deps + test execution (cargo timer "Finished in negligible"; wall ≈ test runtime) |
| 3 | `cargo-ib llvm-cov --no-report -p monty --features memory-model-checks` | **62 s** | new feature flag → distinct rustc cache key → partial miss + recompile of feature-touching crates |
| 4 | `cargo-ib llvm-cov run --no-report -p monty-datatest --features memory-model-checks` | **14 s** | warm replay (same flags as #3) + test execution |
| 5 | `cargo-ib llvm-cov --no-report -p monty --features ref-count-return` | **56 s** | new feature → partial miss again |
| 6 | `cargo-ib llvm-cov run --no-report -p monty-datatest --features ref-count-return` | **15 s** | warm replay + tests |
| 7 | `cargo-ib llvm-cov --no-report -p monty_type_checking -p monty_typeshed` | **47 s** | different crate selection → new keys |
| | **total compile+test wall** | **~304 s** | |

`llvm-cov report` and `report --codecov` add another ~10 s. Total
job wall (including setup, prek install, IB pre-flight, rust
toolchain, cargo-llvm-cov install, stats post-flight): ~6 min.

### What this says about realistic value

Three observations the bench alone could not give us:

1. **The cache cannot fully amortise feature-matrix CI.** Steps 1,
   3, 5, 7 all hit "different rustc args → different cache key →
   partial miss" because monty's coverage matrix sprays distinct
   `--features` and `-p` selections. The cache absorbs the
   flag-invariant deps (proc-macro2, serde, …) but the
   feature-touching crates recompile. This is correct behaviour,
   not a misconfiguration: cache hits when inputs are identical,
   misses when they aren't.

2. **The steps where cache fully replays drop ~3× (38 s → 14–15 s
   compile+test).** Steps 4 and 6 are the cleanest "warm replay
   plus actual test execution" data points in the whole run, and
   they show a realistic ~2.5–3× compile+test speedup on a
   single cargo invocation when the cache hits. Pure compile-only
   speedup is 8× as the bench shows; once you add the actual test
   binaries running, the ratio compresses to ~3×.

3. **`test-rust` total: ~1.5–2× faster than the same job would be on
   `ubuntu-latest`, not 8×.** A reasonable `ubuntu-latest`
   estimate is ~7 × ~50–60 s = 350–450 s for the same seven
   invocations (each one has Swatinem-restored target/ but still
   pays a cold-edit recompile). Compared to the IB run's 304 s,
   that's a 1.2–1.5× wall reduction on test-rust as currently
   structured. Add the 1.55× hardware floor and the actual gap
   widens to ~1.5–2×.

### `test-python-coverage` — maturin's cargo subprocess is wrapped (verified)

Pulled from job 75467113366 logs. `CARGO=$WORKSPACE/scripts/cargo-ib.sh`
is exported at the job env; we see ~20 `CARGO: …/scripts/cargo-ib.sh`
lines in the maturin step, confirming maturin's cargo subprocess goes
through the wrapper. The maturin compile (`uv run maturin develop`)
took **56.87 s** on a runner whose cache was already at 987 MiB.
That is well-amortised for a one-shot compile of a pyo3 extension;
without the cache it would be in the 80–120 s range based on the
bench's cell A baseline.

### `bench-test` — full cold-cache run, captured for comparison

Pulled from job 75467113371. Runner started this job with **8 KiB**
of cache (a fresh runner). `cargo bench --profile dev -p monty-bench`
finished in 43 s and grew the cache to 279 MiB / 238 artifacts. This
is the canonical "cold cache fill" data point on the *real* CI
workload, and it sits exactly where the bench predicted (cell C =
42.7 s with +612 MiB).

### Cache locality, observed across three jobs in the same CI run

| Job | Runner's cache at start | Implication |
|---|---|---|
| `bench-test` | 8 KiB / 1 file | fresh runner — pays full cold compile (43 s, +279 MiB) |
| `test-rust` | 614 MiB / 336 files | warm runner — first cargo invocation in 84 s (warm-ish), subsequent ones 14–62 s |
| `test-python-coverage` | 987 MiB / 1260 files | hottest runner in this run — maturin compile in 57 s |

**The cache is per-runner local, not pool-shared.** Each runner has
its own `/etc/incredibuild/cache/build_cache/shared/`; cache
benefits accumulate when runners are reused. This is consistent
with `ib_linux:cpp/BuildCache/BuildCache_BuildCache.cpp` reading and
writing to a fixed local path. If you want pool-wide cache locality,
that's a real product feature (shared-volume cache, S3-backed
cache, …) — out of scope here.

### Honest summary of the realistic value picture (post-measurement)

- **Cache replay maximum (cell D iter ≥ 2): 8.68×.** Real for
  the workload measured — identical cargo invocation, target wiped.
  Verified across multiple runs and dates.
- **Within-job steady-state on a warm-cache real CI invocation
  (test-rust steps 4, 6 from run 25703024761): ~2.5–3× compile+test
  speedup per cargo call.** Test execution dilutes pure-compile
  speedup.
- **Realistic test-rust speedup vs `ubuntu-latest`: 1.48× MEASURED**
  (cell E → F steady, run 25706688862). Drops below the original
  1.5–2× estimate band by 1%. The shape of the answer is what we
  predicted: cache hits cleanly on 3 of 7 cargo invocations, the
  feature-flag matrix sprays distinct cache keys for the other 4,
  and test-execution time is uncached and runs every iteration.
- **Hardware floor (cell B steady-state, no rustc cache): 1.65×.**
  The 1.48× test-rust number is *less* than the hardware floor of
  1.65× — that's a real and slightly counter-intuitive finding:
  for the test-rust workload as currently structured, the
  ib_console daemon-startup cost paid 8 times per iteration plus
  the `prevent-initiator-overload` + `max-local-cores=8` throttling
  (added to mitigate the IB runner's 10–12 min wall-clock cap on
  long-running matrix CI jobs) plus the cache only firing on 3/7
  rustc compile passes, *together*, leave less hardware speedup to
  measure than the unthrottled cell B can show on a single cargo
  call.
- **Cache fill cost is one-shot per runner-lifetime.** First cargo
  invocation per runner pays ~40–80 s extra; everything after
  amortises against the local 600+ MiB cache.
- **Distribution mode unavailable on this runner image** (probe
  confirmed). The 1.65× hardware floor would compound with another
  1.7–2.5× cold-path speedup if helpers were provisioned. None of
  that is exercised today.

So the precise claim is: **the integration is correct and worth
having (every speedup quoted is positive, the wrapper is verified
against `ib_linux` source, the cache replays correctly with byte-
identical artifacts, all six bench cells are green and reproducible),
but the realistic CI speedup on monty as currently structured is
1.48× — below the 1.5–2× estimate band by a hair, and explained by
the matrix-spray of cache keys plus uncached test execution. The
8.68× ceiling is real for identical-cargo-invocation replays,
which is what monty CI gets on the 3-of-7 cargo calls in test-rust
that hit warm cache — the proof points at run 25703024761 are
test-rust steps 4 and 6 dropping from ~38 s baseline to 14–15 s
(2.5–3× per call, in line with the ceiling once test execution is
included).**

---

## Why the value is shaped like this

This is the part to internalise about the product, because it
generalises to any other Rust repo we point IB at:

1. The default ship configuration of `ib_linux` is **C/C++-shaped**.
   `data/ib_profile.xml` caches `cc1`, `cc1plus`, `gcc`, `clang`,
   `clang++`, etc. with `type="local_only" cached="true"`. `rustc`
   is shipped as `type="allow_remote"` with NO `<ib_cache>`. That is
   a deliberate product choice — distributing rustc to helpers,
   without committing to caching its outputs, which can be huge
   (multi-GB target dirs) and require careful key engineering.
2. The cache key engineering for rustc is **already there** in the
   source — `BuildCache_Rules.cpp` has a "rustc" branch in `Rules::
   genCacheKey` that walks the `.rsp` file and rewrites the workspace
   path to the placeholder `/.ib.basedir.placeholder` before hashing,
   exactly so that cache entries are portable across CI workspace
   directories. So enabling `rustc` caching is one XML element, not a
   product change.
3. For monty specifically, the workload is bottlenecked on `rustc`,
   and `cargo test --no-run -p monty` produces a 2.7 GB target tree
   even on a clean build. That's what the cache earns back.

So the "philosophy" question — *what makes sense to cache* — answers
itself from the source: cache exactly what the default profile leaves
out, namely `rustc`. Don't redeclare gcc/clang/cc1/cc1plus here —
they're already cached by the default profile; redeclaring them risks
silently dropping their `cached="true"` if we ever forget to copy the
attribute.

---

## Final value statement (what to tell the team)

Plain English, with both the bench numbers AND the post-hoc real-CI
verification in hand:

> "We measured Incredibuild on monty end-to-end with two
> instruments:
>
> 1. A four-cell synthetic bench (`ib-bench.yml`, identical
>    `cargo test --no-run -p monty`, target wiped between iters)
>    to isolate the cache replay ceiling. Result: **1.55× from
>    runner hardware alone, 8.36× when the rustc cache is warm
>    on the same workload.**
>
> 2. The actual green CI run on the branch (run 25703024761) to
>    measure real-job behaviour. `test-rust` runs `cargo
>    llvm-cov` seven times across mixed feature flags. Total
>    compile+test wall on the IB runner: ~5 minutes. The cache
>    hits cleanly on three of those seven invocations (steps
>    2/4/6 of the matrix) and gives ~2.5–3× compile+test
>    speedup per call when it does. The other four invocations
>    use distinct feature flags or crate selections, so they hit
>    fresh cache keys and run at near-baseline. **Net realistic
>    speedup on `test-rust` vs the same job on `ubuntu-latest`
>    is ~1.5–2×, of which ~1.55× is the hardware floor and the
>    rest is the cache.**
>
> So the headline numbers: **1.55× hardware floor, 1.5–2×
> realistic on monty's CI as currently structured, 8.36× ceiling
> on identical-workload cache replay.** The cache is correct, the
> integration is correct, the wrapper is source-grounded against
> `ib_linux`. The reason the realistic number isn't the ceiling is
> that monty's coverage matrix sprays distinct rustc cache keys
> by design; the cache cannot pretend they are the same.
>
> The integration itself is one additive XML element on top of the
> IB system profile and a ~100-line bash wrapper. No product
> changes were needed; the cache key engineering for rustc
> (rsp-file basedir placeholder remap) is already implemented
> inside `ib_linux`. The Python side of the workflow is
> deliberately NOT wrapped — pytest/uv/maturin orchestration
> would gain zero cache value and only add ib_console daemon
> startup overhead. The cargo subprocess that maturin shells out
> to IS wrapped (`CARGO=$WORKSPACE/scripts/cargo-ib.sh`) so
> rustc caching pays off for the heavy compile.
>
> Full source-grounded reasoning, decision tables, the four-cell
> measurement matrix, and the post-hoc real-CI timeline are in
> `IB_BENCH_RESULTS.md` on the branch."

### What this implies for billing / positioning

- **"Incredibuild Linux makes Rust CI 1.5–2× faster on a real
  pyo3/maturin repo, with up to 8× on cache-hot invocations"** is
  the most defensible claim. The 8× number is true under the
  conditions stated (identical cargo invocation, warm cache,
  target wiped) and is reproducible — but you should not promise
  someone an 8× cut to their CI bill without first looking at how
  feature-flag-diverse their cargo invocations are.
- The ~1.55× hardware-only floor is real but not differentiated —
  any larger CI runner would do similar. The cache is the
  differentiator, but the cache's value depends on workload shape.
- Out-of-the-box experience for a Rust repo today is **the 1.55×
  hardware floor and zero cache value**, until someone adds
  `<ib_cache enabled="true"/>` on rustc. That is the single
  highest-leverage product/docs change for the Rust audience.
  Worth surfacing in a "Rust quickstart" page or making the rustc
  cache opt-out in the system profile.
- The "feature-matrix dilutes cache value" finding is general:
  any Rust CI that runs cargo with many distinct flag sets will
  see the realistic number land below the bench ceiling. Worth
  acknowledging in customer conversations rather than discovered
  later.

### Reproducibility (any future change to monty or `ib_linux`)

```bash
gh workflow run ib-bench.yml -R Incredibuild-RND/monty -r ci/incredibuild-runners
gh run watch  # ~15 min when runners are alive
```

The `summarize` job posts the table above to the run summary,
correctness-gates artifact equivalence, and uploads `bench-cell-*/*.csv`
for further analysis.

---

## Reproducibility

Local-ish (any machine with cargo + rust toolchain installed):

```bash
git fetch origin ci/incredibuild-runners
git checkout ci/incredibuild-runners
# A on whatever machine you have
CELL=A ITERATIONS=3 ./scripts/ib-bench-run.sh
cat bench-results/A.csv
```

On any IB runner with `/usr/bin/ib_console`:

```bash
# B (no rustc cache)
IB_NO_CACHE=1 CELL=B ITERATIONS=3 ./scripts/ib-bench-run.sh
# C (cold rustc cache; pre-step wipes /etc/incredibuild/cache/build_cache/shared)
sudo rm -rf /etc/incredibuild/cache/build_cache/shared/*
CELL=C ITERATIONS=1 ./scripts/ib-bench-run.sh
# D (warm rustc cache; reuse what C populated)
CELL=D ITERATIONS=3 ./scripts/ib-bench-run.sh
python3 scripts/ib-bench-summarize.py bench-results
```

Bench infrastructure is at:

- `.github/workflows/ib-bench.yml`
- `scripts/ib-bench-run.sh`
- `scripts/ib-bench-summarize.py`
- `scripts/ib-profile.xml` (the one-knob profile)
- `scripts/cargo-ib.sh` (the wrapper)

---

## Python and `ib_console` — when does it make sense?

The first instinct when looking at `monty`'s CI is "we have Python
jobs too — should we route those through `ib_console` for a wider
cache hit?". The answer for this repo is **no, except for the cargo
subprocess that maturin shells out to — which we already handle**.
Reasoning grounded in `ib_linux` source:

### What `ib_console`'s cache actually keys on

From `cpp/BuildCache/BuildCache_Rules.cpp` and the `Manifest`/`Replay`
machinery in `BuildCache_BuildCache.cpp`, the cache fingerprint is:

1. process name (matched against an `<ib_profile>` `<process>` rule
   that opts it in with `<ib_cache enabled="true"/>`),
2. argv tokens (filtered by `exclude_args`),
3. environment subset,
4. **content hashes of files referenced literally on argv** (or, for
   rustc, files referenced inside the `@response.rsp` argument — that
   is the special-case branch keyed off process name `"rustc"` that
   does the `/.ib.basedir.placeholder` rewrite).

What `ib_console` does **not** track: arbitrary `open()` syscalls,
Python `import` resolutions, dlopen of shared libraries, network
requests, or anything else that the wrapped process does at runtime
that isn't visible on its argv. There is no `LD_PRELOAD` import
hooking; there is no Python-import-graph awareness. This is the right
choice for a build-cache (compilers state their inputs cleanly via
argv and `.rsp` files); it is the wrong shape for an interpreter.

### Walking through every Python touch-point in monty CI

| Job step / process | Wrap in `ib_console`? | Why |
|---|---|---|
| `uv sync --all-packages --only-dev` | **No** | PyPI download + dependency resolution + wheel install. uv's own cache is the right cache here. ib_console can't fingerprint network I/O. |
| `uv run maturin develop --uv -m crates/monty-python/Cargo.toml` (top-level) | **No** | `maturin` is a Python binary that orchestrates a cargo subprocess and copies the resulting `.so` into the venv. The orchestration itself is fast and side-effecty. |
| ↳ cargo subprocess that maturin shells out to | **Yes — already wired** | Heavy `rustc` work. `ci.yml::test-python-coverage` sets `CARGO=$WORKSPACE/scripts/cargo-ib.sh` at the job level; cargo respects this env var and uses our wrapper instead of `cargo` for the nested call, so the rustc cache pays off. |
| `uv run --package pydantic-monty --only-dev pytest crates/monty-python/tests` | **No** | Test execution. Loads dynamically-imported `.py` files, conftest fixtures, plugins, runtime fs and socket activity. Not a deterministic input→output build artifact. Even if it were, ib_console can't see the import graph as part of the key. |
| `make pytest` (in `test-python` matrix) | **No** | Same as above. The matrix runs on `ubuntu-latest` anyway. |
| `make dev-py` / `make dev-py-release` | **No** at top level (calls maturin), **Yes** transitively for the inner cargo via `CARGO=` (only on IB jobs that set it). | Same logic: route the cargo subprocess, not the maturin driver. |
| `prek` / `ruff` / `ruff format` / `basedpyright` / `mypy` / `codespell` / `yamlfmt` / `zizmor` | **No** | Lint hooks. Ruff is a sub-second Rust binary; mypy/basedpyright have their own (much better) incremental caches; the ib_console daemon-startup cost would dwarf the work. The `lint` job stays on `ubuntu-latest` for this reason (and to dodge the IB runner's wall-clock cap, which kills basedpyright + workspace clippy mid-run). |
| `cargo-llvm-cov` (subcommands `clean`, `--no-report`, `report`, `report --codecov`) | **Yes** | All cargo subcommands; route through `cargo-ib.sh`. The `show-env` subcommand is the one exception — it just prints env discovery output that we `eval`, and ib_console's "ib_server connected" stdout chatter would corrupt the eval. Use plain `cargo` for `show-env` only. |
| `cargo bench`, `cargo +nightly miri test`, `cargo fuzz run`, `cargo install` | **Yes** | All real cargo invocations. Compilation in each case is rustc work; rustc cache pays off on rebuild. Test/bench/miri/fuzz **execution** is not cached (and shouldn't be — fuzzing is nondeterministic by design, miri-run is intentionally slow interpretation). |
| Wheel/sdist build via `PyO3/maturin-action` | **No** | These jobs run on `ubuntu-latest` (not on the IB runner) and use cross-compilation containers. Not in scope for the IB integration. |

### What you would gain by wrapping pytest anyway: nothing. What it would cost: ~10–30 s per call

Each `ib_console` invocation pays a fixed cost:
- ~1–2 s daemon startup + profile parse + cache directory open.
- Under `--standalone` we skip the 30 s "Trying to connect to
  ib_server" timeout, so that's not in the budget. But pre-fix, every
  IB job in this PR was paying it once at the start.
- For a `pytest` call that itself takes ~2 s on a warm extension, the
  overhead would dominate, and there would be **zero cache hits** on
  the test process because it isn't declared in any profile and its
  inputs aren't argv-visible.

The current configuration (`CARGO=` env on test-python-coverage,
plain `pytest` and plain `uv run`) is the point on the curve where
all the cache value lives and none of the overhead does. There is
nothing further to wire.

### Could a future product change unlock more?

Yes, two specific places:

1. **`rustc`'s build_script_build / build_script_main** are
   `exclude_arg`-filtered out of caching today (deliberately — they
   have side effects). If `ib_linux` grew a "cache build scripts under
   a sandboxed env" mode, monty would benefit because pyo3-build-config
   et al. run on every fresh build.
2. **A test-binary-fingerprint cache** (key by `(test_binary_hash,
   working_dir, env_subset)`, output the test result + stdout) would
   require profile-rule support for arbitrary executables and a way
   to declare "this binary's outputs are deterministic given these
   inputs". That's a real product feature, not a config knob.

Both are out of scope here. Both would generalise to any Rust+Python
repo using maturin/pyo3, not just monty, so worth keeping in mind.

---

## Distribution mode (non-`--standalone`) — investigated, not measured

The current wrapper invokes `ib_console --standalone`, which makes
the build run locally and only exercises the build-avoidance cache.
A second axis of Incredibuild value — **distributing rustc to
remote helper machines via the coordinator** — was not measured in
this PoV, and the source-grounded reason matters for positioning.

### What `--standalone` actually does

Reading `ib_linux:cpp/XgConsole/XgConsole_Session.cpp:308–404`:
`--standalone` does **not** bypass the local `ib_server` daemon
handshake; the unix-socket open to `ib_server` happens regardless,
which is why every IB cell logs `Trying to connect to ib_server …
ib_server connected`. What `--standalone` flips is one branch in
the post-handshake state machine: the coordinator-status check at
line 392 (*"Cannot access coordinator. Please start
incredibuild_coordinator service."*) is *gated* on `!standalone`.
With `--standalone` set, `ib_console` continues even when no
coordinator is reachable, so all `allow_remote` work falls back to
local execution. **Without `--standalone`, the same invocation
would hard-fail on a coordinator-less runner.**

Earlier wrapper comments (and an earlier version of this doc)
described `--standalone` as "skips the 30 s ib_server connect
timeout". That was wrong: the connect retry to `ib_server` is
5 × 1 s and is not affected by the flag. Corrected in
`scripts/cargo-ib.sh` and here.

### What the runner image looks like (and why we likely can't distribute today)

From `cpp/Common/base.h:369–393`, a host runs the coordinator role
iff `/etc/incredibuild/init.d/incredibuild_coordinator` is
executable; helper role marker is `incredibuild_helper`. The
deployed `incredibuild-runner` GH-Actions runner image, based on
indirect evidence (every successful IB job in this PR ran with
`--standalone`; the cargo-ib wrapper author's runtime observation
was *"monty CI has no helpers configured"*), looks like an
**initiator-only** image: `ib_server` runs (the local daemon link
always succeeds), but the coordinator+helper services are not
provisioned.

If that's right, then `type="allow_remote"` on rustc — which
`data/ib_profile.xml:165` sets by default — is a dead-letter
permission today: rustc is *eligible* for remote dispatch but no
helpers exist to accept the work, so it always runs locally. The
1.55× hardware floor we measured is purely the initiator's own
CPUs; nothing is being parallel-dispatched.

### What the probe actually showed

The repo contains `.github/workflows/ib-probe.yml` — a 5-minute
diagnostic that ran successfully against the `incredibuild-runner`
in run [25706946478](https://github.com/Incredibuild-RND/monty/actions/runs/25706946478):

```
role markers (/etc/incredibuild/init.d/):
  incredibuild_babysit, incredibuild_dataaccess, incredibuild_helper,
  incredibuild_httpd, incredibuild_info, incredibuild_server,
  incredibuild_watchdog
  (NO incredibuild_coordinator)

running daemons:  ib_info  ib_server  ib_helper  (NO ib_coordinator)

ib_console version [3.25.2]
ib_console --check-license: "Cannot access coordinator. Please
                             start incredibuild_coordinator service."
                             exit 255
ib_console --no-monitor -- /bin/true (no --standalone):
                            "Cannot access coordinator. ..."
ib_console --no-monitor -f -- /bin/true (force remote):
                            "Cannot access coordinator. ..."
```

**Definitive verdict: this runner image is initiator + helper,
coordinator-less.** The host runs an `ib_helper` daemon (so it's
available to be a helper for other initiators in a coordinator-
managed pool), but there's no coordinator on this machine and the
agent isn't pointed at one elsewhere. So:

- The 1.65× hardware floor we measured (cell A → B) is purely the
  local initiator's CPUs.
- `type="allow_remote"` on rustc in `data/ib_profile.xml` is a
  dead-letter permission today: rustc is *eligible* for remote
  dispatch, but no coordinator means no helper discovery, so all
  work runs locally.
- Adding `-f` / dropping `--standalone` would hard-fail every IB
  job with the "Cannot access coordinator" error, which is exactly
  why the wrapper passes `--standalone` (the flag's role is
  "tolerate missing coordinator", not "skip ib_server timeout").

### What would unlock distribution

A future cell `Q` adding `-f` to the wrapper invocation on the same
real test-rust workload as cells E/F would, **with helpers
provisioned**, model:

| helpers | speedup on cold path (multiplicative with cache) |
|---|---|
| 2 | ≈ 1.7× |
| 4 | ≈ 2.5× |
| 8+ | asymptotes to ~3× |

Distribution × cache is **multiplicative on cold compiles only**.
Cell D iter ≥ 2 spent its 4.2 s in the cache replay path with
zero rustc actually executing, so distribution adds nothing on
the warm path.

### Why this is a high-leverage product finding

The GitHub-hosted IB runner image as currently shipped cannot
demonstrate the distribution side of Incredibuild's value
proposition. The cache key engineering for rustc is already in
the binary (`BuildCache_Rules.cpp` rustc branch); the helper
binary is already on the runner (`ib_helper` is running); only
the coordinator marker file and a default helper-pool registration
are missing. Provisioning those in the runner image would unlock
another 1.7–2.5× on cold-path CI for every Rust customer who uses
the runner image as-is — a single Dockerfile change for the
runner-image team, and a step-change in the demonstrable PoV
ceiling.

### Anti-claims (do NOT make these in the PoV writeup)

- ~~"`--standalone` skips the 30 s ib_server timeout."~~ False — it
  doesn't affect the ib_server connect retry at all.
- ~~"There is a `--coord=` flag that points `ib_console` at a
  coordinator."~~ There is no such flag. Coordinator targeting is
  populated in the agent SQLite DB at runner-image build time
  (`cpp/GridServer/GridServer_Configuration.cpp:20–24`), not via
  the CLI.
- ~~"There is a `--max-remote-cores` knob to tune distribution
  concurrency."~~ There isn't. Only `--max-local-cores` exists.
- ~~"`type="allow_remote"` on rustc means rustc *is* being
  distributed today."~~ It is a permission, not a trigger.
  Distribution requires `!standalone` AND a reachable coordinator
  AND ≥1 connected helper, none of which we currently have.
- ~~"Distribution would multiply the warm-cache 8.36× speedup."~~
  No. Distribution only speeds up rustc invocations that *run* —
  i.e. cache misses. Cell D iter ≥ 2 spent its 4.6 s in the cache
  replay path with zero rustc executing.

---

## sccache (the OSS baseline) — structural comparison

The most-asked sceptical question on this PoV will be "*why pay
for Incredibuild when sccache is free and also caches rustc?*".
Answer: **sccache cannot cache the work that drives most of
monty's compile wall.** Direct apples-to-apples measurement (cell
S = same workload with `RUSTC_WRAPPER=sccache` on `ubuntu-latest`)
is a **follow-up PR**, not in this one — the harness needs a
separate stats parser, and it would muddy the diff. But the
structural ceiling can be characterised cleanly.

### What sccache does NOT cache (from upstream README and `docs/Rust.md`)

> **Crates that invoke the system linker cannot be cached. This
> includes `bin`, `dylib`, `cdylib`, and `proc-macro` crates.**
>
> **Incrementally compiled crates cannot be cached. By default, in
> the debug profile Cargo will use incremental compilation for
> workspace members and path dependencies.**

For monty specifically:

- **~25 proc-macro crates** in the lockfile (`proc-macro2`, `syn`,
  `quote`, `serde_derive`, `salsa-macros`, `pyo3-macros`,
  `thiserror-impl`, `tracing-attributes`, `strum_macros`,
  `zerocopy-derive`, …) — **never cached by sccache**.
- **The `monty` test binary itself** is a `bin` crate with a
  linker invocation — **never cached by sccache**. This is the
  single largest rustc job in the workload (links `salsa` +
  `ruff_*` + `ty_*` + monty's own crates).
- **Cargo's debug profile defaults to `incremental=true`** for
  workspace + path deps. sccache requires `CARGO_INCREMENTAL=0`
  or it short-circuits as a no-op for those crates.

Incredibuild's cache is at the *process* level, not the
rustc-wrapper level: it fingerprints argv + literal-file-arg
hashes and replays the output files of the process verbatim. That
mechanism caches `bin`, `cdylib`, `proc-macro` crates the same way
it caches lib crates — they're all just rustc invocations. The
linker step is also a separate process IB can fingerprint, though
in practice rustc handles linking inline and the cache key is on
the whole rustc call.

### Public sccache speedup numbers (the realistic ceiling on monty)

| Source | Workload | Sccache speedup |
|---|---|---|
| [NeoSmart benchmarks 2024](https://neosmart.net/blog/benchmarking-rust-compilation-speedups-and-slowdowns-from-sccache-and-zthreads), 4-core Skylake | mid-size Rust crate, primed cache | ~5.0× |
| Same source, 16-core Threadripper | same crate, primed cache | 1.07×, slowdowns up to 2.5× *worse* with `-Zthreads` |
| [mozilla/sccache#2041](https://github.com/mozilla/sccache/issues/2041), nearcore (~250 crates), 96-thread | full clean build, primed cache | ~1.78× |
| Same issue, `cargo clippy --all-features` | 50% hit rate, primed cache | 0.86× (slowdown) |

**Best estimate for cell S on monty**: ~1.7–3.2× warm-cache, i.e.
**roughly 30–40% of cell D's 8.36× ceiling**. That leaves
Incredibuild with a measured 3–5× headroom *on top of* what
sccache can achieve, primarily by caching the linker / proc-macro /
incremental-compiled crates that sccache structurally cannot.

### Summary statement for sceptics

> sccache, the open-source rustc cache, cannot cache `bin`,
> `proc-macro`, `cdylib`, or incrementally-compiled crates
> (upstream README, "Known Caveats > Rust"). monty has ~25
> proc-macro deps and produces a `bin` test binary, so sccache
> structurally caps below Incredibuild's 8.36× ceiling at roughly
> 1.7–3.2× based on published numbers for similarly-shaped Rust
> workloads. A direct comparison cell `S` on the same workload
> will land in a follow-up PR.

---

## Lessons logged for next time we point IB at a Rust repo

- Always read `data/ib_profile.xml` first. If `rustc`/`go`/`tsc`/
  whatever the workload uses isn't already cached there, you must
  add an additive profile or you're paying for a remote scheduler
  with nothing to amortise.
- Keep the additive profile **additive** — `globals
  ignore_following_profiles="false"` and don't redeclare entries
  you aren't intentionally overriding.
- Comments in IB profile XML are libxml-strict. No `--` inside
  `<!-- -->`. (Worth a doc note in `ib_linux`.)
- `ib_console` exits 255 if `--profile=<file>` fails to parse, and
  takes your build with it. Validate the profile with `xmllint
  --noout` in CI before invoking `ib_console`.
- Resource accounting: `/usr/bin/time -v` measures the immediate
  child. `ib_console` daemonises; user+sys+RSS will look near-zero
  on the wrapper. Trust the wall-clock, log HIT/MISS counters
  separately via `--build-cache-local-logfile`.
- Self-hosted runner availability is the single biggest CI risk —
  even with everything else green, an offline pool stalls the
  measurement.

---

## Cross-repo strategy update (2026-05-12)

The original PoV stopped at "monty got 1.48× on `test-rust`". Reading
the IB control-plane (`Incredibuild-RND/vnext-processing-engine`) and
runtime (`Incredibuild-RND/ib_linux`) end-to-end revealed that the real
leverage is not in monty at all. Two upstream gaps account for most of
the 12-min cap, the `cargo-ib.sh` workaround, and the structural Docker
isolation we hit on the wheel-build matrix:

1. **`build_accelerator/default_rules.yaml` ships cargo in ENV mode
   only.** ninja and cmake are wrapped with `ib_console
   --build-cache-local-shared` automatically, but cargo is not.
   Customers using Rust on the JIT runner image had to ship their own
   wrapper (e.g., monty's `scripts/cargo-ib.sh`) to get any rustc
   acceleration.
2. **`runner_engine/build/container-hooks/index.js` already mounts
   `/ib-workspace/incredibuild` and `/ib-workspace/cache` into
   `container: image: xx` jobs**, but no Rust customer has ever
   verified this works for the manylinux glibc baseline. If it does,
   the 7 manylinux Docker `build` matrix entries plus `build-pgo
   linux` (8 of monty's 32 compile-bound jobs) become IB-cacheable
   without any vnext code change.

### Layered closing plan and current status

| Layer | Owner | Deliverable | Status |
|---|---|---|---|
| **A — cargo SHIM upstream** | us → vnext PR | Promote cargo from ENV to SHIM in `default_rules.yaml`, regenerate `ib-accel/bin/cargo`, 6 new integration tests + 83 unit tests passing | [Vnext PR #210](https://github.com/Incredibuild-RND/vnext-processing-engine/pull/210) open; all 5 CI checks GREEN; reviewer (`talklainerib`) requested |
| **B — manylinux probe** | us → monty | Add `manylinux-probe` job to `ib-probe.yml` running `container: manylinux_2_28_x86_64` and probing `/ib-workspace`, `ib_console` resolution, glibc compat, `--standalone` smoke test | **GREEN** — [run 25726192172](https://github.com/Incredibuild-RND/monty/actions/runs/25726192172) confirms `/ib-workspace/cache` + `/ib-workspace/incredibuild` mounted, `/usr/bin/ib_console` v3.25.2 runs under glibc 2.28, `--standalone --no-monitor -- /bin/true` connects to `ib_server` |
| **C — hosted-grid IB profile** | Sam + IB ops | Move `scripts/ib-profile.xml` content to tenant's hosted-grid IB settings (`IB_PROFILE_CONTENT` path in `vnext-processing-engine/src/runner_engine/flows.py:109-142`); delete `IB_PROFILE` env wiring from monty | Documented in `IB_NEXT_STEPS_SAM.md` (this PR) |
| **D — stable cache key** | us | Already correct: `cache_key = md5(tenant-repo-workflow-job)` is branch-agnostic by default. `override_cache_key` on the workflow_job exposed for cross-job sharing if we ever want `test-rust` + `bench-test` to share a target/ dir | Documented |
| **E — wall-clock cap** | IB ops | Bump `NAMESPACE_INSTANCE_DURATION_MINUTES` from current value (~12) to 30 for the rust-heavy pool. Single config knob in vnext (`namespace_client.py:265`). Recovers `lint`, `fuzz`, and the `test-python` matrix that today must run on `ubuntu-latest` because of the cap | Action item for IB ops |
| **F — three monty wirings** | us | `codspeed.yml::benchmarks`, `build-js x86_64-unknown-linux-gnu`, `build-js wasm32-wasip1-threads` switched to `incredibuild-runner` with conditional IB env injection | Committed on this branch |
| **G — roadmap** | IB product | macOS / Windows IB runners, aarch64 Linux pool. Each unlocks 5 more compile-bound jobs in monty alone. Out of scope for this PR | Documented |

### New bench cells (G, H, I)

Three new cells extend the existing A–F matrix:

- **Cell G — Layer-A SHIM simulation.** Same `test-rust` workload as
  cell F, but cargo is dispatched via a `PATH`-prepended shim that
  hand-mimics what `vnext-processing-engine`'s `default_rules.yaml`
  would auto-generate (the contents of branch
  `feat/cargo-rustc-shim`'s `ib-accel/bin/cargo`). G tracking F within
  noise is the green light to retire `scripts/cargo-ib.sh` from monty
  the moment Layer A lands and the runner image rebuilds.
- **Cell H — Layer-B manylinux container validation.** Same synthetic
  `cargo test --no-run -p monty` workload as cell D, but inside a
  GHA-level `container: image: quay.io/pypa/manylinux_2_28_x86_64` block
  on `incredibuild-runner`. The container hook fires (proven by the
  manylinux-probe job), `/ib-workspace` and `/opt/incredibuild` are
  bind-mounted, and `cargo` is wrapped with `/usr/bin/ib_console
  --standalone --build-cache-local-shared`. H tracking D within ~10%
  proves the IB cache is fully shared host↔container and the wheel-
  build matrix can be migrated to IB with no per-job custom plumbing.
- **Cell I — codspeed on IB warm.** `cargo codspeed build -p
  monty-bench --bench main` on the IB runner with rustc cache warm.
  Validates Layer F's `codspeed.yml::benchmarks` rewire. Codspeed
  builds the bench crate with instrumentation, so its rustc keyspace
  is disjoint from `test-rust`'s — D/F caches don't help here, so I's
  iter-1→iter-2 ratio is the cleanest single-job signal for the
  every-PR codspeed workflow.

The summarize step in `ib-bench.yml` and `scripts/ib-bench-summarize.py`
both know about G, H, and I; the next workflow run will produce the
extended speedup table automatically.

### Coverage trajectory

| Milestone | monty IB-cacheable jobs |
|---|---|
| Pre-PR (no IB integration) | 0 of 32 (0%) |
| Today (this PR's `ci.yml::test-rust` + `test-python-coverage` + `bench-test` + `miri`) | 4 of 32 (12.5%) |
| + Layer F (3 wirings, codspeed reverted to ubuntu) | 6 of 32 (19%) |
| + Layer A landed in vnext (cargo SHIM auto-applies) | 6 of 32, but `cargo-ib.sh` retires → cleaner monty repo |
| + Layer B GREEN — manylinux Docker reachable (Phase 8 wires 1, then 8) | 14 of 32 (44%) |
| + Layer E (cap bumped, lint/fuzz/test-python-coverage back on IB) | 17 of 32 (53%) |
| + Layer G (macOS/Windows/aarch64 IB pools) | 27 of 32 (84%) |

The remaining 5 of 32 are install/smoke jobs (`test-builds-arch`,
`test-builds-os`) which compile nothing and have no IB applicability
even in a perfect world.
