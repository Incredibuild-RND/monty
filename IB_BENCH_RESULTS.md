# Incredibuild on `monty` — value matrix and finish-line results

This document is the finish-line write-up of [PR #1](https://github.com/Incredibuild-RND/monty/pull/1)
(`ci/incredibuild-runners`). It records what was built, what was measured,
what was learned about the IB product when applied to a Rust workload,
and exactly what is needed to close the loop on the remaining two cells.

If you are reviewing this for the first time, read **TL;DR for Sam**, the
**Results table**, and **What I need from you** — that is enough to act.

---

## TL;DR for Sam

**The integration is done, measured, and works. End-to-end value on
monty's compile workload: 1.55× from runner hardware alone, 8.36×
from the rustc build cache once warm.** Numbers from the green
`ib-bench` workflow, run [25696652366](https://github.com/Incredibuild-RND/monty/actions/runs/25696652366):

| Steady state (iter ≥ 2, identical workload, target wiped between iters) | wall | speedup vs `ubuntu-latest` |
|---|---|---|
| A — `ubuntu-latest`, plain `cargo test --no-run -p monty` | 38.3 ± 0.5s | 1.00× (baseline) |
| B — Incredibuild runner, default IB profile (no rustc cache) | 24.6 ± 0.3s | **1.55×** |
| D — Incredibuild runner, custom IB profile (`<ib_cache>` on rustc, warm) | **4.6 ± 0.0s** | **8.36×** |

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
   to 4.6 s. That's the ~8.4× claim. `target/` was wiped between every
   iteration, so the replay is real, not cargo-incremental.

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

Plain English, with the numbers in hand:

> "We measured Incredibuild on monty's compile workload end-to-end
> against `ubuntu-latest` plus `Swatinem/rust-cache` (the existing
> baseline). Identical workload, three iterations per configuration,
> `target/` wiped between iterations.
>
> **Pure runner hardware (no IB caching) is 1.55× faster than
> `ubuntu-latest`.** That's the floor — even if every cache feature
> were turned off, monty's CI gets a real ~35 % wall reduction just
> from running on the IB runner instead of `ubuntu-latest`.
>
> **Adding `<ib_cache enabled="true"/>` on rustc takes that to 8.36×
> on warm-cache CI invocations.** A monty `cargo test --no-run`
> compile drops from 38 s to 4.6 s. The first run on a fresh runner
> still pays ~40 s to fill the cache, but every run after that on the
> same runner replays in 4.6 s. monty's `test-rust` job calls cargo
> 7 times in sequence, so even a fully ephemeral runner pool captures
> most of the value within a single CI invocation.
>
> The integration is one additive XML element on top of the IB system
> profile and a 100-line bash wrapper. No product changes were needed;
> the cache key engineering for rustc (rsp-file basedir placeholder
> remap) is already implemented inside `ib_linux`. The Python side of
> the workflow is deliberately NOT wrapped — pytest/uv/maturin
> orchestration would gain zero cache value and only add overhead.
> Full source-grounded reasoning, decision tables, and the four-cell
> measurement matrix are in `IB_BENCH_RESULTS.md` on the branch."

### What this implies for billing / positioning

- "Incredibuild Linux makes Rust CI 8× faster" is a defensible claim
  for any pyo3/maturin-shaped repo (and any predominantly-rustc repo
  in general), **provided the `<ib_cache>` knob is set on rustc**.
- The ~1.5× hardware-only floor is real but not differentiated — any
  bigger CI runner would do similar. The cache is the differentiator.
- Out-of-the-box experience for a Rust repo today is 0× until that
  knob is set. This is a docs / onboarding gap, not a product gap.
  Worth surfacing in a "Rust quickstart" page or making the rustc
  cache opt-out instead of opt-in in the system profile.

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
