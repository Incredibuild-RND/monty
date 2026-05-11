#!/usr/bin/env bash
# IB-runner job pre-flight setup.
#
# Bundles all the boilerplate that every IB-routed job needs into one
# script so the workflow stays small. Idempotent and tolerant of
# non-IB runners (no-op fallthroughs).
#
# Effects:
#   1. Bootstrap sudo / curl / wget / unzip / ca-certificates on lean
#      runner images (no-op when already present, so safe everywhere).
#   2. Pre-flight diagnostics: ib_console version, cache directory
#      state, profile presence. Visible in the GitHub Actions log so
#      it's obvious what state IB is in before the job's real work.
#   3. Ensure libpython3.X.so is linkable for pyo3-using crates.
#      python-build-standalone tarballs ship only libpython3.X.so.1.0
#      and bake /opt/hostedtoolcache/Python/... into sysconfig, so we
#      create the missing .so symlink at $sys.prefix/lib and export
#      LIBRARY_PATH / LD_LIBRARY_PATH for cc / lld fallback.
#   4. Ensure .venv/bin/python3 at workspace root if uv + pyproject.toml
#      are present. monty's .cargo/config.toml sets
#      PYO3_PYTHON=.venv/bin/python3 (relative), which is fine for
#      local development but needs that path to actually exist when
#      cargo runs under prek/clippy on a fresh CI clone.
#
# Background:
#   - ib_console CLI: ib_linux:cpp/XgConsole/XgConsole_main.cpp
#   - cache path:     ib_linux:cpp/BuildCache/BuildCache_defines.h
#                     BUILD_CACHE_LOCAL_PATH=/etc/incredibuild/cache/build_cache/shared

set -euo pipefail
echo "::group::IB pre-flight"

# 1. baseline tooling -----------------------------------------------------
is_root() { [ "$(id -u)" = "0" ]; }

if is_root && ! command -v sudo >/dev/null 2>&1; then
    cat > /usr/local/bin/sudo <<'EOF'
#!/bin/sh
exec "$@"
EOF
    chmod +x /usr/local/bin/sudo
fi

apt_install() {
    if is_root; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
    else
        sudo apt-get update -qq
        DEBIAN_FRONTEND=noninteractive sudo apt-get install -y --no-install-recommends "$@"
    fi
}

missing=()
for tool in wget curl unzip; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
# `time` (GNU /usr/bin/time, not the bash builtin) is needed by the
# ib-bench measurement script. Lean IB runner images don't ship it.
if [ ! -x /usr/bin/time ]; then
    missing+=(time)
fi
if [ "${#missing[@]}" -gt 0 ]; then
    missing+=(ca-certificates)
    apt_install "${missing[@]}"
fi

# 2. ib_console + cache state --------------------------------------------
if [ -x /usr/bin/ib_console ]; then
    /usr/bin/ib_console --version 2>&1 | head -3 || true
    for d in /etc/incredibuild/cache/build_cache/shared \
             /etc/incredibuild/cache/build_cache/builds \
             /etc/incredibuild/db; do
        if [ -d "$d" ]; then
            echo "$(du -sh "$d" 2>/dev/null | head -1) (files: $(find "$d" -maxdepth 3 -type f 2>/dev/null | wc -l))"
        fi
    done
else
    echo "ib_console not present — wrapper will fall through to plain cargo"
fi
ls -la scripts/ib-profile.xml 2>/dev/null || true

# 2b. export IB_CACHE_LOG / IB_PROFILE for cargo-ib.sh -------------------
# Logfile path must be ABSOLUTE (XgConsole_main.cpp:482). We put it under
# /etc/incredibuild/log/ — the canonical IB log dir on the runner image
# (ib-stats.sh already greps there), which survives any chroot/namespace
# teardown ib_console may do for intercepted processes. Per-job filename
# so concurrent jobs on the same runner don't stomp each other's log.
if [ -n "${GITHUB_ENV:-}" ]; then
    job_id="${GITHUB_JOB:-local}_${GITHUB_RUN_ID:-0}_${GITHUB_RUN_ATTEMPT:-1}"
    log_path="/etc/incredibuild/log/ib_cache_${job_id}.log"
    profile_path="$PWD/scripts/ib-profile.xml"
    {
        echo "IB_CACHE_LOG=$log_path"
        echo "IB_PROFILE=$profile_path"
    } >> "$GITHUB_ENV"
    echo "IB_CACHE_LOG=$log_path"
    echo "IB_PROFILE=$profile_path"
    # mkdir at root may need sudo if not already root; tolerate failure
    # (cargo-ib.sh re-tries the mkdir).
    if is_root; then
        mkdir -p /etc/incredibuild/log 2>/dev/null || true
    else
        sudo mkdir -p /etc/incredibuild/log 2>/dev/null || true
        sudo chmod 1777 /etc/incredibuild/log 2>/dev/null || true
    fi
fi

# 3. libpython link safety (only meaningful when python is on PATH) ------
if command -v python3 >/dev/null 2>&1; then
    PY_PREFIX=$(python3 -c 'import sys; print(sys.prefix)')
    PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    so_link="$PY_PREFIX/lib/libpython${PY_VER}.so"
    if [ ! -e "$so_link" ]; then
        candidate=$(ls "$PY_PREFIX"/lib/libpython${PY_VER}*.so* 2>/dev/null | sort -r | head -1 || true)
        if [ -n "$candidate" ]; then
            ln -s "$(basename "$candidate")" "$so_link" 2>/dev/null || true
        fi
    fi
    if [ -n "${GITHUB_ENV:-}" ]; then
        echo "LIBRARY_PATH=$PY_PREFIX/lib" >> "$GITHUB_ENV"
        echo "LD_LIBRARY_PATH=$PY_PREFIX/lib" >> "$GITHUB_ENV"
    fi
    echo "python: $PY_PREFIX ($PY_VER)"
fi

# 4. ensure .venv/bin/python3 if uv + pyproject.toml are present ---------
# monty's .cargo/config.toml points PYO3_PYTHON at .venv/bin/python3. We
# keep that file untouched (prek's check-yaml relies on it being tracked
# AND present on disk) and just make the path resolve by pre-creating
# the venv. Idempotent: if .venv/bin/python3 already exists, do nothing.
if command -v uv >/dev/null 2>&1 && [ -f pyproject.toml ] && [ ! -e .venv/bin/python3 ]; then
    echo "creating .venv at workspace root via uv"
    uv venv .venv ${UV_PYTHON:+--python "$UV_PYTHON"} 2>&1 | tail -5 || true
fi
[ -e .venv/bin/python3 ] && echo ".venv/bin/python3: $(readlink -f .venv/bin/python3 2>/dev/null)"

echo "::endgroup::"
