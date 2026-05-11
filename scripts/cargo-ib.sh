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
# cache (under /etc/incredibuild/cache/build_cache/shared/). The
# custom profile at scripts/ib-profile.xml adds
#   <ib_cache enabled="true" />
# to rustc so subsequent runs can replay cached compilations.
#
# ib_console flags actually accepted by this binary (verified in
# ib_linux:cpp/XgConsole/XgConsole_main.cpp option table):
#   --standalone                 run without joining a coordinator
#   --build-cache-local-shared   use the local shared cache at
#                                /etc/incredibuild/cache/build_cache/shared/
#   --build-cache-basedir=PWD    scope the cache key to the workspace
#                                root (paths inside PWD become a
#                                placeholder so cached artifacts are
#                                portable across runs in different
#                                workspace dirs)
#   --build-cache-local-logfile  append hit/miss/info log lines (path
#                                must be absolute)
#   --build-cache-report-all-miss
#                                summarize every miss reason
#   --profile=...                additional profile file (loaded on
#                                top of /opt/incredibuild/data/ib_profile.xml)
#   --debug=build_cache          verbose build-cache diagnostics
#
# Flags that do NOT exist in this version (do not pass them, they are
# silently ignored): --build-cache-force.

set -euo pipefail

# Expose IB's shared cargo target dir at the workspace's ./target/
# location BEFORE running cargo. If a prior cargo run on this runner
# created the IB target dir, symlink to it so subsequent builds
# benefit (without breaking jobs that already have a target/ dir from
# Swatinem/rust-cache).
IB_TARGET="${IB_CARGO_TARGET_DIR:-/ib-workspace/cache/cargo-target}"
if [ -d "$IB_TARGET" ] && [ ! -e "$PWD/target" ]; then
    ln -s "$IB_TARGET" "$PWD/target"
    echo "cargo-ib: $PWD/target -> $IB_TARGET"
fi

# Per-job IB diagnostic log path. Must be ABSOLUTE per ib_console
# validation. ib_console may run intercepted processes in a chroot /
# namespace (tools/deployment/ib_console_chroot, ib_console_ns), so a
# path under RUNNER_TEMP may not be visible inside the sandbox. We
# still try, and the workflow's post-flight step also inspects the
# canonical cache dir at /etc/incredibuild/cache/build_cache/shared/.
IB_CACHE_LOG="${IB_CACHE_LOG:-${RUNNER_TEMP:-/tmp}/ib_cache.log}"
IB_PROFILE="${IB_PROFILE:-$PWD/scripts/ib-profile.xml}"
export IB_CACHE_LOG IB_PROFILE

if [ -x /usr/bin/ib_console ]; then
    # EXPERIMENT B: force default IB profile (no rustc ib_cache)
    echo "cargo-ib: EXP-B — using DEFAULT ib_profile (rustc NOT cached)"
    IB_PROFILE=""

    set -- \
        --standalone \
        --build-cache-local-shared \
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
