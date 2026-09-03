from .models import ParameterSet, ParameterSpec


def parameter_movement_ok(
    baseline: ParameterSet,
    candidate: ParameterSet,
    specs: dict[str, ParameterSpec],
):
    failures = []
    for name, old in baseline.values.items():
        if name not in candidate.values:
            failures.append(f"{name}: missing")
            continue
        new = candidate.values[name]
        spec = specs[name]
        if spec.minimum is not None and new < spec.minimum:
            failures.append(f"{name}: below minimum")
        if spec.maximum is not None and new > spec.maximum:
            failures.append(f"{name}: above maximum")
        if isinstance(old, (int, float)) and isinstance(new, (int, float)):
            delta = abs(new - old)
            if spec.max_absolute_change is not None and delta > spec.max_absolute_change:
                failures.append(f"{name}: absolute change exceeds limit")
            if old != 0 and delta / abs(old) > spec.max_relative_change:
                failures.append(f"{name}: relative change exceeds limit")
    return not failures, failures


def statistical_gate(baseline, candidate, minimum_trades=300, minimum_improvement=0.05):
    failures = []
    if candidate.trades < minimum_trades:
        failures.append("insufficient_candidate_trades")
    if candidate.expectancy_r - baseline.expectancy_r < minimum_improvement:
        failures.append("expectancy_improvement_too_small")
    if candidate.profit_factor < 1.05:
        failures.append("candidate_profit_factor_too_low")
    return not failures, failures


def regime_gate(baseline_by_regime, candidate_by_regime, maximum_degradation=0.25):
    failures = []
    for regime, base in baseline_by_regime.items():
        cand = candidate_by_regime.get(regime)
        if cand is None:
            failures.append(f"{regime}: missing candidate evidence")
            continue
        if base > 0 and (base - cand) / base > maximum_degradation:
            failures.append(f"{regime}: degradation exceeds limit")
    return not failures, failures
