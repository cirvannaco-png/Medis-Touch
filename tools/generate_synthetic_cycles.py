"""
tools/generate_synthetic_cycles.py — fabricates cycle reports matching
metrics_engine.compute_report()'s EXACT schema, so gating.py can be
tested end-to-end today, before any live signal_outcomes data exists.

These are clearly tagged source="synthetic" (see cycle_store.py) and
gating.py hard-refuses to let a synthetic cycle count toward a real
decision. Their only job is to rehearse the gating LOGIC — persistence,
overlap detection, contradiction handling — against known, controllable
inputs, the way you'd write unit tests with fabricated fixtures.

Three scenarios, because "does the logic work" needs more than one
happy path:

  improving   — win_rate/AUC climb cycle over cycle -> should PROMOTE
                once persistence clears
  regressing  — same, but declining -> should ROLLBACK
  noisy       — bounces around with heavy overlap -> should HOLD /
                INSUFFICIENT_DATA, never falsely promote on noise

USAGE
    python tools/generate_synthetic_cycles.py --scenario improving \\
        --weight-version SYNTHETIC-TEST --cycles 4 --history /tmp/synthetic_history/
    python tools/gating.py --history /tmp/synthetic_history/ \\
        --weight-version SYNTHETIC-TEST --source synthetic
"""
from __future__ import annotations

import argparse
import os
import random
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cycle_store import save_cycle  # noqa: E402
from stats import auc_with_ci, pearson_ci, wilson_ci  # noqa: E402


def _fake_resolved_stats(win_rate_target: float, n: int, seed: int) -> dict:
    """
    Builds a plausible (win_scores, loss_scores, pairs) population that
    actually produces win_rate_target when run through the real stats.py
    functions — not hand-typed CI numbers. This matters: it means
    gating.py is being tested against numbers that went through the same
    math a real cycle's numbers would, not against fabricated CIs that
    might not be internally consistent.
    """
    rng = random.Random(seed)
    wins = int(round(n * win_rate_target))
    losses = n - wins
    # Winners skew toward higher confidence, losers toward lower — enough
    # to give confidence_auc a real, non-degenerate value.
    win_scores = [max(0, min(100, rng.gauss(68, 12))) for _ in range(wins)]
    loss_scores = [max(0, min(100, rng.gauss(52, 12))) for _ in range(losses)]
    pairs = [(s, rng.gauss(0.8, 0.6)) for s in win_scores] + [(s, rng.gauss(-0.9, 0.6)) for s in loss_scores]

    return {
        "win_rate": wilson_ci(wins, n).to_dict(),
        "confidence_auc": auc_with_ci(win_scores, loss_scores).to_dict(),
        "confidence_r_correlation": pearson_ci(pairs).to_dict(),
    }


def _fake_cycle_report(weight_version: str, win_rate: float, n: int, seed: int, when: datetime) -> dict:
    stats = _fake_resolved_stats(win_rate, n, seed)
    return {
        "generated_at": when.isoformat(),
        "coverage": {
            "total_signals": n + int(n * 0.15),
            "no_fill_count": int(n * 0.15),
            "no_fill_rate": 0.15,
            "ambiguous_count": 0,
            "directional_bias": {},
            "by_regime": {},
            "by_session": {},
            "by_weight_version": {},
        },
        "expectancy": {
            "resolved_count": n,
            "overall_win_rate": win_rate,
            "overall_avg_r": None,
            "overall_stats": stats,
            "by_weight_version_stats": {weight_version: stats},
            "by_regime": {},
            "by_session": {},
            "by_sweep_grade": {},
            "by_htf_ob_aligned": {},
            "by_weight_version": {},
            "realized_r_by_confidence_decile": {},
        },
    }


SCENARIOS = {
    # win_rate per cycle, oldest -> newest
    "improving": [0.42, 0.46, 0.55, 0.61],
    "regressing": [0.58, 0.53, 0.44, 0.39],
    "noisy": [0.50, 0.53, 0.48, 0.51],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scenario", choices=list(SCENARIOS), default="improving")
    parser.add_argument("--weight-version", default="SYNTHETIC-TEST")
    parser.add_argument("--cycles", type=int, default=None, help="defaults to the scenario's built-in length")
    parser.add_argument("--n-per-cycle", type=int, default=60, help="resolved trades per fabricated cycle")
    parser.add_argument("--history", required=True)
    args = parser.parse_args()

    win_rates = SCENARIOS[args.scenario]
    if args.cycles:
        win_rates = (win_rates * ((args.cycles // len(win_rates)) + 1))[: args.cycles]

    base_time = datetime.now(timezone.utc) - timedelta(days=14 * len(win_rates))
    for i, wr in enumerate(win_rates):
        when = base_time + timedelta(days=14 * i)
        report = _fake_cycle_report(args.weight_version, wr, args.n_per_cycle, seed=1000 + i, when=when)
        path = save_cycle(report, source="synthetic", history_dir=args.history)
        print(f"[{args.scenario}] cycle {i + 1}/{len(win_rates)} win_rate={wr:.0%} -> {path}")

    print(
        f"\n{len(win_rates)} synthetic '{args.scenario}' cycles written to {args.history}. "
        f"Try: python tools/gating.py --history {args.history} "
        f"--weight-version {args.weight_version} --source synthetic"
    )


if __name__ == "__main__":
    main()
