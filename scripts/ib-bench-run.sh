#!/usr/bin/env bash
# Runs a single deterministic cargo workload N times under whatever
# cargo flavour the surrounding job sets (plain cargo for cell A,
# cargo-ib.sh for cells B/C/D), captures wall-clock + IB cache HIT/MISS
# + cache-dir-size deltas + final target/ size, and emits one CSV row
# per iteration to bench-results/$CELL.csv.
#
# Bench workload: `cargo test --no-run -p monty`. Compiles monty's
# test binary but doesn't execute it — exercises the same rustc work
# that dominates the production test-rust job, without depending on
# the third-party cargo-llvm-cov subcommand. The number we publish
# transfers directly to the test-rust wall-clock minus the test-run
# tail.
#
# CSV columns:
#   iteration, wall_seconds, user_seconds, sys_seconds, max_rss_kb,
#   hits, misses, cache_size_bytes_delta, target_size_bytes,
#   coverage_sha256
#
# coverage_sha256 is filled in by the summarize job; this script
# leaves it empty.

set -uo pipefail

CELL="${CELL:?CELL must be set (A/B/C/D)}"
ITERATIONS="${ITERATIONS:-3}"
[ -z "$ITERATIONS" ] && ITERATIONS=3

# Bench workload — hardcoded so shell metacharacters in args are not
# a portability concern.
BENCH_ARGS=(test --no-run -p monty)

mkdir -p bench-results
OUT="bench-results/${CELL}.csv"
echo "iteration,wall_seconds,user_seconds,sys_seconds,max_rss_kb,hits,misses,cache_size_bytes_delta,target_size_bytes,coverage_sha256" > "$OUT"

# Cargo dispatcher: B/C/D go through cargo-ib.sh, A uses plain cargo.
if [ -x /usr/bin/ib_console ] && [ "$CELL" != "A" ]; then
    CARGO_RUNNER=(./scripts/cargo-ib.sh)
else
    CARGO_RUNNER=(cargo)
fi

echo "::group::bench setup diagnostic"
echo "CELL=$CELL ITERATIONS=$ITERATIONS"
echo "CARGO_RUNNER=${CARGO_RUNNER[*]}"
echo "BENCH_ARGS=${BENCH_ARGS[*]}"
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

# Each iteration:
#   1. clean target/ (full rebuild)
#   2. snapshot pre-cache size
#   3. run cargo under /usr/bin/time -v
#   4. snapshot post-cache size and HIT/MISS deltas
#   5. emit one CSV row
# We capture the cargo exit code but DO NOT abort the rest of the
# loop — the data point is still valuable (high wall-clock, zero
# hits) and we want all iterations visible in the CSV.
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

    time_out=$(mktemp)
    user="0"; sys="0"; rss="0"; wall_secs="0"

    set +e
    if [ -x /usr/bin/time ]; then
        # Preferred: GNU /usr/bin/time -v gives wall + user + sys + RSS.
        /usr/bin/time -v -o "$time_out" \
            "${CARGO_RUNNER[@]}" "${BENCH_ARGS[@]}"
        cargo_rc=$?
    else
        # Fallback: date-based wall-clock when GNU time isn't available
        # (lean self-hosted runner images that haven't been bootstrapped
        # by ib-prep.sh yet). User/sys/rss stay zero in this branch.
        echo "::warning::/usr/bin/time missing, using date fallback (no user/sys/rss)"
        t0=$(date +%s.%N)
        "${CARGO_RUNNER[@]}" "${BENCH_ARGS[@]}"
        cargo_rc=$?
        t1=$(date +%s.%N)
        wall_secs=$(python3 -c "print(f'{${t1}-${t0}:.3f}')")
    fi
    set -e

    echo "cargo exit code: $cargo_rc"
    if [ "$cargo_rc" -ne 0 ]; then
        echo "::warning::cargo iteration $i exited $cargo_rc"
    fi
    if [ -s "$time_out" ]; then
        echo "--- /usr/bin/time -v output ---"
        cat "$time_out"
        echo "---"
        wall=$(awk -F': ' '/Elapsed \(wall clock\) time/ {print $2}' "$time_out" 2>/dev/null | tail -1)
        user=$(awk -F': ' '/User time \(seconds\)/ {print $2+0}' "$time_out" 2>/dev/null | tail -1)
        sys=$(awk -F': ' '/System time \(seconds\)/ {print $2+0}' "$time_out" 2>/dev/null | tail -1)
        rss=$(awk -F': ' '/Maximum resident set size/ {print $2+0}' "$time_out" 2>/dev/null | tail -1)
        # Convert HH:MM:SS, MM:SS, SS, or SS.ss into seconds.
        wall_secs=$(python3 - <<PY
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

    post_cache=$(cache_size)
    post_hits=$(count_logfile HIT)
    post_misses=$(count_logfile MISS)
    delta_cache=$((post_cache - pre_cache))
    delta_hits=$((post_hits - pre_hits))
    delta_misses=$((post_misses - pre_misses))
    target=$(target_size)

    echo "post: cache=${post_cache}B hits=${post_hits} misses=${post_misses} target=${target}B"
    echo "deltas: cache=${delta_cache}B hits=${delta_hits} misses=${delta_misses}"
    echo "iter=$i wall=${wall_secs}s user=${user:-0}s sys=${sys:-0}s rss=${rss:-0}kb"
    echo "$i,$wall_secs,${user:-0},${sys:-0},${rss:-0},$delta_hits,$delta_misses,$delta_cache,$target," >> "$OUT"

    rm -f "$time_out"
    echo "::endgroup::"
done

echo "::group::wrote $OUT"
cat "$OUT"
echo "::endgroup::"
