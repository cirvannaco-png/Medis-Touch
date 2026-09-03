from datetime import datetime, timezone
from uuid import uuid4

from .bounds import PARAMETERS
from .candidates import generate_candidates
from .gates import parameter_movement_ok, regime_gate, statistical_gate
from .models import Proposal
from .robustness import evaluate_robustness


class ParameterProposalEngine:
    def __init__(self, evaluator):
        self.evaluator = evaluator

    def propose_live(self, current):
        """Build proposals only from a real, replay-backed evaluator.

        ``propose`` remains useful for offline tests and tooling, but live
        callers must use this explicit entry point so a fake or baseline-only
        evaluator cannot accidentally create deployable recommendations.
        """
        if not (
            getattr(self.evaluator, "is_real_outcome_evaluator", False)
            and getattr(self.evaluator, "replay_backed", False)
        ):
            raise RuntimeError(
                "live proposals require OutcomeEvaluator backed by real "
                "outcomes and the actual EA replay"
            )
        return self.propose(current)

    def propose(self, current):
        baseline = self.evaluator.evaluate(current)
        proposals = []
        for candidate in generate_candidates(current, PARAMETERS):
            ok, _ = parameter_movement_ok(current, candidate, PARAMETERS)
            if not ok:
                continue
            evaluation = self.evaluator.evaluate(candidate)
            ok, _ = statistical_gate(baseline, evaluation)
            if not ok:
                continue
            ok, _ = regime_gate(baseline.by_regime, evaluation.by_regime)
            if not ok:
                continue
            robustness = evaluate_robustness(candidate, self.evaluator)
            if not robustness.stable:
                continue

            now = datetime.now(timezone.utc)
            proposal_id = "pp_" + now.strftime("%Y%m%d%H%M%S") + "_" + uuid4().hex[:10]
            proposals.append(
                Proposal(
                    proposal_id=proposal_id,
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
                )
            )
        return sorted(proposals, key=lambda p: p.candidate.objective, reverse=True)
