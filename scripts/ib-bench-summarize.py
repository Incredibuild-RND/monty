#!/usr/bin/env python3
"""Aggregate ib-bench per-cell CSVs into a markdown table.

Each cell of the bench workflow drops a CSV at
  bench-results/<cell>.csv

with header:
  iteration,wall_seconds,user_seconds,sys_seconds,max_rss_kb,hits,misses,cache_size_bytes_delta,target_size_bytes,coverage_sha256

This script reads them, computes mean/stddev for wall_seconds, and writes
a comparison table plus speedup ratios (D/A, C/A, B/A) to $GITHUB_STEP_SUMMARY
(if set) and stdout.

Usage:
  scripts/ib-bench-summarize.py bench-results/
"""
from __future__ import annotations

import csv
import math
import os
import statistics
import sys
from pathlib import Path

CELLS = [
    ("A", "ubuntu-latest, no IB"),
    ("B", "IB, default profile (rustc NOT cached)"),
    ("C", "IB, custom profile (rustc cached) — COLD"),
    ("D", "IB, custom profile (rustc cached) — WARM"),
]


def read_cell(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    with path.open() as f:
        return list(csv.DictReader(f))


def fnum(rows: list[dict[str, str]], key: str) -> list[float]:
    out: list[float] = []
    for r in rows:
        v = r.get(key, "")
        try:
            out.append(float(v))
        except ValueError:
            continue
    return out


def fmt_mean_std(xs: list[float], unit: str = "s") -> str:
    if not xs:
        return "—"
    if len(xs) == 1:
        return f"{xs[0]:.1f}{unit}"
    m = statistics.mean(xs)
    s = statistics.stdev(xs)
    return f"{m:.1f} ± {s:.1f}{unit}"


def fmt_ratio(num: list[float], den: list[float]) -> str:
    if not num or not den:
        return "—"
    a = statistics.mean(num)
    b = statistics.mean(den)
    if a == 0:
        return "—"
    return f"{b / a:.2f}x"


def fmt_int_mean(xs: list[float]) -> str:
    if not xs:
        return "—"
    return f"{statistics.mean(xs):.0f}"


def fmt_bytes(n: float | None) -> str:
    if n is None or math.isnan(n):
        return "—"
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    i = 0
    f = float(n)
    while abs(f) >= 1024 and i < len(units) - 1:
        f /= 1024
        i += 1
    return f"{f:.1f} {units[i]}"


def main(results_dir: str) -> int:
    base = Path(results_dir)
    cells: dict[str, list[dict[str, str]]] = {}
    for label, _ in CELLS:
        cells[label] = read_cell(base / f"{label}.csv")

    lines: list[str] = []
    lines.append("# IB build-runner value matrix")
    lines.append("")
    lines.append("Same workload (`cargo llvm-cov --no-report -p monty`), 3 iterations per cell.")
    lines.append("")
    lines.append("| cell | configuration | wall time | hits | misses | target/ size |")
    lines.append("|---|---|---|---|---|---|")
    for label, desc in CELLS:
        rows = cells.get(label, [])
        wall = fnum(rows, "wall_seconds")
        hits = fnum(rows, "hits")
        misses = fnum(rows, "misses")
        target = fnum(rows, "target_size_bytes")
        target_str = fmt_bytes(statistics.mean(target)) if target else "—"
        lines.append(
            f"| **{label}** | {desc} | {fmt_mean_std(wall)} | "
            f"{fmt_int_mean(hits)} | {fmt_int_mean(misses)} | {target_str} |"
        )
    lines.append("")

    a_wall = fnum(cells.get("A", []), "wall_seconds")
    lines.append("## Speedup vs ubuntu-latest baseline (A)")
    lines.append("")
    lines.append("| comparison | meaning | speedup |")
    lines.append("|---|---|---|")
    for label, desc in CELLS[1:]:
        rows = cells.get(label, [])
        w = fnum(rows, "wall_seconds")
        meaning = {
            "B": "ib_console overhead floor (no rustc cache)",
            "C": "first run on a clean IB runner",
            "D": "every push after the first (warm rustc cache)",
        }[label]
        lines.append(f"| **A → {label}** | {meaning} | {fmt_ratio(w, a_wall)} |")
    lines.append("")

    # Correctness gate.
    shas: dict[str, set[str]] = {}
    for label in (l for l, _ in CELLS):
        shas[label] = {
            r.get("coverage_sha256", "")
            for r in cells.get(label, [])
            if r.get("coverage_sha256")
        }
    all_shas = set().union(*shas.values()) if shas else set()
    lines.append("## Artifact correctness")
    lines.append("")
    if len(all_shas) <= 1 and all_shas:
        sha = next(iter(all_shas))
        lines.append(f"All cells produced byte-identical `rust-coverage.json`: `{sha[:16]}…`")
    elif not all_shas:
        lines.append("No coverage artifact hashes recorded.")
    else:
        lines.append(
            "**MISMATCH** — IB cache produced different output from plain cargo:"
        )
        lines.append("")
        lines.append("| cell | distinct sha256 |")
        lines.append("|---|---|")
        for label, _ in CELLS:
            seen = sorted(shas.get(label, set()))
            lines.append(
                f"| {label} | "
                + ", ".join(f"`{s[:12]}…`" for s in seen)
                + " |"
            )
    lines.append("")

    out = "\n".join(lines) + "\n"
    sys.stdout.write(out)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(out)
    # Exit non-zero if correctness gate failed and we have data from at
    # least 2 cells.
    if len(all_shas) > 1 and sum(1 for s in shas.values() if s) >= 2:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "bench-results/"))
