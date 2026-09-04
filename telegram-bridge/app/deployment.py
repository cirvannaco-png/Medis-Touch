"""Shared deployment lifecycle rules for the Telegram bridge."""
from __future__ import annotations

from enum import Enum


class DeploymentState(str, Enum):
    GENERATED = "GENERATED"
    VALIDATED = "VALIDATED"
    TESTED = "TESTED"
    PENDING_APPROVAL = "PENDING_APPROVAL"
    APPROVED = "APPROVED"
    SCHEDULED = "SCHEDULED"
    EA_VALIDATED = "EA_VALIDATED"
    EA_ACKNOWLEDGED = "EA_ACKNOWLEDGED"
    ACTIVE = "ACTIVE"
    RETIRED = "RETIRED"
    ROLLED_BACK = "ROLLED_BACK"


_ALLOWED: dict[DeploymentState, frozenset[DeploymentState]] = {
    DeploymentState.GENERATED: frozenset({DeploymentState.VALIDATED}),
    DeploymentState.VALIDATED: frozenset({DeploymentState.TESTED}),
    DeploymentState.TESTED: frozenset({DeploymentState.PENDING_APPROVAL}),
    DeploymentState.PENDING_APPROVAL: frozenset({DeploymentState.APPROVED}),
    DeploymentState.APPROVED: frozenset({DeploymentState.SCHEDULED}),
    DeploymentState.SCHEDULED: frozenset({DeploymentState.EA_VALIDATED}),
    DeploymentState.EA_VALIDATED: frozenset({DeploymentState.EA_ACKNOWLEDGED}),
    DeploymentState.EA_ACKNOWLEDGED: frozenset({DeploymentState.ACTIVE}),
    DeploymentState.ACTIVE: frozenset({DeploymentState.RETIRED, DeploymentState.ROLLED_BACK}),
    DeploymentState.RETIRED: frozenset(),
    DeploymentState.ROLLED_BACK: frozenset(),
}


def transition(current: DeploymentState, target: DeploymentState) -> DeploymentState:
    """Return target only for an explicitly permitted lifecycle transition."""
    if target not in _ALLOWED.get(current, frozenset()):
        raise ValueError(f"invalid deployment transition: {current.value} -> {target.value}")
    return target
