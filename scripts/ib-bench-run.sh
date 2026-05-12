#!/usr/bin/env bash
# Runs a deterministic cargo workload N times under whatever cargo flavour
# the surrounding job sets (plain cargo for cell A/E, cargo-ib.sh for
# cells B/C/D/F), captures wall-clock + IB cache HIT/MISS + cache-dir-size
# deltas + final target/ size, and emits one CSV row per iteration to
# bench-results/$CELL.csv.
#
# Workloads (selected via WORKLOAD env, default `synthetic`):
#   synthetic   `cargo test --no-run -p monty`. Compiles monty's test
#               binary but doesn't execute it — exercises the same rustc
#               work that dominates the production test-rust job, without
#               depending on the third-party cargo-llvm-cov subcommand.
#               Used by cells A/B/C/D for fast cell-comparison signal.
#   test-rust   The 8-call `cargo llvm-cov` sequence from
#               .github/workflows/ci.yml::test-rust, replayed verbatim.
#               Used by cells E (ubuntu-latest baseline) and F (IB warm
#               cache) so the E→F speedup is the directly measured
#               realistic test-rust speedup, not an extrapolation from
#               the synthetic workload.
#
# Cargo dispatcher:
#   - explicit `CARGO_BIN` env wins (cells E/F set this);
#   - otherwise, on a host with /usr/bin/ib_console for cells B/C/D,
#     route through ./scripts/cargo-ib.sh;
#   - otherwise, plain `cargo` (cell A and any non-IB host).
#
# CSV columns (one row per iteration; for multi-call workloads,
# wall/user/sys are summed across calls and rss is the per-call max):
#   iteration, wall_seconds, user_seconds, sys_seconds, max_rss_kb,
#   hits, misses, cache_size_bytes_delta, target_size_bytes,
#   coverage_sha256
#
# coverage_sha256 is left empty here; the `synthetic` workload doesn't
# produce a stable artifact, and the `test-rust` workload skips
# `llvm-cov report` (the artifact emit step is not part of the rustc-
# bound work we're measuring).

set -uo pipefail

CELL="${CELL:?CELL must be set (A/B/C/D/E/F)}"
ITERATIONS="${ITERATIONS:-3}"
[ -z "$ITERATIONS" ] && ITERATIONS=3
WORKLOAD="${WORKLOAD:-synthetic}"

mkdir -p bench-results
OUT="bench-results/${CELL}.csv"
echo "iteration,wall_seconds,user_seconds,sys_seconds,max_rss_kb,hits,misses,cache_size_bytes_delta,target_size_bytes,coverage_sha256" > "$OUT"

# Cargo dispatcher.
if [ -n "${CARGO_BIN:-}" ]; then
    # shellcheck disable=SC2206  # caller-controlled, intentional split
    CARGO_RUNNER=($CARGO_BIN)
elif [ -x /usr/bin/ib_console ] && [ "$CELL" != "A" ]; then
    CARGO_RUNNER=(./scripts/cargo-ib.sh)
else
    CARGO_RUNNER=(cargo)
fi

# Workload definition.
case "$WORKLOAD" in
    synthetic)
        WORKLOAD_CMDS=("test --no-run -p monty")
        ;;
    test-rust)
        # Mirrors .github/workflows/ci.yml::test-rust (the 7 cargo llvm-cov
        # invocations plus the leading `clean`). The trailing `report`
        # steps are intentionally omitted — they emit text/codecov from
        # already-compiled coverage data, not rustc work, so they would
        # add wall-clock noise without measuring anything we care about.
        WORKLOAD_CMDS=(
            "llvm-cov clean --workspace"
            "llvm-cov --no-report -p monty"
            "llvm-cov run --no-report -p monty-datatest"
            "llvm-cov --no-report -p monty --features memory-model-checks"
            "llvm-cov run --no-report -p monty-datatest --features memory-model-checks"
            "llvm-cov --no-report -p monty --features ref-count-return"
            "llvm-cov run --no-report -p monty-datatest --features ref-count-return"
            "llvm-cov --no-report -p monty_type_checking -p monty_typeshed"
        )
        ;;
    codspeed)
        # Mirrors .github/workflows/codspeed.yml::benchmarks. The
        # `cargo install cargo-codspeed` step is left to the workflow
        # (idempotent across iterations: the binary persists in
        # CARGO_HOME/bin so iter ≥ 2 is a no-op install). Only the
        # actual rustc-bound `cargo codspeed build` is in the workload,
        # which is what Layer F (codspeed.yml on incredibuild-runner)
        # actually accelerates.
        WORKLOAD_CMDS=(
            "codspeed build -p monty-bench --bench main"
        )
        ;;
    *)
        echo "::error::unknown WORKLOAD=$WORKLOAD (expected synthetic|test-rust|codspeed)"
        exit 2
        ;;
