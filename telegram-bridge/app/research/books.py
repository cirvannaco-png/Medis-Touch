"""Three-book experiment construction: candidate, SMC baseline, diagnostics."""
from __future__ import annotations
from typing import Callable, Iterable
from .contracts import BookResult, SignalObservation

STRATEGIES = ("SMC", "Momentum", "MeanRev", "KeyLevel")


def build_books(observations: Iterable[SignalObservation], evaluator: Callable[[SignalObservation, str], dict]) -> list[BookResult]:
    results: list[BookResult] = []
    for obs in observations:
        candidate = evaluator(obs, "ENSEMBLE")
        results.append(BookResult(obs.experiment_id, obs.signal_id, "candidate", None, obs.selected_direction, candidate["outcome"], candidate.get("realized_r"), candidate.get("mfe_r"), candidate.get("mae_r"), False))
        smc = evaluator(obs, "SMC")
        results.append(BookResult(obs.experiment_id, obs.signal_id, "smc_baseline", "SMC", smc.get("direction"), smc["outcome"], smc.get("realized_r"), smc.get("mfe_r"), smc.get("mae_r"), True))
        for strategy in STRATEGIES:
            r = evaluator(obs, strategy)
            results.append(BookResult(obs.experiment_id, obs.signal_id, "strategy_diagnostics", strategy, r.get("direction"), r["outcome"], r.get("realized_r"), r.get("mfe_r"), r.get("mae_r"), True))
    return results
