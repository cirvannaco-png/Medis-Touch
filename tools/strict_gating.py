"""Strict calibration gate layered on top of the existing persistence gate.

Promotion requires ALL of:
  1. minimum resolved observations in the latest candidate cycle;
  2. non-overlapping CI evidence already produced by tools/gating.py;
  3. a minimum practical effect size;
  4. explicit comparison against the approved baseline weight version;
  5. a passing temporal holdout (out-of-sample sanity check);
  6. the existing multi-cycle persistence rule.

This module never silently invents an OOS result. If the report has no
out_of_sample block or it is not passed in, promotion is refused.
"""
from __future__ import annotations

from gating import Decision, GatingError, decide

MIN_RESOLVED_LATEST = 30
MIN_EFFECT = {
    "win_rate": 0.05,
    "confidence_auc": 0.03,
    "confidence_r_correlation": 0.10,
}


def _stat(cycle: dict, weight_version: str, metric: str):
    return cycle.get("expectancy", {}).get("by_weight_version_stats", {}).get(weight_version, {}).get(metric, {})


def strict_decide(cycles: list[dict], weight_version: str, baseline_weight_version: str | None = None,
                  min_persistence: int = 2, min_resolved: int = MIN_RESOLVED_LATEST) -> Decision:
    base = decide(cycles, weight_version, min_persistence)
    if base.action != "PROMOTE":
        return base

    latest = cycles[-1]
    candidate_win = _stat(latest, weight_version, "win_rate")
    if int(candidate_win.get("n", 0)) < min_resolved:
        base.action = "HOLD"
        base.reasoning.insert(0, f"STRICT GATE: latest candidate sample is {candidate_win.get('n', 0)} resolved trades; minimum is {min_resolved}.")
        return base

    oos = latest.get("out_of_sample")
    if not isinstance(oos, dict) or not oos.get("passed"):
        base.action = "HOLD"
        base.reasoning.insert(0, "STRICT GATE: no passing temporal out-of-sample holdout is attached to the latest cycle.")
        return base

    if not baseline_weight_version:
        base.action = "HOLD"
        base.reasoning.insert(0, "STRICT GATE: baseline_weight_version is required; never compare a candidate against an implicit or guessed baseline.")
        return base

    baseline_block = latest.get("expectancy", {}).get("by_weight_version_stats", {}).get(baseline_weight_version)
    if not baseline_block:
        base.action = "HOLD"
        base.reasoning.insert(0, f"STRICT GATE: baseline {baseline_weight_version} is absent from the latest cycle; no baseline comparison is allowed.")
        return base

    favorable_effects = []
    regressions = []
    for metric, min_effect in MIN_EFFECT.items():
        cand = _stat(latest, weight_version, metric)
        base_stat = _stat(latest, baseline_weight_version, metric)
        cv, bv = cand.get("value"), base_stat.get("value")
        if cv is None or bv is None:
            continue
        effect = cv - bv
        if effect >= min_effect:
            favorable_effects.append(f"{metric} +{effect:.3f} >= +{min_effect:.3f}")
        elif effect <= -min_effect:
            regressions.append(f"{metric} {effect:.3f} <= -{min_effect:.3f}")

    if regressions or not favorable_effects:
        base.action = "HOLD"
        if regressions:
            base.reasoning.insert(0, "STRICT GATE: candidate materially regresses against the approved baseline: " + "; ".join(regressions))
        else:
            base.reasoning.insert(0, "STRICT GATE: candidate has not demonstrated a minimum practical effect against the approved baseline.")
        return base

    base.reasoning.insert(0, "STRICT GATE PASSED: sample, CI/persistence, practical effect, baseline comparison and temporal holdout all passed.")
    base.reasoning.extend(favorable_effects)
    return base
