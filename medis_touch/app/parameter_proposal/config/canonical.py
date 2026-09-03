"""Deterministic serialization and identity for deployable configurations."""
from __future__ import annotations

import hashlib
import json
from typing import Any


def _normalise(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(k): _normalise(value[k]) for k in sorted(value)}
    if isinstance(value, (list, tuple)):
        return [_normalise(item) for item in value]
    if isinstance(value, float):
        if value != value or value in (float("inf"), float("-inf")):
            raise ValueError("configuration contains a non-finite float")
        return float(format(value, ".15g"))
    if hasattr(value, "value"):
        return _normalise(value.value)
    return value


def canonical_json(values: dict[str, Any]) -> str:
    """Return the only JSON representation allowed for config hashing."""
    return json.dumps(
        _normalise(values),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    )


def config_hash(values: dict[str, Any]) -> str:
    """Return a SHA-256 identity for the canonical parameter payload."""
    return hashlib.sha256(canonical_json(values).encode("utf-8")).hexdigest()
