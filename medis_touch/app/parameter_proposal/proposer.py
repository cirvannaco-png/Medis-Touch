from datetime import datetime, timezone
from uuid import uuid4

from .bounds import PARAMETERS
from .candidates import generate_candidates
from .config.canonical import config_hash
from .config.schema import validate_parameter_set
from .gates import parameter_movement_ok, regime_gate, statistical_gate
from .models import DeploymentState, Proposal
from .robustness import evaluate_robustness
from .search_budget import SearchBudget, bounded


class ParameterProposalEngine:
    """Generate bounded challengers without doing work on the live tick path."""

    def __init__(self, evaluator, *, search_budget: SearchBudget | None = None):
        self.evaluator = evaluator
        self.search_budget = search_budget or SearchBudget()

    def propose_live(self, current):
        """Build deployable recommendations only from a real replay evaluator."""
        if not (
            getattr(self.evaluator, "is_real_outcome_evaluator", False)
            and getattr(self.evaluator, "replay_backed", False)
        ):
            raise RuntimeError(
                "live proposals require OutcomeEvaluator backed by real outcomes and the actual EA replay"
            )
        return self.propose(current)

    def propose(self, current):
        valid, failures = validate_parameter_set(current, specs=PARAMETERS)
        if not valid:
            raise ValueError("invalid current configuration: " + ", ".join(failures))

        baseline = self.evaluator.evaluate(current)
        statistical_survivors = []
        for candidate in bounded(
            generate_candidates(current, PARAMETERS), self.search_budget.max_candidates
        ):
            movement_ok, _ = parameter_movement_ok(current, candidate, PARAMETERS)
            if not movement_ok:
                continue
            candidate_evaluation = self.evaluator.evaluate(candidate)
            ok, _ = statistical_gate(baseline, candidate_evaluation)
            if ok:
                statistical_survivors.append((candidate, candidate_evaluation))

        # Cheap gates happen before expensive neighborhood replay. Only the
        # strongest statistical survivors consume the next compute budget.
        statistical_survivors.sort(key=lambda item: item[1].objective, reverse=True)
        proposals = []
        for rank, (candidate, evaluation) in enumerate(
            statistical_survivors[: self.search_budget.max_statistical_survivors], start=1
        ):
            ok, _ = regime_gate(baseline.by_regime, evaluation.by_regime)
            if not ok:
                continue
            robustness = evaluate_robustness(
                candidate, self.evaluator, candidate_evaluation=evaluation
            )
            if not robustness.stable:
                continue
            now = datetime.now(timezone.utc)
            proposals.append(
                Proposal(
                    proposal_id="pp_" + now.strftime("%Y%m%d%H%M%S") + "_" + uuid4().hex[:10],
                    parameter_set=candidate,
                    parent_version=current.parent_version,
                    created_at=now,
                    baseline=baseline,
                    candidate=evaluation,
                    robustness=robustness,
                    confidence=robustness.neighborhood_score,
                    reasons=(
                        "bounded improvement",
                        "statistical gate passed",
                        "regime gate passed",
                        "robustness gate passed",
                    ),
                    gates_passed=(
                        "parameter_bounds",
                        "parameter_movement",
                        "sample_size",
                        "statistical",
                        "regime",
                        "robustness",
                    ),
                    gates_failed=(),
                    status="PENDING_APPROVAL",
                    config_hash=config_hash(candidate.values),
                    validation_state=DeploymentState.VALIDATED,
                    search_rank=rank,
                )
            )
        return sorted(proposals, key=lambda p: p.candidate.objective, reverse=True)
