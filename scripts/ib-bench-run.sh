#!/usr/bin/env bash
# Runs $BENCH_CMD ($ITERATIONS times) under whatever cargo flavour is
# active in the surrounding job, captures wall-clock + IB cache HIT/MISS
# + cache-dir-size deltas + final target/ size, and emits one CSV row
# per iteration to bench-results/$CELL.csv.
#
# Cells A/B/C/D differ only in the surrounding job env (ubuntu-latest
# vs incredibuild-runner; IB_NO_CACHE vs IB_PROFILE; cold vs warm IB
# cache). All four invoke this script identically.
#
# CSV columns:
#   iteration, wall_seconds, user_seconds, sys_seconds, max_rss_kb,
#   hits, misses, cache_size_bytes_delta, target_size_bytes,
#   coverage_sha256
#
# coverage_sha256 is filled in by the summarize job (it has the artifact
# from every cell); this script writes an empty placeholder.

set -euo pipefail

CELL="${CELL:?CELL must be set (A/B/C/D)}"
ITERATIONS="${ITERATIONS:-3}"

# Bench workload: the dominant compile in the test-rust job. Hardcoded
# (not env-driven) because the report regex contains shell
# metacharacters that don't survive word-splitting through env vars.
BENCH_ARGS=(llvm-cov --no-report -p monty)
REPORT_ARGS=(llvm-cov report --codecov --output-path=rust-coverage.json
             --ignore-filename-regex '(tests/|test_cases/|/tests\.rs$)')

mkdir -p bench-results
OUT="bench-results/${CELL}.csv"
echo "iteration,wall_seconds,user_seconds,sys_seconds,max_rss_kb,hits,misses,cache_size_bytes_delta,target_size_bytes,coverage_sha256" > "$OUT"

# Cargo dispatcher: B/C/D go through cargo-ib.sh, A uses plain cargo.
if [ -x /usr/bin/ib_console ] && [ "$CELL" != "A" ]; then
    CARGO_RUNNER=(./scripts/cargo-ib.sh)
else
    CARGO_RUNNER=(cargo)
fi

cache_size() {
    local d="/etc/incredibuild/cache/build_cache/shared"
    if [ -d "$d" ]; then
        du -sb "$d" 2>/dev/null | awk '{print $1}'
    else
        echo 0
    fi
}

target_size() {
    if [ -d target ]; then
        du -sb target 2>/dev/null | awk '{print $1}'
    else
        echo 0
    fi
}

count_logfile() {
    # Sums HIT / MISS counts across all per-job IB cache logfiles. The
    # bench script reuses the surrounding job's IB_CACHE_LOG (set by
    # ib-prep.sh) but cargo invocations may rotate logfiles between
    # iterations; safer to sum the dir.
    local dir="/etc/incredibuild/log"
    local kind="$1"
    if [ -d "$dir" ]; then
        grep -h -c -E "^${kind}[[:space:]]" "$dir"/ib_cache_*.log 2>/dev/null \
            | awk '{s+=$1} END {print s+0}'
    else
        echo 0
    fi
}

# Each iteration:
#   1. clean the cargo target dir (so the rustc work is real)
#   2. snapshot pre-cache size
#   3. run BENCH_CMD under /usr/bin/time
#   4. snapshot post-cache size and HIT/MISS deltas
#   5. emit one CSV row
# The final iteration also runs BENCH_REPORT_CMD to produce
# rust-coverage.json for the cross-cell correctness check.
for i in $(seq 1 "$ITERATIONS"); do
    echo "::group::cell ${CELL} iteration ${i}/${ITERATIONS}"

    "${CARGO_RUNNER[@]}" llvm-cov clean --workspace 2>&1 | tail -5 || true
    pre_cache=$(cache_size)
    pre_hits=$(count_logfile HIT)
    pre_misses=$(count_logfile MISS)

    time_out=$(mktemp)
    /usr/bin/time -v -o "$time_out" \
        "${CARGO_RUNNER[@]}" "${BENCH_ARGS[@]}" 2>&1 \
        | tail -200 || true

    wall=$(awk -F': ' '/Elapsed \(wall clock\) time/ {print $2}' "$time_out" | tail -1)
    user=$(awk -F': ' '/User time \(seconds\)/ {print $2+0}' "$time_out" | tail -1)
    sys=$(awk -F': ' '/System time \(seconds\)/ {print $2+0}' "$time_out" | tail -1)
    rss=$(awk -F': ' '/Maximum resident set size/ {print $2+0}' "$time_out" | tail -1)

    # Convert HH:MM:SS or MM:SS or SS.ss into seconds.
    wall_secs=$(python3 -c "
import sys
parts = '${wall}'.strip().split(':') if '${wall}' else []
if not parts:
    print(0); sys.exit()
parts = [float(p) for p in parts]
secs = 0.0
for p in parts:
    secs = secs * 60 + p
print(f'{secs:.3f}')")

    post_cache=$(cache_size)
    post_hits=$(count_logfile HIT)
    post_misses=$(count_logfile MISS)
    delta_cache=$((post_cache - pre_cache))
    delta_hits=$((post_hits - pre_hits))
    delta_misses=$((post_misses - pre_misses))
    target=$(target_size)

    echo "iter=$i wall=${wall_secs}s user=${user}s sys=${sys}s rss=${rss}kb hits=${delta_hits} misses=${delta_misses} cache_delta=${delta_cache}B target=${target}B"
    echo "$i,$wall_secs,$user,$sys,$rss,$delta_hits,$delta_misses,$delta_cache,$target," >> "$OUT"

    rm -f "$time_out"
    echo "::endgroup::"
done

# Produce coverage artifact from the LAST iteration's compiled state.
# `report` is a no-op compile-wise; it just writes rust-coverage.json
# from already-instrumented binaries.
echo "::group::cell ${CELL} coverage artifact"
"${CARGO_RUNNER[@]}" "${REPORT_ARGS[@]}" 2>&1 | tail -10 || true
ls -la rust-coverage.json 2>/dev/null || true
echo "::endgroup::"

echo "wrote $OUT:"
cat "$OUT"
