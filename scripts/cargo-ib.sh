#!/usr/bin/env bash
# Bridge cargo forms the runner-image shim cannot safely classify yet.
#
# The vnext cargo shim accelerates normal built-in subcommands such as
# `cargo build`, `cargo test`, and `cargo bench`. monty also uses cargo
# extension/toolchain forms (`cargo llvm-cov ...`, `cargo +nightly miri ...`)
# where the first argv token is not the real compile-driving subcommand.
# Keep those explicit call sites under ib_console until the upstream shim
# learns to parse cargo toolchain prefixes and selected extension commands.

set -euo pipefail

if [ ! -x /usr/bin/ib_console ] || [ -n "${IB_CONSOLE_SKIP:-}" ]; then
    exec cargo "$@"
fi

if [ -n "${IB_CONSOLE_ARGS:-}" ]; then
    _ib_console_args_expanded="${IB_CONSOLE_ARGS//\$PWD/$PWD}"
    # shellcheck disable=SC2206  # same split contract as the runner shim
    _ib_console_args=($_ib_console_args_expanded)
else
    _ib_console_args=(
        --standalone
        --build-cache-local-shared
        --build-cache-basedir="$PWD"
        --build-cache-report-all-miss
        --no-monitor
    )
    if [ -n "${IB_CACHE_LOG:-}" ]; then
        _ib_console_args+=(--build-cache-local-logfile="$IB_CACHE_LOG")
    fi
    if [ -z "${IB_NO_CACHE:-}" ] && [ -n "${IB_PROFILE:-}" ] && [ -f "${IB_PROFILE}" ]; then
        _ib_console_args+=(--profile="$IB_PROFILE")
    fi
    if [ -n "${IB_MAX_LOCAL_CORES:-}" ]; then
        _ib_console_args+=(--max-local-cores="$IB_MAX_LOCAL_CORES")
    fi
    if [ -n "${IB_PREVENT_OVERLOAD:-}" ]; then
        _ib_console_args+=(--prevent-initiator-overload)
    fi
fi

export __IB_CARGO_WRAPPED=1
exec /usr/bin/ib_console "${_ib_console_args[@]}" cargo "$@"