esac

echo "::group::bench setup diagnostic"
echo "CELL=$CELL ITERATIONS=$ITERATIONS WORKLOAD=$WORKLOAD"
echo "CARGO_RUNNER=${CARGO_RUNNER[*]}"
echo "WORKLOAD_CMDS:"
for c in "${WORKLOAD_CMDS[@]}"; do echo "  cargo $c"; done
echo "PWD=$PWD"
echo "PATH=$PATH"
echo "which cargo: $(command -v cargo || echo MISSING)"
cargo --version 2>&1 || echo "cargo --version FAILED"
rustc --version --verbose 2>&1 || echo "rustc --version FAILED"
ls -la /usr/bin/ib_console 2>&1 || true
ls -la /usr/bin/time 2>&1 || true
ls -la /etc/incredibuild/log/ 2>&1 || true
echo "::endgroup::"

cache_size() {
    local d="/etc/incredibuild/cache/build_cache/shared"
    if [ -d "$d" ]; then
        du -sb "$d" 2>/dev/null | awk '{print $1+0}'
    else
        echo 0
    fi
}

target_size() {
    if [ -d target ]; then
        du -sb target 2>/dev/null | awk '{print $1+0}'
    else
        echo 0
    fi
}

count_logfile() {
    # Sum HIT / MISS counts across all per-job IB cache logfiles.
    local dir="/etc/incredibuild/log"
    local kind="$1"
    if [ -d "$dir" ]; then
        local n
        n=$(grep -h -c -E "^${kind}[[:space:]]" "$dir"/ib_cache_*.log 2>/dev/null \
            | awk '{s+=$1} END {print s+0}')
        echo "${n:-0}"
    else
        echo 0
    fi
}

# Run a single cargo invocation under /usr/bin/time -v (or a date
# fallback). Sets globals: call_wall, call_user, call_sys, call_rss,
# call_rc. Tolerates non-zero exit codes (the data point is still
# valuable; we surface a ::warning:: and let the iteration continue).
run_one() {
    local args_str="$1"
    # shellcheck disable=SC2206  # workload-controlled, intentional split
    local -a args=($args_str)
    call_wall=0
    call_user=0
    call_sys=0
    call_rss=0
    call_rc=0
    local time_out
    time_out=$(mktemp)
    set +e
    if [ -x /usr/bin/time ]; then
        /usr/bin/time -v -o "$time_out" \
            "${CARGO_RUNNER[@]}" "${args[@]}"
        call_rc=$?
    else
        echo "::warning::/usr/bin/time missing, using date fallback (no user/sys/rss)"
        local t0 t1
        t0=$(date +%s.%N)
        "${CARGO_RUNNER[@]}" "${args[@]}"
        call_rc=$?
        t1=$(date +%s.%N)
        call_wall=$(python3 -c "print(f'{${t1}-${t0}:.3f}')")
    fi
    set -e
    if [ -s "$time_out" ]; then
        echo "--- /usr/bin/time -v: cargo ${args_str} ---"
        cat "$time_out"
        echo "---"
        local wall user sys rss
        wall=$(awk -F': ' '/Elapsed \(wall clock\) time/ {print $2}' "$time_out" 2>/dev/null | tail -1)
        user=$(awk -F': ' '/User time \(seconds\)/ {print $2+0}' "$time_out" 2>/dev/null | tail -1)
        sys=$(awk -F': ' '/System time \(seconds\)/ {print $2+0}' "$time_out" 2>/dev/null | tail -1)
        rss=$(awk -F': ' '/Maximum resident set size/ {print $2+0}' "$time_out" 2>/dev/null | tail -1)
        call_user="${user:-0}"
        call_sys="${sys:-0}"
        call_rss="${rss:-0}"
        # Convert HH:MM:SS, MM:SS, SS, or SS.ss into seconds.
        call_wall=$(python3 - <<PY
w = "${wall:-0}".strip()
if not w:
    print(0); raise SystemExit
parts = [float(p) for p in w.split(":")]
secs = 0.0
for p in parts:
    secs = secs * 60 + p
print(f"{secs:.3f}")
PY
)
    fi
    rm -f "$time_out"
}

