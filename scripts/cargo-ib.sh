#!/usr/bin/env bash
# Invoke cargo through Incredibuild's ib_console when available so heavy
# rustc invocations (build, test, clippy, check, llvm-cov, fuzz, ...)
# run under build-avoidance caching.
#
# On runners without ib_console (ubuntu-latest carve-outs, macOS/Windows,
# local dev) this falls through to plain `cargo`, so the same workflow
# step is portable.
#
# SCOPE (read this before adding new call sites):
# -----------------------------------------------
# This wrapper invokes ONLY `cargo`. The cache it produces only pays
# off for processes IB knows how to fingerprint via ib-profile.xml —
# in monty that means rustc (we add it) and the C/C++ compilers
# inherited from the system default. Do NOT pipe pytest, uv,
# maturin's top-level driver, ruff, mypy, or python through this
# wrapper:
#   * `pytest`, `python`, `uv run` — interpreters whose work is
#     dynamic .py imports and runtime side effects. ib_console hashes
#     argv + literal-file-args, not the import graph or runtime fs
#     reads, so the cache key would be wrong (or trivially miss).
#   * `maturin develop` (the foreground driver) — it's a Python
#     binary that orchestrates a cargo subprocess and copies the
#     resulting .so into the venv. The cargo subprocess is the part
#     worth caching; it gets routed automatically by setting
#     `CARGO=$WORKSPACE/scripts/cargo-ib.sh` at the job level (see
#     ci.yml::test-python-coverage). Wrapping the maturin driver
#     itself would only add ib_console's daemon-startup overhead.
#   * `ruff`, `mypy`, `basedpyright`, `prek` — fast linters with
#     their own incremental caches. Wrapping them costs more than
#     it saves.
# Rule of thumb: if the heavy work is rustc, route through this
# script. If the heavy work is anything else, run it directly.
#
# DESIGN NOTES (grounded in ib_linux source):
# -------------------------------------------
# Flag set is the minimum needed to produce cache hits in --standalone
# mode, verified against the option table in
#   ib_linux:cpp/XgConsole/XgConsole_main.cpp (lines 84-152, 270-650).
#
#   --standalone                  tolerate a missing/unreachable
#                                 IB coordinator. The local ib_server
#                                 unix-socket handshake still happens
#                                 either way (XgConsole_Session.cpp
#                                 :224-237). What --standalone flips
#                                 is the post-handshake check at
#                                 line 392 (Session::openSession's
#                                 "Cannot access coordinator. Please
#                                 start incredibuild_coordinator
#                                 service." gate, which is gated on
#                                 !standalone). Without --standalone,
#                                 the same invocation hard-fails on
#                                 a coordinator-less runner.
#                                 The incredibuild-runner GHA image
#                                 ships initiator-only (no helpers
#                                 configured); --standalone makes
#                                 ib_console run all allow_remote
#                                 work locally. Run ib-probe.yml to
#                                 confirm and revisit if helpers
#                                 become available.
#   --build-cache-local-shared    use the shared local cache at
#                                 /etc/incredibuild/cache/build_cache/shared/
#                                 (path from BuildCache_defines.h).
#   --build-cache-basedir=$PWD    rewrite $PWD -> placeholder in the
#                                 cache key, so artifacts are portable
#                                 across runs in different workspace
#                                 dirs (Manifest::init in
#                                 BuildCache_BuildCache.cpp:198).
#   --build-cache-local-logfile   per-job hit/miss/info log; absolute
#                                 path required (XgConsole_main.cpp:482).
#   --build-cache-report-all-miss list every cache miss with the reason
#                                 (BuildCache_HitMiss.cpp); useful for
#                                 attribution in CI logs.
#   --no-monitor                  monty CI doesn't use the IB build
#                                 monitor; saves startup overhead.
#   --profile=<file>              additive profile loaded after the
#                                 system default. monty's
#                                 scripts/ib-profile.xml just adds
#                                 <ib_cache enabled="true"/> on rustc.
#   --debug=build_cache           verbose cache diagnostics (IB_DEBUG=1
#                                 only — chatty otherwise).
#
# Flags deliberately NOT passed:
#   --build-cache-force           does not exist in this binary
#                                 (verified absent from option table).
#   --avoid-* aliases             same flags as --build-cache-local-*,
#                                 use the canonical name.
#   --force-remote                no helpers in --standalone, no-op.
#   --build-cache-service=URL     no remote cache server stood up yet;
#                                 future work.
#
# Caller contract:
#   IB_CACHE_LOG          absolute path of the cache logfile. ib-prep.sh
#                         sets a per-job default under /etc/incredibuild/log/.
#   IB_PROFILE            path to additive profile XML. ib-prep.sh sets it.
#   IB_DEBUG              if non-empty, pass --debug=build_cache.
#   IB_NO_CACHE           if non-empty, skip --profile (run with the
#                         system default profile, i.e. rustc NOT cached).
#                         Used by the measurement workflow's "B — IB no
#                         rustc cache" cell.
#   IB_MAX_LOCAL_CORES    if non-empty, pass --max-local-cores=<N> to
#                         throttle local rustc concurrency. Used in
#                         ci.yml to keep concurrent IB jobs on the same
#                         shared runner from each spawning nproc rustc
#                         instances and tripping the runner's wall-clock
#                         cap.
#   IB_PREVENT_OVERLOAD   if non-empty, pass --prevent-initiator-overload
#                         (a no-op under --standalone since there are no
#                         remote helpers to push to, but harmless and
#                         future-proofs for when a coordinator is added).

set -euo pipefail

if [ ! -x /usr/bin/ib_console ]; then
    exec cargo "$@"
fi

LOG="${IB_CACHE_LOG:-/etc/incredibuild/log/ib_cache_${GITHUB_JOB:-local}_${GITHUB_RUN_ID:-0}.log}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

PROFILE_FLAG=()
if [ -z "${IB_NO_CACHE:-}" ] && [ -n "${IB_PROFILE:-}" ] && [ -f "${IB_PROFILE}" ]; then
    PROFILE_FLAG=(--profile="${IB_PROFILE}")
fi

DEBUG_FLAG=()
if [ -n "${IB_DEBUG:-}" ]; then
    DEBUG_FLAG=(--debug=build_cache)
fi

CAP_FLAGS=()
if [ -n "${IB_MAX_LOCAL_CORES:-}" ]; then
    CAP_FLAGS+=(--max-local-cores="${IB_MAX_LOCAL_CORES}")
fi
if [ -n "${IB_PREVENT_OVERLOAD:-}" ]; then
    CAP_FLAGS+=(--prevent-initiator-overload)
fi

exec /usr/bin/ib_console \
    --standalone \
    --build-cache-local-shared \
    --build-cache-basedir="$PWD" \
    --build-cache-local-logfile="$LOG" \
    --build-cache-report-all-miss \
    --no-monitor \
    "${CAP_FLAGS[@]}" \
    "${PROFILE_FLAG[@]}" \
    "${DEBUG_FLAG[@]}" \
    cargo "$@"
