#!/usr/bin/env bash
# Invoke cargo through Incredibuild's ib_console when available so heavy
# rustc invocations (build, test, clippy, check, llvm-cov, fuzz, ...)
# run under build-avoidance caching.
#
# On runners without ib_console (ubuntu-latest carve-outs, macOS/Windows,
# local dev) this falls through to plain `cargo`, so the same workflow
# step is portable.
#
# DESIGN NOTES (grounded in ib_linux source):
# -------------------------------------------
# Flag set is the minimum needed to produce cache hits in --standalone
# mode, verified against the option table in
#   ib_linux:cpp/XgConsole/XgConsole_main.cpp (lines 84-152, 270-650).
#
#   --standalone                  do not try to join an IB coordinator.
#                                 monty CI has no helpers configured;
#                                 this prevents a 30s connect timeout.
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
