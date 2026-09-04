import pytest

from app.parameter_proposal.deployment import transition
from app.parameter_proposal.models import DeploymentState


def test_deployment_follows_explicit_state_machine():
    state = DeploymentState.GENERATED
    for target in (
        DeploymentState.VALIDATED,
        DeploymentState.TESTED,
        DeploymentState.PENDING_APPROVAL,
        DeploymentState.APPROVED,
        DeploymentState.SCHEDULED,
        DeploymentState.EA_VALIDATED,
        DeploymentState.EA_ACKNOWLEDGED,
        DeploymentState.ACTIVE,
    ):
        state = transition(state, target)
    assert state is DeploymentState.ACTIVE
    assert transition(state, DeploymentState.ROLLED_BACK) is DeploymentState.ROLLED_BACK


def test_deployment_rejects_skipping_approval():
    with pytest.raises(ValueError, match="invalid deployment transition"):
        transition(DeploymentState.TESTED, DeploymentState.ACTIVE)


def test_deployment_rejects_activation_without_ea_ack():
    with pytest.raises(ValueError, match="invalid deployment transition"):
        transition(DeploymentState.SCHEDULED, DeploymentState.ACTIVE)
