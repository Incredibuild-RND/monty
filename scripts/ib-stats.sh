#!/usr/bin/env bash
# IB-runner job post-flight cache stats.
#
# Dumps the IB build-cache state after a job completes so each job's
# log shows whether its cargo invocations populated or hit the cache.
# Tolerant of non-IB environments.
#
# Paths come from ib_linux:cpp/BuildCache/BuildCache_defines.h
# (BUILD_CACHE_LOCAL_PATH = /etc/incredibuild/cache/build_cache/shared).

set +e

echo "::group::IB cache stats"

# ib_hm.log is announced in build output as
#   "Incredibuild System: Build Cache report is '...'"
# but is typically written inside ib_console's chroot/namespace and
# torn down on exit. Try to surface any survivors.
if [ -d /etc/incredibuild/log ]; then
    mapfile -t hmlogs < <(find /etc/incredibuild/log -name ib_hm.log -printf "%T@ %p\n" 2>/dev/null | sort -rn | head -3 | cut -d" " -f2-)
    for f in "${hmlogs[@]:-}"; do
        [ -z "$f" ] && continue
        echo "--- $f ---"
        wc -l "$f" 2>/dev/null
        tail -100 "$f" 2>/dev/null
        hits=$(grep -c -E '^HIT' "$f" 2>/dev/null || echo 0)
        misses=$(grep -c -E '^MISS' "$f" 2>/dev/null || echo 0)
        echo "  HIT=$hits MISS=$misses"
    done
fi

for d in /etc/incredibuild/cache/build_cache/shared \
         /etc/incredibuild/cache/build_cache/builds; do
    if [ -d "$d" ]; then
        tar_count=$(find "$d" -name '*.tar' 2>/dev/null | wc -l)
        echo "$(du -sh "$d" 2>/dev/null | head -1) — .tar artifacts: $tar_count"
    fi
done

echo "::endgroup::"
