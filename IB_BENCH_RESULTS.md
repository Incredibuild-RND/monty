# Incredibuild on `monty` — value matrix and finish-line results

This document is the finish-line write-up of [PR #1](https://github.com/Incredibuild-RND/monty/pull/1)
(`ci/incredibuild-runners`). It records what was built, what was measured,
what was learned about the IB product when applied to a Rust workload,
and exactly what is needed to close the loop on the remaining two cells.

If you are reviewing this for the first time, read **TL;DR for Sam**, the
**Results table**, and **What I need from you** — that is enough to act.

---

## TL;DR for Sam

1. Out-of-the-box, Incredibuild gives `monty` **near-zero caching value**.
   This is by design: the system default profile that ships with
   `ib_linux` (`data/ib_profile.xml`) declares `rustc` as
   `type="allow_remote"` with **no `<ib_cache>` element**. C/C++
   compilers are cached, `rustc` is not. `monty` is ~100% `rustc`, so
   the default profile cannot move the needle on this repo.

2. The fix is one XML knob: `scripts/ib-profile.xml` adds
   `<ib_cache enabled="true"/>` on `rustc` and is loaded additively
   (`ignore_following_profiles="false"`). The wrapper passes that
   profile plus the minimal flag set verified against
   `ib_linux:cpp/XgConsole/XgConsole_main.cpp`:
   `--standalone --build-cache-local-shared --build-cache-basedir=$PWD
   --build-cache-local-logfile=… --build-cache-report-all-miss
   --no-monitor [--profile=…]`.
   The basedir placeholder remap that makes `rustc` `.rsp` cache keys
   workspace-portable is already implemented in
   `ib_linux:cpp/BuildCache/BuildCache_Rules.cpp` and activates the
   moment `<ib_cache>` is on for `rustc`.

3. **Hardware-only value already proven** (cells A and B below): on
   identical workload (`cargo test --no-run -p monty`, target wiped
   between iterations), the IB runner without IB caching is **~1.6× faster**
   than `ubuntu-latest`. So the runner pool itself is worth keeping
   even before any cache work lands.

4. **Cache value** (cells C and D) is **not yet measured** — every
   measurement attempt has been killed by the IB self-hosted runner
   pool not staying online. During the most recent run we observed
   `42 total / 0 online` for 50+ continuous minutes after a brief
   window where one runner came up to handle one cell and then went
   away. **This is an infra issue on the IB runner pool, not a `monty`
   issue.**

5. To finish the experiment I need (a) the runner pool stable for ~20
   minutes and (b) one button press: `gh workflow run ib-bench.yml -R
   Incredibuild-RND/monty -r ci/incredibuild-runners`. Everything
   else (workflow, scripts, summarizer, profile fix) is in place and
   green.

6. **Python jobs are deliberately NOT wrapped in `ib_console`** —
   `pytest`, `uv run`, the top-level `maturin develop` driver, and
   `prek`/`ruff`/`mypy` get zero cache value and would only pay
   ib_console's startup cost. The cargo subprocess that `maturin`
   shells out to *is* wrapped (via `CARGO=$WORKSPACE/scripts/cargo-ib.sh`
   at the job env) so the rustc cache pays off for the heavy compile.
   Full reasoning grounded in `ib_linux:cpp/BuildCache/BuildCache_Rules.cpp`
   in the new "Python and `ib_console`" section below.

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

## Results table

`cargo test --no-run -p monty`, target/ wiped between iterations,
3 iterations per cell. Wall-clock is what matters for "value to
developer / CI"; user+sys time on the IB cells is artifactually low
because `ib_console` daemonises and the `/usr/bin/time` accounting on
the wrapper script doesn't follow the detached child where the real
work happens.

| Cell | Runner            | IB? | rustc cache | Iter 1 (s) | Iter 2 (s) | Iter 3 (s) | Mean | vs A     |
|------|-------------------|-----|-------------|------------|------------|------------|------|----------|
| A    | `ubuntu-latest`   | no  | n/a         | 39.55      | 38.53      | 38.46      | 38.85 | 1.00×   |
| B    | `incredibuild`    | yes | **off**     | 44.19      | 25.22      | 23.81      | (24.5 steady) | **~1.59× faster than A** at steady state |
| C    | `incredibuild`    | yes | cold (1×)   | not run    | —          | —          | —    | blocked on runner pool |
| D    | `incredibuild`    | yes | warm (3×)   | not run    | not run    | not run    | —    | blocked on runner pool |

Cell A iter 1 has Swatinem rust-cache populated, so all three iters
are pure compile and tightly clustered.

Cell B iter 1 includes ~16s of `Updating crates.io index` + git
repository fetches + crate downloads (the IB runner has no cargo
registry warmup). Iters 2 and 3 are pure compile from a wiped
`target/` and are the apples-to-apples comparison vs cell A. **24s
vs 38s = ~1.6× speedup from the IB runner hardware alone.**
HIT=0 / MISS=0 in cell B is expected: `IB_NO_CACHE=1` skips
`--profile=`, so the system default profile applies and `rustc` is
not cached. C/C++ compilation is cacheable under the default
profile, but `monty`'s graph has essentially zero C work.

Cells C and D would have shown the value of `<ib_cache enabled="true"/>`
on `rustc`. The expected pattern (based on the source in
`ib_linux:cpp/BuildCache/BuildCache_BuildCache.cpp` and the
`Manifest::init` basedir-placeholder logic for `.rsp` files):

- C: one cold compile populates `/etc/incredibuild/cache/build_cache/shared/`.
  Wall ~ B's first iter; HIT=0, MISS=N (N = number of `rustc`
  invocations in the graph).
- D: three warm compiles read from that cache. HIT≈MISS_of_C, MISS≈0,
  and wall should drop dramatically (the linking step on monty is
  small, the long pole is `rustc`, which is now replayed from the
  cache by `Replay::run` in `BuildCache_Replay.cpp`).

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

## What I need from you (Sam) to land cells C and D

Pick whichever path is easier on your side:

**Option 1 — fix the runner pool, I run the bench.**
1. Bring the `incredibuild-runner` pool back to a steady online
   state (today during the experiment we saw `42 total / 0 online`
   for 50+ minutes; before that, one runner came up briefly,
   handled one job, and went offline again).
2. Ping me, I'll run:
   ```
   gh workflow run ib-bench.yml \
     -R Incredibuild-RND/monty \
     -r ci/incredibuild-runners
   ```
   The summarize job posts a markdown table to the run summary;
   I'll paste it back here and into the PR.

**Option 2 — you run the bench.**
Same one-liner, same branch (`ci/incredibuild-runners`), same
artifact (`bench-cell-D/D.csv`). The `summarize` job does the
arithmetic. Three iterations × 4 cells, total wall ≈ 15 min once
runners are alive.

Either way, end state is the full A/B/C/D row of the table above.

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

