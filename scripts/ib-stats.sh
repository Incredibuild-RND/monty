#!/usr/bin/env bash
# IB-runner job post-flight cache stats.
#
# Reports per-job HIT/MISS counts and cache-dir state so each job's log
# (and step summary) shows whether its cargo invocations populated or
# hit the IB build cache. Tolerant of non-IB environments (no-op).
#
# Source-of-truth paths:
#   /etc/incredibuild/cache/build_cache/shared/   (BuildCache_defines.h
#                                                  BUILD_CACHE_LOCAL_PATH)
#   /etc/incredibuild/cache/build_cache/builds/   (BUILD_CACHE_BUILDS_PATH)
#
# Logfile schema (BuildCache_HitMiss.cpp): each cargo invocation appends
# a block of "info" lines, then "hit_miss" lines, then "other" lines,
# terminated by a literal "END" line. We count lines that look like
# HIT / MISS hit-miss entries.

set +e

echo "::group::IB cache stats"

LOG="${IB_CACHE_LOG:-}"
hits=0
misses=0
miss_reasons=""

if [ -n "$LOG" ] && [ -f "$LOG" ]; then
    echo "logfile: $LOG"
    bytes=$(wc -c <"$LOG" 2>/dev/null || echo 0)
    lines=$(wc -l <"$LOG" 2>/dev/null || echo 0)
    echo "size: ${bytes} bytes, ${lines} lines"

    # Hit/miss markers in BuildCache_HitMiss::add_hit_miss are formatted
    # as "HIT <hash>" / "MISS <hash> reason=..." — match line starts.
    hits=$(grep -c -E '^HIT[[:space:]]'  "$LOG" 2>/dev/null || echo 0)
    misses=$(grep -c -E '^MISS[[:space:]]' "$LOG" 2>/dev/null || echo 0)
    echo "HIT=$hits MISS=$misses"

    # Top miss reasons (--build-cache-report-all-miss output).
    miss_reasons=$(grep -E '^MISS[[:space:]]' "$LOG" 2>/dev/null \
        | sed -E 's/.*reason=([^[:space:]]+).*/\1/' \
        | sort | uniq -c | sort -rn | head -10)
    if [ -n "$miss_reasons" ]; then
        echo "top miss reasons:"
        echo "$miss_reasons"
    fi

    # Tail for human inspection.
    echo "--- last 80 lines ---"
    tail -80 "$LOG" 2>/dev/null
fi

# Legacy ib_hm.log path (older ib_console builds). We still surface any
# survivors in case a different code path wrote there.
if [ -d /etc/incredibuild/log ]; then
    mapfile -t hmlogs < <(find /etc/incredibuild/log -name ib_hm.log -printf "%T@ %p\n" 2>/dev/null | sort -rn | head -3 | cut -d" " -f2-)
    for f in "${hmlogs[@]:-}"; do
        [ -z "$f" ] && continue
        echo "--- legacy ib_hm.log: $f ---"
        wc -l "$f" 2>/dev/null
        tail -40 "$f" 2>/dev/null
    done
fi

echo "--- cache dirs ---"
for d in /etc/incredibuild/cache/build_cache/shared \
         /etc/incredibuild/cache/build_cache/builds; do
    if [ -d "$d" ]; then
        tar_count=$(find "$d" -name '*.tar' 2>/dev/null | wc -l)
        echo "$(du -sh "$d" 2>/dev/null | head -1) — .tar artifacts: $tar_count"
    fi
done

echo "::endgroup::"

# Step summary surface (markdown).
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### IB cache stats — \`${GITHUB_JOB:-local}\`"
        echo ""
        echo "| metric | value |"
        echo "|---|---|"
        echo "| HIT | ${hits:-0} |"
        echo "| MISS | ${misses:-0} |"
        if [ -d /etc/incredibuild/cache/build_cache/shared ]; then
            shared_size=$(du -sh /etc/incredibuild/cache/build_cache/shared 2>/dev/null | awk '{print $1}')
            shared_tars=$(find /etc/incredibuild/cache/build_cache/shared -name '*.tar' 2>/dev/null | wc -l | tr -d ' ')
            echo "| shared cache size | ${shared_size:-?} |"
            echo "| shared cache .tar artifacts | ${shared_tars:-0} |"
        fi
        echo ""
        if [ -n "$miss_reasons" ]; then
            echo "Top miss reasons:"
            echo ""
            echo '```'
            echo "$miss_reasons"
            echo '```'
        fi
    } >> "$GITHUB_STEP_SUMMARY"
fi
