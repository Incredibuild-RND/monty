#!/usr/bin/env bash
# Invoke cargo through Incredibuild's ib_console when available so heavy
# compile commands (build, test, clippy, check, llvm-cov, fuzz, etc.)
# get distributed across the IB acceleration network.
#
# On runners that don't have ib_console (e.g. ubuntu-latest carve-outs
# for cross-compile / Docker-dependent jobs), this falls through to
# plain `cargo` so the same workflow step works on both runner types.
#
# Flags chosen per Incredibuild's recommended template for CI builds:
#   --standalone               run without joining a coordinator
#   --build-cache-local-shared use the runner-local shared cache
#   --debug=build_cache        emit cache hit/miss diagnostics into the log
#   --build-cache-force        force-fill the cache even on the first run
#   --build-cache-basedir=PWD  scope the cache key to the workspace root

set -euo pipefail

# Expose IB's shared cargo target dir at the workspace's ./target/
# location BEFORE running cargo, so when ib_console redirects cargo
# output to /ib-workspace/cache/cargo-target/ the resulting binaries
# are still findable at ./target/ for downstream consumers (artifact
# uploads, maturin develop output, etc).
#
# We use a symlink instead of forcing CARGO_TARGET_DIR=$PWD/target
# because ib_console can crash when its expected target path is
# overridden from the workspace.
IB_TARGET="${IB_CARGO_TARGET_DIR:-/ib-workspace/cache/cargo-target}"
if [ -d "$IB_TARGET" ] && [ ! -e "$PWD/target" ]; then
    ln -s "$IB_TARGET" "$PWD/target"
    echo "cargo-ib: $PWD/target -> $IB_TARGET"
fi

if [ -x /usr/bin/ib_console ]; then
    exec /usr/bin/ib_console \
        --standalone \
        --build-cache-local-shared \
        --debug=build_cache \
        --build-cache-force \
        --build-cache-basedir="$PWD" \
        cargo "$@"
else
    exec cargo "$@"
fi
