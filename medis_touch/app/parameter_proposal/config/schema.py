"""Fail-closed validation for parameter configurations."""
from __future__ import annotations

from typing import Any

from ..bounds import PARAMETERS
from ..models import ParameterSet


def validate_parameter_set(parameter_set: ParameterSet, *, specs=None) -> tuple[bool, tuple[str, ...]]:
    specs = specs or PARAMETERS
    failures: list[str] = []
    if not parameter_set.parent_version or len(parameter_set.parent_version) > 128:
        failures.append("parent_version_invalid")

    expected = set(specs)
    actual = set(parameter_set.values)
    for missing in sorted(expected - actual):
        failures.append(f"missing:{missing}")
    for unknown in sorted(actual - expected):
        failures.append(f"unknown:{unknown}")

    for name, spec in specs.items():
        if name not in parameter_set.values:
            continue
        value: Any = parameter_set.values[name]
        if spec.kind == "int" and (isinstance(value, bool) or not isinstance(value, int)):
            failures.append(f"{name}:not_int")
            continue
        if spec.kind == "float" and (isinstance(value, bool) or not isinstance(value, (int, float))):
            failures.append(f"{name}:not_float")
            continue
        if spec.minimum is not None and value < spec.minimum:
            failures.append(f"{name}:below_minimum")
        if spec.maximum is not None and value > spec.maximum:
            failures.append(f"{name}:above_maximum")
        if spec.step:
            origin = spec.minimum if spec.minimum is not None else 0
            steps = (value - origin) / spec.step
            if abs(steps - round(steps)) > 1e-9:
                failures.append(f"{name}:invalid_step")
    return not failures, tuple(failures)
