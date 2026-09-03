"""Application-level registry contracts for optimizer persistence."""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from .config.canonical import config_hash
from .config.schema import validate_parameter_set
from .models import DeploymentState, ParameterSet


def build_registry_record(
    parameter_set: ParameterSet,
    *,
    provenance: dict[str, Any],
    validation_state: DeploymentState = DeploymentState.GENERATED,
) -> dict[str, Any]:
    """Build an immutable persistence payload after fail-closed validation."""
    valid, failures = validate_parameter_set(parameter_set)
    if not valid:
        raise ValueError("invalid parameter set: " + ", ".join(failures))
    if not isinstance(provenance, dict) or not provenance:
        raise ValueError("provenance must be a non-empty mapping")
    return {
        "config_hash": config_hash(parameter_set.values),
        "parent_version": parameter_set.parent_version,
        "parameters_json": parameter_set.values,
        "provenance_json": provenance,
        "validation_state": validation_state.value,
        "created_at": datetime.now(timezone.utc),
    }
