"""
tools/calibration_matrix.py — the tag-driven expectancy delta matrix:

  Tag | 4W expectancy | 2W expectancy | Delta | Sample | Action

"Tag" here is a (symbol, session, sweep_grade)-style compound key — every
combination that has enough of its own rows to be worth a row in the
table. This is deliberately NOT the same thing as gating.py's
weight-version promotion decision: gating.py asks "should this weight
set go live," this asks "which market-condition + setup combinations is
Medis Touch actually good at right now, and is that changing." They
share the same underlying stats (tools/stats.py) but answer different
questions, on purpose — collapsing them into one tool would force one
sample-size/persistence policy onto two different decisions.

WHY 4W IS THE PRIOR, NOT THE THING BEING REPLACED
The 4-week window is the stable baseline; the 2-week window is the last
half of it, which is what "is the recent behavior different from the
baseline" actually means (the 2W window's trades are a SUBSET of the 4W
window's, not a separate later sample) — same asymmetry the spec's
C4W/C2W layering describes. This tool reports the delta; it does not
apply it. Wiring the 2W evidence into a bounded live adjustment is a
separate, harder change (see the ACTIVE PARAMETER note in the module
docstring) and is NOT what this file does.

ACTION COLUMN — sample-size-aware, per the spec's explicit warning not
to react to every negative delta:
  Keep         — 2W CI and 4W CI overlap, or 2W moved favorably
  Investigate  — 2W CI and 4W CI diverge unfavorably, sample adequate
  Reduce confidence — divergence is large AND persists at large sample
  Insufficient — 2W (or 4W) sample too small for the divergence test to
                 mean anything (this is reported, never silently upgraded
                 to Keep or Investigate)

USAGE
    python tools/calibration_matrix.py --min-sample 15
    python tools/calibration_matrix.py --json
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

_TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
if _TOOLS_DIR not in sys.path:
    sys.path.insert(0, _TOOLS_DIR)
from _pathutil import ensure_bridge_importable  # noqa: E402
ensure_bridge_importable(__file__)

try:
    from sqlalchemy import select

    from app.database import async_session
    from app.models import SignalOutcome
except ImportError as exc:  # pragma: no cover
    print(f"calibration_matrix: couldn't import the bridge's `app` package ({exc}). "
          "Run from telegram-bridge/, or with it on PYTHONPATH.", file=sys.stderr)
    sys.exit(1)

from stats import intervals_overlap, wilson_ci  # noqa: E402

RESOLVED_OUTCOMES = {"win", "loss", "scratch"}
DEFAULT_MIN_SAMPLE = 15  # below this, the divergence test isn't trusted regardless of what it says
BASELINE_WEEKS = 4
RECENT_WEEKS = 2


def _tag_key(r) -> str:
    parts = [r.symbol or "?", r.session or "?"]
    if r.sweep_grade:
        parts.append(f"sweep={r.sweep_grade}")
    return " ".join(parts)


def _expectancy(rows) -> tuple[float | None, int]:
    resolved = [r for r in rows if r.outcome in RESOLVED_OUTCOMES and r.realized_r is not None]
    n = len(resolved)
    if n == 0:
        return None, 0
    return sum(r.realized_r for r in resolved) / n, n


def _win_ci_for_delta_test(rows):
    """Uses win rate (not avg R) for the overlap test — Wilson CI on a
    proportion is well-behaved at small n; a CI on mean R needs a
    t-distribution and enough samples to trust normality, which is
    exactly the regime these tag buckets often DON'T reach. Avg R is
    still reported in the table (that's the number a person reads), the
    win-rate CI is just what decides "diverged or not.\""""
    resolved = [r for r in rows if r.outcome in RESOLVED_OUTCOMES]
    wins = sum(1 for r in resolved if r.outcome == "win")
    return wilson_ci(wins, len(resolved))


def compute_matrix(rows, min_sample: int = DEFAULT_MIN_SAMPLE) -> list[dict]:
    now = max((r.received_at for r in rows if r.received_at), default=datetime.now(timezone.utc))
    baseline_cutoff = now - timedelta(weeks=BASELINE_WEEKS)
    recent_cutoff = now - timedelta(weeks=RECENT_WEEKS)

    by_tag_4w: dict[str, list] = defaultdict(list)
    by_tag_2w: dict[str, list] = defaultdict(list)
    for r in rows:
        if not r.received_at or r.received_at < baseline_cutoff:
            continue
        tag = _tag_key(r)
        by_tag_4w[tag].append(r)  # 4W window
        if r.received_at >= recent_cutoff:
            by_tag_2w[tag].append(r)  # 2W window — a SUBSET of the 4W rows, not a separate sample

    out = []
    for tag, rows_4w in by_tag_4w.items():
        rows_2w = by_tag_2w.get(tag, [])
        exp_4w, n_4w = _expectancy(rows_4w)
        exp_2w, n_2w = _expectancy(rows_2w)
        delta = (exp_2w - exp_4w) if (exp_4w is not None and exp_2w is not None) else None

        ci_4w = _win_ci_for_delta_test(rows_4w)
        ci_2w = _win_ci_for_delta_test(rows_2w)
        overlap = intervals_overlap(ci_4w, ci_2w)

        if n_2w < min_sample or n_4w < min_sample:
            action = "Insufficient"
        elif overlap is None:
            action = "Insufficient"
        elif overlap:
            action = "Keep"
        elif delta is not None and delta > 0:
            action = "Keep"  # diverged, but favorably — not what the spec means by "Investigate"
        elif delta is not None and delta < -0.15 and n_2w >= min_sample * 2:
            action = "Reduce confidence"  # large, well-sampled, unfavorable divergence
        else:
            action = "Investigate"

        out.append({
            "tag": tag,
            "expectancy_4w": exp_4w,
            "expectancy_2w": exp_2w,
            "delta": delta,
            "sample_4w": n_4w,
            "sample_2w": n_2w,
            "win_rate_ci_4w": ci_4w.to_dict(),
            "win_rate_ci_2w": ci_2w.to_dict(),
            "overlap": overlap,
            "action": action,
        })

    out.sort(key=lambda d: (d["delta"] is None, d["delta"] if d["delta"] is not None else 0))
    return out


def print_matrix(matrix: list[dict]) -> None:
    print("=" * 100)
    print(f"CALIBRATION MATRIX — {BASELINE_WEEKS}W baseline vs {RECENT_WEEKS}W recent, by tag")
    print("=" * 100)
    header = f"{'Tag':38s} {'4W Exp':>8s} {'2W Exp':>8s} {'Delta':>8s} {'N(4W/2W)':>10s} {'Action':>18s}"
    print(header)
    print("-" * len(header))
    for row in matrix:
        e4 = f"{row['expectancy_4w']:+.2f}R" if row["expectancy_4w"] is not None else "n/a"
        e2 = f"{row['expectancy_2w']:+.2f}R" if row["expectancy_2w"] is not None else "n/a"
        d = f"{row['delta']:+.2f}" if row["delta"] is not None else "n/a"
        n = f"{row['sample_4w']}/{row['sample_2w']}"
        print(f"{row['tag']:38s} {e4:>8s} {e2:>8s} {d:>8s} {n:>10s} {row['action']:>18s}")
    print(
        "\nReminder: 2W rows are a SUBSET of the 4W window (last two weeks of it), "
        "not an independent later sample — the Delta column compares a baseline to "
        "its own recent tail, matching the spec's C4W/C2W framing.\n"
    )


async def fetch_rows():
    async with async_session() as session:
        result = await session.execute(select(SignalOutcome))
        return list(result.scalars().all())


async def run(args) -> int:
    rows = await fetch_rows()
    if not rows:
        print("calibration_matrix: no rows in signal_outcomes yet.", file=sys.stderr)
        return 1
    matrix = compute_matrix(rows, args.min_sample)
    if args.json:
        print(json.dumps(matrix, indent=2, default=str))
    else:
        print_matrix(matrix)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--min-sample", type=int, default=DEFAULT_MIN_SAMPLE)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    sys.exit(asyncio.run(run(args)))


if __name__ == "__main__":
    main()
