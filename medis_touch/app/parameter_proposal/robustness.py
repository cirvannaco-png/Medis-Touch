from .models import RobustnessResult


def evaluate_robustness(candidate, evaluator, minimum_neighbor_ratio=0.85):
    neighbors = list(evaluator.evaluate_neighbors(candidate))
    if not neighbors:
        return RobustnessResult(False, 0.0, float("-inf"), float("-inf"), 1.0)
    objectives = [x.objective for x in neighbors]
    candidate_objective = evaluator.evaluate(candidate).objective
    worst = min(objectives)
    best = max(objectives)
    ratio = worst / candidate_objective if candidate_objective else 0.0
    return RobustnessResult(
        ratio >= minimum_neighbor_ratio,
        max(0.0, min(1.0, ratio)),
        worst,
        best,
        max(0.0, 1.0 - ratio),
    )
