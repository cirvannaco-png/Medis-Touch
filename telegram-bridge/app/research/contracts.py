"""Canonical research contracts. These are deliberately broker-neutral and immutable-friendly."""
from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime
from hashlib import sha256
import json
from typing import Any, Literal

Outcome = Literal["win", "loss", "scratch", "no_fill", "ambiguous"]
Strategy = Literal["SMC", "Momentum", "MeanRev", "KeyLevel"]

@dataclass(frozen=True)
class SignalObservation:
    signal_id: str
    symbol: str
    timestamp: datetime
    regime: str
    session: str
    volatility: float
    smc_score: float
    momentum_score: float
    breakout_score: float
    mean_reversion_score: float
    keylevel_score: float
    smc_vote: int
    momentum_vote: int
    reversion_vote: int
    keylevel_vote: int
    agreement_count: int
    agreement_strength: float
    contradiction_count: int
    contradiction_type: str | None
    selected_direction: str
    ensemble_confidence: float
    entry: float
    sl: float
    tp: float
    rr: float
    spread: float
    execution_latency_ms: float | None
    outcome: Outcome | None = None
    realized_r: float | None = None
    mfe_r: float | None = None
    mae_r: float | None = None
    weight_version: str = "unknown"
    experiment_id: str = "live"
    data_snapshot: str = "unknown"

    def canonical(self) -> dict[str, Any]:
        d = asdict(self)
        d["timestamp"] = self.timestamp.isoformat()
        return d

    def fingerprint(self) -> str:
        payload = json.dumps(self.canonical(), sort_keys=True, separators=(",", ":"))
        return sha256(payload.encode()).hexdigest()

@dataclass(frozen=True)
class BookResult:
    experiment_id: str
    signal_id: str
    book: Literal["candidate", "smc_baseline", "strategy_diagnostics"]
    strategy: Strategy | None
    direction: str | None
    outcome: Outcome
    realized_r: float | None
    mfe_r: float | None
    mae_r: float | None
    hypothetical: bool
    metadata: dict[str, Any] = field(default_factory=dict)

@dataclass(frozen=True)
class Experiment:
    experiment_id: str
    name: str
    code_sha: str
    config_hash: str
    data_snapshot: str
    created_at: datetime
    train_start: datetime
    train_end: datetime
    oos_start: datetime
    oos_end: datetime
    walk_forward_id: str | None
    holdout_locked: bool


def canonical_hash(value: Any) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":"), default=str)
    return sha256(payload.encode()).hexdigest()
