# IB integration — mechanical cleanup spec for Phases 5 / 6 / 7

This is the executable companion to [`IB_NEXT_STEPS_SAM.md`](./IB_NEXT_STEPS_SAM.md).
It records the **exact** edits each post-merge phase needs, with concrete
file paths, line ranges, and search-and-replace patterns. Each phase is
gated on an external dependency; once that clears, the corresponding
section here is a paint-by-numbers PR.

The point of this doc is to remove "what does the cleanup look like?"
from the critical path. When IB ops emails Sam saying "Layer C done"
or when a JIT runner image rebuild lands, the right person can open
the cleanup PR in 10 minutes by following the diff below — they don't
need to re-derive the change set.

**Current correction (2026-05-13)**: vnext PR #210 has shipped and the
runner image now handles standard cargo subcommands out-of-the-box.
[vnext PR #215](https://github.com/Incredibuild-RND/vnext-processing-engine/pull/215)
is open and green with first-class coverage for the remaining
extension/toolchain forms (`cargo llvm-cov`, `cargo codspeed build`,
and `cargo +nightly miri test`). Do not delete `scripts/cargo-ib.sh`
until PR #215 is merged, the runner image is rebuilt/deployed, and
monty's `test-rust`, `miri`, and codspeed-build bench cells are green
without the bridge.

---

## Phase 5 — Delete `scripts/cargo-ib.sh` and all `CARGO=…cargo-ib.sh` wirings

### Gate
1. [`Vnext PR #210`](https://github.com/Incredibuild-RND/vnext-processing-engine/pull/210)
   merged to `Incredibuild-RND/vnext-processing-engine:main`.
2. [`Vnext PR #215`](https://github.com/Incredibuild-RND/vnext-processing-engine/pull/215)
   merged to `Incredibuild-RND/vnext-processing-engine:main`.
3. The IB build team rebuilds the JIT-runner image so it carries the
   regenerated shim at `/ib-workspace/incredibuild/ib-accel/bin/cargo`
   (or `/opt/ib-accel/bin/cargo` on older variants).
4. The next dispatch of `ib-probe.yml` on `ci/incredibuild-runners`
   reports `FOUND Layer-A cargo shim:` in its `Layer-A cargo SHIM
   deploy check (Phase 4)` log group and the generated shim includes
   `llvm-cov`, `codspeed`, and `miri` cases.
5. Cell G in `ib-bench.yml` (the `cargo` shim simulation) is within
   ~10% of cell F's wall time — confirms the auto-generated shim
   matches the hand-rolled `scripts/cargo-ib.sh` behavior.

When all four are true: open the PR below.

### Files to delete

```bash
rm scripts/cargo-ib.sh
```

### Files to edit

#### `.github/workflows/ci.yml`

Run once across every `./scripts/cargo-ib.sh` reference in the file:

```bash
# In each `- run: ./scripts/cargo-ib.sh <cargo-args>` line, strip the
# `./scripts/cargo-ib.sh ` prefix so the line becomes
# `- run: cargo <cargo-args>`. The runner image's auto-generated
# /ib-workspace/incredibuild/ib-accel/bin/cargo handles ib_console
# wrapping transparently via $PATH.
sed -i 's|\./scripts/cargo-ib\.sh |cargo |g' .github/workflows/ci.yml
```

Affected lines (verify after the sed):
- `test-rust` job, lines 144–160 (10 cargo llvm-cov calls).
- `test-python-coverage` job, lines 249, 252, 253 (3 cargo llvm-cov calls).
- `bench-test` job, line 436 (cargo bench).
- `miri` job, line 480 (cargo +nightly miri test).

Then remove the `CARGO=…cargo-ib.sh` env var from `test-python-coverage`:

```yaml
# DELETE these lines from test-python-coverage's env: block:
      # Route maturin's INTERNAL cargo invocation through ib_console
      # by the cargo `CARGO=<path>` env-var contract (cargo respects
      # this and uses the indicated binary instead of `cargo`).
      #
      # Why only cargo, and not pytest / uv / maturin itself?
      #   - The heavy work in this job is rustc (cargo build of the
      #     pyo3 extension via maturin). Cached via the rustc entry
      #     in scripts/ib-profile.xml.
      #   - pytest, uv run, and maturin's top-level driver are
      #     Python interpreters orchestrating dynamic .py imports
      #     and venv copying. ib_console's cache key is
      #     argv + literal-file-args, not the import graph; wrapping
      #     these would never produce a meaningful cache hit and
      #     would only add ib_console's startup overhead per call.
      # See scripts/cargo-ib.sh top comment for the full rule.
      CARGO: ${{ github.workspace }}/scripts/cargo-ib.sh
```

The comment block goes too — it's a tutorial about a contract that
no longer needs explaining (the runner image owns it).

Then remove the `CARGO=…cargo-ib.sh` line from `build-js`'s IB-env
step (currently lines 893–900):

```yaml
# BEFORE:
      - name: IB env (Linux IB only)
        if: matrix.settings.host == 'incredibuild-runner'
        run: |
          {
            echo "CARGO=$(pwd)/scripts/cargo-ib.sh"
            echo "IB_MAX_LOCAL_CORES=4"
            echo "IB_PREVENT_OVERLOAD=1"
          } >> "$GITHUB_ENV"

# AFTER:
      - name: IB env (Linux IB only)
        if: matrix.settings.host == 'incredibuild-runner'
        run: |
          {
            echo "IB_MAX_LOCAL_CORES=4"
            echo "IB_PREVENT_OVERLOAD=1"
          } >> "$GITHUB_ENV"
```

Then update the comment 4 lines above to drop the napi-rs `$CARGO`
reference:

```yaml
# BEFORE:
      # IB pre-flight + env: only on incredibuild-runner. napi-rs
      # (invoked by `npm run build:napi`) honors $CARGO and routes
      # its internal cargo subcommand through our wrapper, which
      # invokes /usr/bin/ib_console for build-cache.

# AFTER:
      # IB pre-flight + env: only on incredibuild-runner. The runner
      # image's auto-generated /ib-workspace/incredibuild/ib-accel/bin/cargo
      # SHIM (see vnext-processing-engine#210) wraps cargo invocations
      # with /usr/bin/ib_console for build-cache automatically — no
      # per-job CARGO env needed.
```

#### `.github/workflows/codspeed.yml`

The `setarch personality` blocker forced this back to `ubuntu-latest`,
so codspeed.yml does NOT reference `cargo-ib.sh` today and Phase 5
does not touch it. Phase 9 (codspeed recovery) is what re-engages it.

#### `.github/workflows/ib-bench.yml`

Cells F and I currently dispatch via `./scripts/cargo-ib.sh`. Replace
both with bare `cargo`:

```yaml
# Cell F (line 412):
# BEFORE:  CARGO_BIN: ./scripts/cargo-ib.sh
# AFTER:   CARGO_BIN: cargo

# Cell I (line 581):
# BEFORE:  CARGO_BIN: ./scripts/cargo-ib.sh
# AFTER:   CARGO_BIN: cargo

# Cell I top-of-job env (line 544):
# DELETE:  CARGO: ${{ github.workspace }}/scripts/cargo-ib.sh
```

Cell G stays untouched — it's the simulation cell that demonstrates
exactly this transition. After Phase 5 lands, Cell G's PATH-prepended
shim becomes redundant with the runner's image-side shim and Cell G
can be marked `continue-on-error: true` (or removed entirely) in
Phase 10.

Path filter at the top of the workflow:

```yaml
# BEFORE:
  push:
    branches:
      - ci/incredibuild-runners
    paths:
      - .github/workflows/ib-bench.yml
      - scripts/ib-bench-run.sh
      - scripts/ib-bench-summarize.py
      - scripts/cargo-ib.sh
      - scripts/ib-profile.xml

# AFTER:
  push:
    branches:
      - ci/incredibuild-runners
    paths:
      - .github/workflows/ib-bench.yml
      - scripts/ib-bench-run.sh
      - scripts/ib-bench-summarize.py
      - scripts/ib-profile.xml   # ← still here until Phase 6
```

#### `scripts/ib-bench-run.sh`

Remove the auto-fallback to `./scripts/cargo-ib.sh` on IB hosts:

```bash
# BEFORE (around line 54):
    CARGO_RUNNER=(./scripts/cargo-ib.sh)

# AFTER:
    CARGO_RUNNER=(cargo)
```

Verify the surrounding `if` branch — once both branches collapse to
`cargo`, simplify the conditional.

### Verification before merging Phase 5 PR

1. Push to a branch off `ci/incredibuild-runners`.
2. Trigger `ib-bench.yml` manually. Cell F (now using bare `cargo`)
   should match the prior Cell F wall time within ~10%. If it
   regresses, the runner image either (a) hasn't been rebuilt, or
   (b) has the wrong subcommand whitelist — check Cell G logs to
   pinpoint.
3. Trigger `ib-probe.yml` — the new `Layer-A cargo SHIM deploy check`
   group must report `FOUND`.
4. Run a real `ci.yml` cycle on the branch (label the PR `Full Build`
   or push-trigger). `test-rust` and `test-python-coverage` should
   stay within ~5% of pre-Phase-5 wall time.

### Commit message

```
chore(ib): retire scripts/cargo-ib.sh — runner image now ships cargo SHIM

vnext-processing-engine#210 and #215 (cargo SHIM upstream) merged and
the JIT runner image was rebuilt on <date>. The auto-generated
/ib-workspace/incredibuild/ib-accel/bin/cargo wraps cargo subcommands
with /usr/bin/ib_console transparently via $PATH, replacing monty's
hand-rolled wrapper.

Removed:
  - scripts/cargo-ib.sh
  - All ./scripts/cargo-ib.sh prefixes in ci.yml (test-rust,
    test-python-coverage, bench-test, miri)
  - CARGO=$(pwd)/scripts/cargo-ib.sh env wirings (test-python-coverage,
    build-js IB-env step)
  - CARGO_BIN: ./scripts/cargo-ib.sh from ib-bench.yml cells F and I
  - cargo-ib.sh fallback in scripts/ib-bench-run.sh
  - scripts/cargo-ib.sh from the ib-bench.yml push-path filter

Verification: cell F (bare cargo) wall time matched prior cell F
within X%, cell G (PATH shim simulation) is now redundant with the
runner image's shim and continues to pass.
```

---

## Phase 6 — Delete `scripts/ib-profile.xml` and `IB_PROFILE` wirings

### Gate
IB ops confirms the contents of `scripts/ib-profile.xml` are pasted
into the hosted-grid `IB_PROFILE_CONTENT` field for the
`Incredibuild-RND/monty` tenant, and the next ib-probe run shows the
profile is being applied (look for `Loaded profile from
/ib-workspace/incredibuild/ib_profile.xml` in `ib_console
--full-version --diagnose` output).

### Files to delete

```bash
rm scripts/ib-profile.xml
```

### Files to edit

#### `scripts/ib-prep.sh`

Find the `IB_PROFILE` export block:

```bash
# BEFORE:
echo "IB_PROFILE=$PWD/scripts/ib-profile.xml" >> "$GITHUB_ENV"

# AFTER (delete the line; the runner image now sources the profile
# via vnext-processing-engine's entrypoint.sh:47-51).
```

If the script has surrounding diagnostic prints about IB_PROFILE,
keep them but rewrite to read from the runner-injected location:

```bash
# REPLACE the diagnostic block with:
PROFILE_PATH=/ib-workspace/incredibuild/ib_profile.xml
if [ -f "$PROFILE_PATH" ]; then
    echo "IB profile (tenant-injected): $PROFILE_PATH"
    head -10 "$PROFILE_PATH"
else
    echo "no tenant IB profile present at $PROFILE_PATH"
fi
```

#### `.github/workflows/ib-bench.yml`

Delete `IB_PROFILE: ${{ github.workspace }}/scripts/ib-profile.xml`
from cells F (line 416), G (line 519), I (line 582), and H (line 694
if added in Phase 8).

Path filter — drop `scripts/ib-profile.xml`:

```yaml
# BEFORE:
    paths:
      - .github/workflows/ib-bench.yml
      - scripts/ib-bench-run.sh
      - scripts/ib-bench-summarize.py
      - scripts/ib-profile.xml

# AFTER:
    paths:
      - .github/workflows/ib-bench.yml
      - scripts/ib-bench-run.sh
      - scripts/ib-bench-summarize.py
```

#### `.github/workflows/ci.yml`

Verify with `rg IB_PROFILE`. If any per-job env block sets
`IB_PROFILE`, delete those lines too.

### Verification

Trigger `ib-bench.yml`. Cells C and D (which depend on the rustc
caching profile) should show the same hit/miss pattern as before. If
hits drop to zero, the tenant config didn't apply — escalate back to
IB ops with the run URL.

---

## Phase 7 — Re-route `lint`, `fuzz`, `test-python-coverage` back to `incredibuild-runner`

### Gate
IB ops confirms `NAMESPACE_INSTANCE_DURATION_MINUTES` for the pool
serving `Incredibuild-RND/monty` is bumped to 30 minutes (or a
dedicated `rust-heavy` label/pool with that cap is created).

### Files to edit

#### `.github/workflows/ci.yml`

Three jobs to flip:

1. **`lint`** (currently `runs-on: ubuntu-latest` per the wall-clock
   revert). Switch to `incredibuild-runner` and add the conditional
   IB env injection pattern used by `build-js` matrix entries.

2. **`fuzz tokens_input_panic`** (line ~488 of `fuzz` matrix
   strategy). Add this single matrix entry as `runs-on:
   incredibuild-runner`; leave the other fuzz targets on
   `ubuntu-latest` if they're not compile-bound.

3. **`test-python` matrix** (line ~309). Switch the fastest entry
   (`python-version: 3.14`) first to validate; then expand if it
   stays under the (bumped) cap.

For each, follow the pattern already in
`test-rust`/`test-python-coverage`:

```yaml
runs-on: incredibuild-runner
timeout-minutes: 25  # under the new 30-min cap with margin
env:
  CARGO_HOME: ${{ github.workspace }}/.cargo
  CARGO_TARGET_DIR: ${{ github.workspace }}/target
  IB_MAX_LOCAL_CORES: '8'  # tune by job profile
  LANG: C.UTF-8
  LC_ALL: C.UTF-8
  PYTHONUTF8: '1'
steps:
  - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
  - name: IB pre-flight
    run: ./scripts/ib-prep.sh
  ...
  - name: IB cache stats
    if: always()
    run: ./scripts/ib-stats.sh
```

### Verification

Each rewired job must finish under 25 min (5 min headroom under the
new cap) for at least 3 consecutive runs. If any flake at the cap,
the cap bump didn't apply or the job needs `IB_MAX_LOCAL_CORES`
tuning — collect a flame profile via the IB summary log groups and
file with IB ops.

---

## Phase 8 — Migrate one wheel-build matrix entry to `incredibuild-runner` + `container:`

### Gate
Cell H of `ib-bench.yml` reports `H_warm / D_warm` within ~10%
(green light: container vs host adds no overhead, IB cache fully
shared). Currently dispatched as run 25727104334; check
[ib-bench.yml workflow runs](https://github.com/Incredibuild-RND/monty/actions/workflows/ib-bench.yml).

### Files to edit

#### `.github/workflows/ci.yml`, `build` job

Pick one matrix entry to demo first (suggested: `linux x86_64-musl`
because it's the only Linux entry that runs natively, not via QEMU):

```yaml
# BEFORE (line 605-607):
        - os: linux
          target: x86_64
          manylinux: musllinux_1_1

# AFTER (split into two-tier conditional via `host`):
        - os: linux
          target: x86_64
          manylinux: musllinux_1_1
          host: incredibuild-runner
          container: quay.io/pypa/musllinux_1_1_x86_64@sha256:<digest>
```

Then in `runs-on:` (line 619), add the IB-runner branch:

```yaml
runs-on: ${{ matrix.host || ((matrix.os == 'linux' && 'ubuntu-latest') || (matrix.os == 'macos' && 'macos-latest') || (matrix.os == 'windows' && 'windows-latest')) }}
```

And add a top-of-job container directive that's conditional:

```yaml
container: ${{ matrix.container || '' }}
```

(GHA accepts an empty `container:` value as "no container".)

Inside the steps, replace `PyO3/maturin-action` (which uses its own
child docker that bypasses the IB hook) with a direct `maturin
build` call when `matrix.host == 'incredibuild-runner'`.

### Verification

Compare wheel-build wall time on the migrated matrix entry between
the previous (ubuntu-latest + maturin-action) and new (incredibuild-
runner + container:). Expect ≥1.3× speedup for warm runs (post-cell-D
warm cache state). If not, debug via `IB cache stats` step output.

After validation, expand the same pattern to the remaining 7 Linux
entries (`aarch64`, `i686`, `armv7`, `ppc64le`, `s390x`,
`x86_64-unknown-linux-gnu`, `aarch64-musl`) plus `build-pgo` linux.

---

## Phase 10 — Final aggregation

### Gate
Phases 5, 6, 7 (and optionally 8) all merged.

### Actions
1. Re-run `ib-bench.yml` end-to-end — produces the post-cleanup
   speedup table covering cells A–I.
2. Update `IB_BENCH_RESULTS.md`'s "Coverage trajectory" with measured
   post-phase numbers (replace the projected percentages with
   measured ones).
3. Convert `IB_NEXT_STEPS_SAM.md` from an action-item document into a
   roadmap-only document (delete the "What I need from Sam" section,
   keep Layer G).
4. Delete this `IB_CLEANUP_SPEC.md` file — it has no further purpose
   once all phases land.
5. Post a close-out comment on monty PR #1 with the final numbers
   and any remaining IB-product roadmap items.
