#!/usr/bin/env bash
# Invoke cargo through Incredibuild's ib_console when available so heavy
# compile commands (build, test, clippy, check, llvm-cov, fuzz, etc.)
# get distributed across the IB acceleration network and their outputs
# get persisted to the build-avoidance cache.
#
# On runners that don't have ib_console (e.g. ubuntu-latest carve-outs
# for cross-compile / Docker-dependent jobs), this falls through to
# plain `cargo` so the same workflow step works on both runner types.
#
# Why a custom --profile:
# --------------------
# The default /opt/incredibuild/data/ib_profile.xml lists rustc as
#   <process filename="rustc" type="allow_remote" .../>
# with NO ib_cache entry. That means rustc gets distributed across IB
# build agents but its outputs are NOT persisted to the local build
# cache — every run recompiles every crate from scratch. The custom
# profile at scripts/ib-profile.xml adds
#   <ib_cache enabled="true" />
# to rustc so subsequent runs can replay cached compilations.
#
# ib_console flag rationale:
#   --standalone               run without joining a coordinator
#   --build-cache-local-shared use the runner-local shared cache
#   --build-cache-force        force-fill the cache even on the first run
#   --build-cache-basedir=PWD  scope the cache key to the workspace root
#                              (paths inside PWD become a placeholder so
#                              cached artifacts are portable across runs
#                              in different workspace dirs)
#   --build-cache-local-logfile=...     append hit/miss/info log lines
#   --build-cache-report-all-miss       summarize every miss reason
#   --profile=scripts/ib-profile.xml    enable rustc ib_cache (see above)
#   --debug=build_cache                 verbose build-cache diagnostics

set -euo pipefail

IB_TARGET="${IB_CARGO_TARGET_DIR:-/ib-workspace/cache/cargo-target}"
if [ -d "$IB_TARGET" ] && [ ! -e "$PWD/target" ]; then
    ln -s "$IB_TARGET" "$PWD/target"
    echo "cargo-ib: $PWD/target -> $IB_TARGET"
fi

# Per-job IB diagnostic log path. The workflow can `cat` this at the
# end of a job to surface cache hit/miss counts in the run summary.
IB_CACHE_LOG="${IB_CACHE_LOG:-${RUNNER_TEMP:-/tmp}/ib_cache.log}"
IB_PROFILE="${IB_PROFILE:-$PWD/scripts/ib-profile.xml}"
export IB_CACHE_LOG IB_PROFILE

if [ -x /usr/bin/ib_console ]; then
    # Sanity-print profile location/age on first invocation so the build
    # log makes it obvious which profile is in effect.
    if [ -f "$IB_PROFILE" ]; then
        echo "cargo-ib: using IB profile $IB_PROFILE"
    else
        echo "cargo-ib: WARNING IB profile $IB_PROFILE not found, falling back to system default (rustc will NOT be ib_cached)"
        IB_PROFILE=""
    fi

    set -- \
        --standalone \
        --build-cache-local-shared \
        --build-cache-force \
        --build-cache-basedir="$PWD" \
        --build-cache-local-logfile="$IB_CACHE_LOG" \
        --build-cache-report-all-miss \
        --debug=build_cache \
        ${IB_PROFILE:+--profile="$IB_PROFILE"} \
        cargo "$@"
    exec /usr/bin/ib_console "$@"
else
    exec cargo "$@"
fi
