"""
tools/stats.py — dependency-free statistical primitives for the gating
layer (step 4). No numpy/scipy: this repo's tooling convention
(tools/medistouch_retrain.py) is stdlib-only, and none of this needs
more than `math`.

Three things, because step 4 explicitly asks for intervals, not point
estimates:

  wilson_ci(wins, n)              -> CI on a win rate (binomial proportion)
  auc_with_ci(scores_outcomes)    -> confidence's discriminative power
                                      (win vs loss) + Hanley-McNeil CI
  pearson_ci(pairs)               -> confidence-vs-realized-R correlation
                                      + Fisher z-transform CI

Every function returns a `Stat` (point estimate, ci_low, ci_high, n) so
`intervals_overlap()` and everything in gating.py can treat all three the
same way regardless of which metric they came from.
"""
from __future__ import annotations

import math
from dataclasses import dataclass


@dataclass
class Stat:
    value: float | None
    ci_low: float | None
    ci_high: float | None
    n: int

    @property
    def is_estimable(self) -> bool:
        return self.value is not None and self.ci_low is not None and self.ci_high is not None

    def to_dict(self) -> dict:
        return {"value": self.value, "ci_low": self.ci_low, "ci_high": self.ci_high, "n": self.n}

    @staticmethod
    def from_dict(d: dict) -> "Stat":
        return Stat(value=d.get("value"), ci_low=d.get("ci_low"), ci_high=d.get("ci_high"), n=d.get("n", 0))

    @staticmethod
    def empty(n: int = 0) -> "Stat":
        return Stat(value=None, ci_low=None, ci_high=None, n=n)


def wilson_ci(successes: int, n: int, z: float = 1.96) -> Stat:
    """
    Wilson score interval for a binomial proportion (win rate). Preferred
    over the normal approximation for small/uneven samples — which is
    exactly the regime a biweekly cycle with a few dozen resolved trades
    per tag lives in. z=1.96 -> ~95% CI.
    """
    if n == 0:
        return Stat.empty(0)
    p = successes / n
    denom = 1 + z * z / n
    center = (p + z * z / (2 * n)) / denom
    half_width = (z / denom) * math.sqrt((p * (1 - p) / n) + (z * z / (4 * n * n)))
    return Stat(value=p, ci_low=max(0.0, center - half_width), ci_high=min(1.0, center + half_width), n=n)


def auc_with_ci(win_scores: list[float], loss_scores: list[float], z: float = 1.96) -> Stat:
    """
    AUC of `confidence` discriminating win vs loss, via the standard
    Mann-Whitney U relationship: AUC = P(a random win's confidence >
    a random loss's confidence), with ties counted as 0.5. Standard error
    via Hanley & McNeil (1982)'s closed-form approximation — no
    resampling, no scipy, and it's the textbook non-bootstrap CI for
    exactly this statistic.

    Deliberately requires BOTH classes present with n>=1 each; an AUC
    with only one class is undefined, not 0.5 or 1.0 by convention here —
    returning a fabricated point estimate would be worse than admitting
    "not estimable yet."
    """
    n1, n2 = len(win_scores), len(loss_scores)
    if n1 == 0 or n2 == 0:
        return Stat.empty(n1 + n2)

    total_pairs = 0.0
    for w in win_scores:
        for l in loss_scores:
            if w > l:
                total_pairs += 1.0
            elif w == l:
                total_pairs += 0.5
    auc = total_pairs / (n1 * n2)

    # Hanley-McNeil: Q1 = AUC / (2 - AUC), Q2 = 2*AUC^2 / (1 + AUC)
    q1 = auc / (2 - auc)
    q2 = (2 * auc * auc) / (1 + auc)
    variance = (
        auc * (1 - auc)
        + (n1 - 1) * (q1 - auc * auc)
        + (n2 - 1) * (q2 - auc * auc)
    ) / (n1 * n2)
    se = math.sqrt(max(variance, 0.0))
    half_width = z * se
    return Stat(value=auc, ci_low=max(0.0, auc - half_width), ci_high=min(1.0, auc + half_width), n=n1 + n2)


def pearson_ci(pairs: list[tuple[float, float]], z: float = 1.96) -> Stat:
    """
    Pearson correlation between confidence_at_signal and realized_r
    (resolved trades only), with a Fisher z-transform CI — the standard
    closed-form CI for a correlation coefficient, valid for n>=4.
    """
    n = len(pairs)
    if n < 4:
        return Stat.empty(n)

    xs = [p[0] for p in pairs]
    ys = [p[1] for p in pairs]
    mean_x, mean_y = sum(xs) / n, sum(ys) / n
    cov = sum((x - mean_x) * (y - mean_y) for x, y in pairs)
    var_x = sum((x - mean_x) ** 2 for x in xs)
    var_y = sum((y - mean_y) ** 2 for y in ys)
    denom = math.sqrt(var_x * var_y)
    if denom == 0:
        return Stat.empty(n)  # zero variance in one side — undefined, not 0

    r = cov / denom
    r = max(-0.999999, min(0.999999, r))  # guard atanh domain at the r=+/-1 edge
    z_r = math.atanh(r)
    se_z = 1 / math.sqrt(n - 3)
    z_low, z_high = z_r - z * se_z, z_r + z * se_z
    return Stat(value=r, ci_low=math.tanh(z_low), ci_high=math.tanh(z_high), n=n)


def intervals_overlap(a: Stat, b: Stat) -> bool | None:
    """
    True if two CIs overlap at all (-> "no significant change, don't
    act", per the gating spec). None if either isn't estimable yet
    (too little data — a decision here should treat that as "can't
    tell," not silently coerce it into either answer).
    """
    if not a.is_estimable or not b.is_estimable:
        return None
    return a.ci_low <= b.ci_high and b.ci_low <= a.ci_high


def direction(a: Stat, b: Stat) -> str | None:
    """
    Which way b moved relative to a, but ONLY meaningful once overlap()
    has already said the intervals genuinely don't overlap — this is
    "which side," not "how confident." Returns None if either isn't
    estimable.
    """
    if not a.is_estimable or not b.is_estimable:
        return None
    return "up" if b.value > a.value else "down" if b.value < a.value else "flat"
