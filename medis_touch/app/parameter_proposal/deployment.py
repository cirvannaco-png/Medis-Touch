"""Fail-closed deployment state machine for candidate configurations."""
from __future__ import annotations

from .models import DeploymentState

_ALLOWED: dict[DeploymentState, frozenset[DeploymentState]] = {
    DeploymentState.GENERATED: frozenset({DeploymentState.VALIDATED}),
    DeploymentState.VALIDATED: frozenset({DeploymentState.TESTED}),
    DeploymentState.TESTED: frozenset({DeploymentState.PENDING_APPROVAL}),
    DeploymentState.PENDING_APPROVAL: frozenset({DeploymentState.APPROVED}),
    DeploymentState.APPROVED: frozenset({DeploymentState.SCHEDULED}),
    DeploymentState.SCHEDULED: frozenset({DeploymentState.ACTIVE}),
    DeploymentState.ACTIVE: frozenset({DeploymentState.RETIRED, DeploymentState.ROLLED_BACK}),
    DeploymentState.RETIRED: frozenset(),
    DeploymentState.ROLLED_BACK: frozenset(),
}


def transition(current: DeploymentState, target: DeploymentState) -> DeploymentState:
    """Return target only for an explicitly permitted lifecycle transition."""
    if target not in _ALLOWED.get(current, frozenset()):
        raise ValueError(f"invalid deployment transition: {current.value} -> {target.value}")
    return target