# Each iteration:
#   1. clean target/ (full rebuild)
#   2. snapshot pre-cache size + HIT/MISS
#   3. run each workload command under /usr/bin/time -v
#   4. snapshot post-cache size + HIT/MISS deltas
#   5. emit one CSV row aggregating across the workload's calls
# We capture each call's exit code but DO NOT abort the loop — the data
# point is still valuable and we want all iterations visible in the CSV.
for i in $(seq 1 "$ITERATIONS"); do
    echo "::group::cell ${CELL} iteration ${i}/${ITERATIONS}"

    # Clean target/ between iterations so the rustc work is real
    # every time. Use direct rm rather than `cargo clean` to avoid
    # any cargo-subcommand dispatch quirks under ib_console.
    rm -rf target 2>&1 | tail -5 || true

    pre_cache=$(cache_size)
    pre_hits=$(count_logfile HIT)
    pre_misses=$(count_logfile MISS)
    echo "pre: cache=${pre_cache}B hits=${pre_hits} misses=${pre_misses}"

    iter_wall=0
    iter_user=0
    iter_sys=0
    iter_max_rss=0
    iter_rc=0
    for cmd in "${WORKLOAD_CMDS[@]}"; do
        echo ":: cargo $cmd"
        run_one "$cmd"
        iter_wall=$(python3 -c "print(f'{${iter_wall}+${call_wall}:.3f}')")
        iter_user=$(python3 -c "print(f'{${iter_user}+${call_user}:.3f}')")
        iter_sys=$(python3 -c "print(f'{${iter_sys}+${call_sys}:.3f}')")
        if [ "${call_rss:-0}" -gt "${iter_max_rss:-0}" ] 2>/dev/null; then
            iter_max_rss="$call_rss"
        fi
        if [ "$call_rc" -ne 0 ]; then
            iter_rc=$call_rc
            echo "::warning::cargo $cmd in iter $i exited $call_rc"
        fi
    done

    post_cache=$(cache_size)
    post_hits=$(count_logfile HIT)
    post_misses=$(count_logfile MISS)
    delta_cache=$((post_cache - pre_cache))
    delta_hits=$((post_hits - pre_hits))
    delta_misses=$((post_misses - pre_misses))
    target=$(target_size)

    echo "post: cache=${post_cache}B hits=${post_hits} misses=${post_misses} target=${target}B"
    echo "deltas: cache=${delta_cache}B hits=${delta_hits} misses=${delta_misses}"
    echo "iter=$i wall=${iter_wall}s user=${iter_user}s sys=${iter_sys}s rss=${iter_max_rss}kb rc=${iter_rc}"
    echo "$i,$iter_wall,$iter_user,$iter_sys,$iter_max_rss,$delta_hits,$delta_misses,$delta_cache,$target," >> "$OUT"

    echo "::endgroup::"
done

echo "::group::wrote $OUT"
cat "$OUT"
echo "::endgroup::"
