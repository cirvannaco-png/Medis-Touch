"""
tools/walk_forward.py — step 3, the part that's honestly buildable
without an MT5 environment.

THE REFRAMING THAT MAKES THIS POSSIBLE: the spec's requirement was
"reuse the actual EA's closed-bar signal logic (not a reimplementation)
so lookahead bias can't creep back in." tools/metrics_engine.py already
only ever reads `signal_outcomes` — which OutcomeTracker.mqh populates
by running the EA's OWN production signal/decision code bar-by-bar,
live, not a Python reimplementation of it. So a walk-forward validation
that splits an already-elapsed calendar window into an older TRAIN
portion and a more-recent HOLDOUT portion, and compares expectancy
between them, satisfies "not a reimplementation" by construction — it's
analyzing what the real EA actually decided, not simulating what it
might have decided.

WHAT THIS DOES NOT DO, AND WHY: it cannot compress years of history into
a five-minute run the way an MT5 Strategy Tester batch could — it only
ever sees dates the EA has actually been live and posting to
`signal_outcomes` for. Building an automated Strategy-Tester-driver here
instead was considered and deliberately not done: that would mean
writing MQL5/terminal automation glue I have no way to run or verify in
this environment, unlike every other piece of this system, which was
tested against a real (if small) database before being handed over. A
plausible-looking but unverified Tester-automation script is a worse
outcome than an honest gap. If/when you want that path, the natural
next step is exporting one Strategy Tester run's OutcomeTracker CSV for
a known historical window and building ingest_tester_csv() below against
its ACTUAL column layout — not guessed in advance.

USAGE
    python tools/walk_forward.py --weight-version v2.11-baseline
    python tools/walk_forward.py --weight-version v2.11-baseline --reference-weeks 4 --holdout-weeks 1 --json
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from datetime import datetime, timedelta, timezone

_TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
if _TOOLS_DIR not in sys.path:
    sys.path.insert(0, _TOOLS_DIR)
from _pathutil import ensure_bridge_importable  # noqa: E402
ensure_bridge_importable(__file__)

from sqlalchemy import select  # noqa: E402

from app.database import async_session  # noqa: E402
from app.models import SignalOutcome  # noqa: E402
from metrics_engine import compute_report  # noqa: E402
from stats import intervals_overlap, wilson_ci  # noqa: E402

RESOLVED_OUTCOMES = {"win", "loss", "scratch"}


def split_train_holdout(rows, reference_weeks: int = 4, holdout_weeks: int = 1,
                          now: datetime | None = None) -> tuple[list, list]:
    """
    TRAIN = the older part of the reference window (what the weight set
    was effectively observed/tuned against). HOLDOUT = the most recent
    `holdout_weeks` of it — the portion that came LAST, chronologically,
    within the same window. This is the "at minimum validate each new
    weight set against the most recent portion of the window it wasn't
    primarily fit to" fallback the spec explicitly allows for when a
    stricter internal train/test split isn't practical.
    """
    if now is None:
        now = max((r.received_at for r in rows if r.received_at), default=datetime.now(timezone.utc))
    reference_start = now - timedelta(weeks=reference_weeks)
    holdout_start = now - timedelta(weeks=holdout_weeks)

    train, holdout = [], []
    for r in rows:
        if not r.received_at or r.received_at < reference_start:
            continue
        (holdout if r.received_at >= holdout_start else train).append(r)
    return train, holdout


def compute_walk_forward_report(rows, weight_version: str, reference_weeks: int = 4,
                                  holdout_weeks: int = 1) -> dict:
    tagged = [r for r in rows if r.weight_version == weight_version]
    train, holdout = split_train_holdout(tagged, reference_weeks, holdout_weeks)

    train_resolved = [r for r in train if r.outcome in RESOLVED_OUTCOMES]
    holdout_resolved = [r for r in holdout if r.outcome in RESOLVED_OUTCOMES]

    train_ci = wilson_ci(sum(1 for r in train_resolved if r.outcome == "win"), len(train_resolved))
    holdout_ci = wilson_ci(sum(1 for r in holdout_resolved if r.outcome == "win"), len(holdout_resolved))
    overlap = intervals_overlap(train_ci, holdout_ci)

    return {
        "weight_version": weight_version,
        "reference_weeks": reference_weeks,
        "holdout_weeks": holdout_weeks,
        "train": compute_report(train) if train else None,
        "holdout": compute_report(holdout) if holdout else None,
        "train_win_rate_ci": train_ci.to_dict(),
        "holdout_win_rate_ci": holdout_ci.to_dict(),
        "overlap": overlap,
        "verdict": (
            "insufficient_data" if overlap is None else
            "consistent" if overlap else
            "diverged"
        ),
    }


def ingest_tester_csv(path: str) -> list:
    """
    NOT YET IMPLEMENTED. Placeholder for validating against a deeper
    historical window than the EA has actually been live for, by feeding
    in one Strategy Tester run's OutcomeTracker CSV export.

    Deliberately raises rather than guessing a column layout: writing a
    parser against an assumed CSV shape I've never seen a real sample of
    would be exactly the kind of unverified-and-likely-wrong code this
    module's docstring explains was avoided elsewhere. Export one real
    Tester run's CSV first, then this function gets written against its
    actual header row, not a guess.
    """
    raise NotImplementedError(
        "ingest_tester_csv() is an intentional stub — see this function's "
        "docstring and the module docstring's 'WHAT THIS DOES NOT DO' section."
    )


def print_walk_forward(report: dict) -> None:
    print("=" * 88)
    print(f"WALK-FORWARD VALIDATION — {report['weight_version']} "
          f"({report['reference_weeks']}W reference, last {report['holdout_weeks']}W as holdout)")
    print("=" * 88)
    print(f"Verdict: {report['verdict']}")
    print(f"Train win rate:   {_fmt_ci(report['train_win_rate_ci'])}")
    print(f"Holdout win rate: {_fmt_ci(report['holdout_win_rate_ci'])}")
    if report["verdict"] == "insufficient_data":
        print("\nNot enough resolved trades in one or both windows yet to compare — "
              "expected while the EA is newly live or the weight_version is newly promoted.")
    elif report["verdict"] == "diverged":
        print("\nHoldout performance diverges from the training window — treat this weight "
              "set as NOT validated yet; investigate before trusting it going forward.")
    else:
        print("\nHoldout performance is consistent with the training window — no evidence "
              "of overfitting to the older portion of the reference window.")
    print()


def _fmt_ci(d: dict) -> str:
    if d.get("value") is None:
        return f"n/a (n={d.get('n', 0)})"
    return f"{d['value']*100:.1f}% [{d['ci_low']*100:.1f}%, {d['ci_high']*100:.1f}%] (n={d['n']})"


async def run(args) -> int:
    async with async_session() as session:
        result = await session.execute(select(SignalOutcome))
        rows = list(result.scalars().all())

    if not rows:
        print("walk_forward: no rows in signal_outcomes yet.", file=sys.stderr)
        return 1

    report = compute_walk_forward_report(rows, args.weight_version, args.reference_weeks, args.holdout_weeks)
    if args.json:
        print(json.dumps(report, indent=2, default=str))
    else:
        print_walk_forward(report)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--weight-version", required=True)
    parser.add_argument("--reference-weeks", type=int, default=4)
    parser.add_argument("--holdout-weeks", type=int, default=1)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    sys.exit(asyncio.run(run(args)))


if __name__ == "__main__":
    main()
