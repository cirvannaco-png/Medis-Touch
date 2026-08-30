"""
tools/gating.py — Step 4: the statistical gating layer.

Consumes a HISTORY of cycle reports — the exact dict shape
tools/metrics_engine.py's compute_report() produces — and decides
whether a candidate weight set should be promoted, held, or rolled back.
It never looks at signal_outcomes directly; it only ever looks at cycle
reports, which is what makes the "fill it with dummy data now, real data
displaces it later" approach sound: a synthetic cycle report and a real
one are structurally identical, so this module can't tell the
difference, and doesn't need to.

THE TWO RULES FROM THE SPEC, IMPLEMENTED LITERALLY:
  1. Overlapping CIs across consecutive cycles -> "no significant
     change, don't act." Divergent (non-overlapping) CIs are a
     candidate signal, not a verdict.
  2. Persistence: divergence has to point the SAME direction across
     >= MIN_PERSISTENCE consecutive cycles before promotion is allowed.
     One noisy fortnight can't flip a decision by itself.
  On genuine CONTRADICTION (cycle N says "up", cycle N+1 says "down",
  both non-overlapping) -> auto-fallback to last known-good, flagged,
  no attempt to reconcile. This is not a persistence failure (which is
  just "inconclusive, hold") — it's an active reversal, which the spec
  says should never be silently smoothed over.

CYCLE SOURCE TAGGING (this is the actual answer to "how do we swap
dummy data for real data without hacking it"):
  Every cycle passed in must carry {"source": "live" | "synthetic",
  "weight_version": str, "cycle_id": str}. decide() REFUSES to compute a
  live promotion decision from anything but an unbroken run of "live"
  cycles for the SAME weight_version — a synthetic cycle mixed into a
  live history raises, rather than silently contributing a data point.
  So the transition from dummy to real isn't a flag you flip: it's just
  that real cycles start satisfying decide()'s requirements and
  synthetic ones stop being usable for anything but rehearsing the code
  path. See tools/generate_synthetic_cycles.py for that rehearsal.

USAGE
    python tools/gating.py --history metrics_history/ --weight-version v2.11-candidate
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stats import Stat, direction, intervals_overlap  # noqa: E402

MIN_PERSISTENCE = 2  # consecutive same-direction divergent cycles required to promote
GATED_METRICS = ("win_rate", "confidence_auc", "confidence_r_correlation")


class GatingError(ValueError):
    """Raised when the input history can't support a real decision — e.g.
    a synthetic cycle mixed into what's supposed to be a live history.
    This is deliberately a hard error, not a warning: silently degrading
    to "decide anyway" is exactly the kind of quiet contamination the
    source-tagging exists to prevent."""


@dataclass
class MetricVerdict:
    metric: str
    prior: Stat
    latest: Stat
    overlap: bool | None       # None = not estimable yet
    moved: str | None          # "up" / "down" / "flat" / None


@dataclass
class Decision:
    action: str                 # "PROMOTE" | "HOLD" | "ROLLBACK" | "INSUFFICIENT_DATA"
    weight_version: str
    reasoning: list[str]
    metric_verdicts: list[MetricVerdict]
    cycles_considered: int

    def to_dict(self) -> dict:
        return {
            "action": self.action,
            "weight_version": self.weight_version,
            "reasoning": self.reasoning,
            "cycles_considered": self.cycles_considered,
            "metric_verdicts": [
                {
                    "metric": mv.metric,
                    "prior": mv.prior.to_dict(),
                    "latest": mv.latest.to_dict(),
                    "overlap": mv.overlap,
                    "moved": mv.moved,
                }
                for mv in self.metric_verdicts
            ],
        }


def _extract_stat(cycle: dict, weight_version: str, metric: str) -> Stat:
    by_wv = cycle.get("expectancy", {}).get("by_weight_version_stats", {})
    wv_block = by_wv.get(weight_version)
    if wv_block is None:
        return Stat.empty(0)
    return Stat.from_dict(wv_block.get(metric, {}))


def _validate_cycles(cycles: list[dict], weight_version: str) -> None:
    if not cycles:
        raise GatingError("empty cycle history — nothing to decide from.")
    sources = {c.get("source") for c in cycles}
    if "synthetic" in sources and "live" in sources:
        raise GatingError(
            "cycle history mixes synthetic and live cycles for a real "
            "decision. This is refused, not auto-filtered: filter to one "
            "source explicitly (e.g. pass --source live) so a synthetic "
            "rehearsal cycle can never silently count toward a real "
            "promotion. Use generate_synthetic_cycles.py output only to "
            "test this module's logic in isolation."
        )
    for c in cycles:
        if "source" not in c or "cycle_id" not in c:
            raise GatingError(
                f"cycle missing required 'source'/'cycle_id' tag: {c.get('cycle_id', '(untagged)')}. "
                "Every cycle report fed to this module must be tagged — see tools/cycle_store.py."
            )


def decide(cycles: list[dict], weight_version: str, min_persistence: int = MIN_PERSISTENCE) -> Decision:
    """
    `cycles` must be in chronological order (oldest first), already
    filtered to a single weight_version's history (or containing that
    weight_version's block via by_weight_version_stats — this function
    reads only that slice, but validates source-purity across the WHOLE
    list you pass, so pass exactly the cycles you intend to be compared).
    """
    _validate_cycles(cycles, weight_version)

    if len(cycles) < min_persistence + 1:
        return Decision(
            action="INSUFFICIENT_DATA",
            weight_version=weight_version,
            reasoning=[
                f"Only {len(cycles)} cycle(s) available; need at least "
                f"{min_persistence + 1} (one baseline + {min_persistence} "
                "for the persistence check) before any promote/rollback "
                "decision is possible. This is the expected, correct "
                "state in week one of live data — not an error."
            ],
            metric_verdicts=[],
            cycles_considered=len(cycles),
        )

    # Compare each consecutive pair on every gated metric.
    per_metric_directions: dict[str, list[str | None]] = {m: [] for m in GATED_METRICS}
    last_verdicts: list[MetricVerdict] = []
    reasoning: list[str] = []

    for i in range(1, len(cycles)):
        prior_cycle, latest_cycle = cycles[i - 1], cycles[i]
        for metric in GATED_METRICS:
            prior = _extract_stat(prior_cycle, weight_version, metric)
            latest = _extract_stat(latest_cycle, weight_version, metric)
            overlap = intervals_overlap(prior, latest)
            moved = direction(prior, latest) if overlap is False else None
            per_metric_directions[metric].append(moved)
            if i == len(cycles) - 1:  # keep only the most recent pair's verdicts for the report
                last_verdicts.append(MetricVerdict(metric, prior, latest, overlap, moved))

    # Persistence check: for each metric, look at the last `min_persistence`
    # pairwise comparisons — do they all agree on a non-None direction?
    contradiction_found = False
    persistent_moves: dict[str, str] = {}
    for metric in GATED_METRICS:
        recent = per_metric_directions[metric][-min_persistence:]
        non_none = [d for d in recent if d is not None]
        if len(non_none) < min_persistence:
            reasoning.append(
                f"{metric}: not enough consecutive divergent cycles yet "
                f"({len(non_none)}/{min_persistence}) — overlapping CIs "
                "count as 'no significant change,' not evidence either way."
            )
            continue
        if len(set(non_none)) > 1:
            contradiction_found = True
            reasoning.append(
                f"{metric}: CONTRADICTION — recent cycles disagree on "
                f"direction ({non_none}). Not a persistence failure; this "
                "is an active reversal and is never auto-reconciled."
            )
            continue
        persistent_moves[metric] = non_none[0]
        reasoning.append(f"{metric}: persistent '{non_none[0]}' across the last {min_persistence} cycles.")

    if contradiction_found:
        action = "ROLLBACK"
        reasoning.insert(0, "Genuine contradiction between cycles on at least one gated metric — "
                             "auto-fallback to last known-good weights, flagged for review.")
    elif persistent_moves and all(v == "down" for v in persistent_moves.values()):
        action = "ROLLBACK"
        reasoning.insert(0, "All persistently-moved metrics moved DOWN — candidate is regressing, not improving.")
    elif persistent_moves and any(v == "up" for v in persistent_moves.values()) and \
            all(v != "down" for v in persistent_moves.values()):
        action = "PROMOTE"
        reasoning.insert(0, "At least one metric persistently improved, none persistently regressed — "
                             "eligible for promotion (still requires the human tap-to-approve gate, step 5).")
    else:
        action = "HOLD"
        reasoning.insert(0, "No metric cleared the persistence bar in a clearly favorable direction — hold.")

    return Decision(
        action=action,
        weight_version=weight_version,
        reasoning=reasoning,
        metric_verdicts=last_verdicts,
        cycles_considered=len(cycles),
    )


def load_cycles_from_dir(path: str, weight_version: str | None, source: str | None) -> list[dict]:
    files = sorted(f for f in os.listdir(path) if f.endswith(".json"))
    cycles = []
    for fname in files:
        with open(os.path.join(path, fname)) as fh:
            c = json.load(fh)
        if weight_version and weight_version not in c.get("expectancy", {}).get("by_weight_version_stats", {}):
            continue
        if source and c.get("source") != source:
            continue
        cycles.append(c)
    cycles.sort(key=lambda c: c.get("generated_at", ""))
    return cycles


async def load_cycles_from_db(weight_version: str | None, source: str | None) -> list[dict]:
    """
    Same contract as load_cycles_from_dir(), reading telegram-bridge's
    CalibrationCycle table instead of a directory of JSON files. This is
    what production (app/calibration.py's scheduled run_cycle()) uses;
    this function exists on the CLI too so a decision can be re-run or
    inspected manually against the real database without waiting for the
    next scheduled cycle. Requires the bridge's `app` package — see
    tools/_pathutil.py.
    """
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from _pathutil import ensure_bridge_importable
    ensure_bridge_importable(__file__)
    from sqlalchemy import select

    from app.database import async_session
    from app.models import CalibrationCycle

    async with async_session() as session:
        stmt = select(CalibrationCycle).order_by(CalibrationCycle.generated_at.asc())
        if source:
            stmt = stmt.where(CalibrationCycle.source == source)
        result = await session.execute(stmt)
        rows = result.scalars().all()

    cycles = []
    for row in rows:
        c = dict(row.report_json)
        c["source"] = row.source
        c["cycle_id"] = row.cycle_id
        c.setdefault("generated_at", row.generated_at.isoformat() if row.generated_at else None)
        if weight_version and weight_version not in c.get("expectancy", {}).get("by_weight_version_stats", {}):
            continue
        cycles.append(c)
    return cycles


def print_decision(d: Decision) -> None:
    print("=" * 72)
    print(f"GATING DECISION — {d.weight_version}")
    print("=" * 72)
    print(f"Action:              {d.action}")
    print(f"Cycles considered:   {d.cycles_considered}")
    print("\nReasoning:")
    for line in d.reasoning:
        print(f"  - {line}")
    if d.metric_verdicts:
        print("\nMost recent cycle-pair, per metric:")
        for mv in d.metric_verdicts:
            ov = "overlap (no change)" if mv.overlap else ("DIVERGED" if mv.overlap is False else "not estimable")
            print(f"  {mv.metric:24s} {ov:22s} moved={mv.moved}")
            print(f"    prior:  {mv.prior}")
            print(f"    latest: {mv.latest}")
    print()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--history", help="directory of cycle JSON files (tools/cycle_store.py format)")
    parser.add_argument("--db", action="store_true", help="load cycles from the bridge's CalibrationCycle table instead of --history")
    parser.add_argument("--weight-version", required=True)
    parser.add_argument("--source", choices=["live", "synthetic"], help="filter to one source explicitly")
    parser.add_argument("--min-persistence", type=int, default=MIN_PERSISTENCE)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    if args.db == bool(args.history):
        print("gating: pass exactly one of --history <dir> or --db", file=sys.stderr)
        sys.exit(2)

    if args.db:
        import asyncio
        cycles = asyncio.run(load_cycles_from_db(args.weight_version, args.source))
    else:
        cycles = load_cycles_from_dir(args.history, args.weight_version, args.source)

    try:
        decision = decide(cycles, args.weight_version, args.min_persistence)
    except GatingError as e:
        print(f"gating: {e}", file=sys.stderr)
        sys.exit(2)

    if args.json:
        print(json.dumps(decision.to_dict(), indent=2, default=str))
    else:
        print_decision(decision)


if __name__ == "__main__":
    main()
