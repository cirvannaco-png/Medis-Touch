from .models import Evaluation, RobustnessResult


def evaluate_robustness(candidate, evaluator, minimum_neighbor_ratio=0.85, candidate_evaluation: Evaluation | None = None):
    """Evaluate bounded neighbors while reusing the already-scored candidate."""
    neighbors = list(evaluator.evaluate_neighbors(candidate))
    if not neighbors:
        return RobustnessResult(False, 0.0, float("-inf"), float("-inf"), 1.0)
    candidate_objective = (
        candidate_evaluation.objective
        if candidate_evaluation is not None
        else evaluator.evaluate(candidate).objective
    )
    objectives = [x.objective for x in neighbors]
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
