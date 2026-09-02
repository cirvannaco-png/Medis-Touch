"""
Calibration robustness gating.

Handbook section 14. Directly addresses the example given: "17 trades
with a 64.7% win rate is weak evidence of durable edge." This module
doesn't just compute a win rate — it computes a confidence interval
around it and refuses to promote a strategy/calibration update unless
the sample clears a minimum size AND the interval doesn't overlap an
uninformative baseline (e.g. 50% for a binary win/loss, or whatever
your actual baseline should be for R-multiple-based outcomes).

Section 14 also requires: "Two-week recalibration must not silently
overwrite or contaminate the previous four-week baseline" — handled
here by CalibrationStore never mutating a baseline in place; it only
ever appends a new versioned snapshot.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from datetime import datetime


@dataclass(frozen=True)
class WilsonInterval:
    lower: float
    upper: float
    point_estimate: float


def wilson_score_interval(successes: int, n: int, *, z: float = 1.96) -> WilsonInterval:
    """95% Wilson score interval by default (z=1.96). Preferred over the
    naive normal-approximation interval for small samples — a plain
    Wald interval on 17 trades will understate uncertainty and can even
    produce bounds outside [0, 1].
    """
    if n == 0:
        return WilsonInterval(0.0, 1.0, 0.5)
    p_hat = successes / n
    denom = 1 + z**2 / n
    center = (p_hat + z**2 / (2 * n)) / denom
    margin = (z * math.sqrt((p_hat * (1 - p_hat) / n) + (z**2 / (4 * n**2)))) / denom
    return WilsonInterval(lower=max(0.0, center - margin), upper=min(1.0, center + margin), point_estimate=p_hat)


@dataclass(frozen=True)
class CalibrationVerdict:
    promotable: bool
    reasons: list[str]
    sample_size: int
    win_rate: float
    interval: WilsonInterval


@dataclass(frozen=True)
class CalibrationGateConfig:
    min_resolved_trades: int = 100
    baseline_win_rate: float = 0.50
    require_interval_excludes_baseline: bool = True
    min_effect_size: float = 0.03  # point estimate must clear baseline by this much
    require_out_of_sample: bool = True


def evaluate_calibration(
    *,
    resolved_trades: int,
    wins: int,
    out_of_sample_resolved_trades: int = 0,
    out_of_sample_wins: int = 0,
    config: CalibrationGateConfig | None = None,
) -> CalibrationVerdict:
    """Refuses promotion unless: minimum sample size, a confidence
    interval that doesn't overlap the baseline, a minimum effect size,
    and (if configured) a separate out-of-sample sample that also
    clears its own bar. This directly implements the handbook's list:
    minimum resolved trades, confidence intervals, effect size, baseline
    comparison, out-of-sample validation, multiple-cycle confirmation
    (the caller is responsible for calling this once per cycle and
    requiring N consecutive passes for "multiple-cycle confirmation" —
    that's a caller-level policy, not something a single evaluation can
    determine on its own).
    """
    # Resolved here, not at the function-definition boundary — a
    # default-arg instance is built once at import time and shared
    # across every call. CalibrationGateConfig is frozen so this was
    # never actually mutation-unsafe, but ruff (B008) can't prove that
    # in general, and constructing fresh per-call costs nothing.
    if config is None:
        config = CalibrationGateConfig()
    reasons: list[str] = []
    interval = wilson_score_interval(wins, resolved_trades) if resolved_trades else WilsonInterval(0, 1, 0.5)
    win_rate = wins / resolved_trades if resolved_trades else 0.0

    if resolved_trades < config.min_resolved_trades:
        reasons.append(
            f"only {resolved_trades} resolved trades, need >= {config.min_resolved_trades}"
        )

    if config.require_interval_excludes_baseline and interval.lower <= config.baseline_win_rate:
        reasons.append(
            f"95% CI lower bound {interval.lower:.3f} does not clear baseline "
            f"{config.baseline_win_rate:.3f} — cannot rule out no-edge"
        )

    if (win_rate - config.baseline_win_rate) < config.min_effect_size:
        reasons.append(
            f"effect size {win_rate - config.baseline_win_rate:.3f} below "
            f"minimum {config.min_effect_size:.3f}"
        )

    if config.require_out_of_sample:
        if out_of_sample_resolved_trades < config.min_resolved_trades:
            reasons.append(
                f"out-of-sample only has {out_of_sample_resolved_trades} trades, "
                f"need >= {config.min_resolved_trades}"
            )
        else:
            oos_interval = wilson_score_interval(out_of_sample_wins, out_of_sample_resolved_trades)
            if oos_interval.lower <= config.baseline_win_rate:
                reasons.append("out-of-sample CI does not clear baseline")

    return CalibrationVerdict(
        promotable=not reasons,
        reasons=reasons,
        sample_size=resolved_trades,
        win_rate=win_rate,
        interval=interval,
    )


@dataclass
class CalibrationSnapshot:
    snapshot_id: str
    window_label: str  # e.g. "2-week" | "4-week-baseline"
    created_at: datetime
    verdict: CalibrationVerdict
    superseded: bool = False


@dataclass
class CalibrationStore:
    """Append-only. A new 2-week recalibration never overwrites the
    4-week baseline snapshot — it's stored alongside it, and only an
    explicit, separate "promote to baseline" action (not shown here,
    left to your ops workflow) changes what's used live.
    """

    snapshots: list[CalibrationSnapshot] = field(default_factory=list)

    def add(self, snapshot: CalibrationSnapshot) -> None:
        self.snapshots.append(snapshot)

    def current_baseline(self, window_label: str = "4-week-baseline") -> CalibrationSnapshot | None:
        candidates = [s for s in self.snapshots if s.window_label == window_label and not s.superseded]
        return candidates[-1] if candidates else None
