"""Temporal out-of-sample sanity validation for calibration candidates.

This is deliberately a temporal holdout, not a claim of full model
retraining OOS proof. The candidate version is split chronologically;
the later holdout is never used by the earlier segment. Promotion must
have a passing holdout before strict gating can approve it.
"""
from __future__ import annotations

from tools.stats import wilson_ci

RESOLVED = {"win", "loss", "scratch"}


def validate_temporal_holdout(rows, weight_version: str, train_fraction: float = 0.70,
                              min_train: int = 30, min_test: int = 15) -> dict:
    candidate = [r for r in rows if r.weight_version == weight_version and r.outcome in RESOLVED]
    candidate.sort(key=lambda r: r.received_at)

    n = len(candidate)
    if n < min_train + min_test:
        return {
            "passed": False,
            "reason": f"insufficient resolved trades for temporal holdout: {n} < {min_train + min_test}",
            "resolved_count": n,
            "train_count": 0,
            "holdout_count": 0,
        }

    split = max(min_train, int(n * train_fraction))
    split = min(split, n - min_test)
    train = candidate[:split]
    holdout = candidate[split:]

    wins = sum(1 for r in holdout if r.outcome == "win")
    losses = sum(1 for r in holdout if r.outcome == "loss")
    avg_r_values = [r.realized_r for r in holdout if r.realized_r is not None]
    avg_r = (sum(avg_r_values) / len(avg_r_values)) if avg_r_values else None
    ci = wilson_ci(wins, len(holdout))

    # Conservative pass: holdout must have enough observations, positive
    # average realized R, and a win-rate point estimate above 50%.
    # We do not require the lower CI bound to exceed 50% here because that
    # would be unrealistically strict for a 15-50 trade holdout; strict
    # gating separately enforces the minimum effect and persistence rules.
    passed = (
        len(holdout) >= min_test
        and avg_r is not None
        and avg_r > 0.0
        and ci.value is not None
        and ci.value > 0.50
        and wins > 0
        and losses > 0
    )

    return {
        "passed": passed,
        "reason": "pass" if passed else "holdout failed positive-expectancy/win-rate sanity checks",
        "resolved_count": n,
        "train_count": len(train),
        "holdout_count": len(holdout),
        "holdout_win_rate": ci.to_dict(),
        "holdout_avg_r": avg_r,
    }
