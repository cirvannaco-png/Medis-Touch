"""
Canonical TradeSetup contract and signal lifecycle.

Implements handbook sections 3 ("Canonical TradeSetup") and 6
("Continuous Signal Lifecycle").

Core invariant (section 3): `invalidation` and `stop_loss` are separate
semantics. `invalidation` is where the strategy's THESIS is proven wrong.
`stop_loss` is the actual protective order sent to the broker, and may
sit past invalidation to account for execution/ATR buffer. Example from
the handbook: entry 3350, invalidation 3347, SL 3346.

NOTE ON SCOPE: this module implements the *contract* and the *lifecycle
state machine* exactly as specified. It does not implement the
strategy-specific detection logic (momentum/breakout detection, mean
reversion extension detection, key-level identification, SMC structure
analysis) — that logic lives in your MT5 EA / strategy layer and depends
on market data structures this repo doesn't currently expose to me.
Wire `MomentumBreakoutEngine.generate()` etc. below to your real
detectors; the shape of what they must return is enforced here.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum


class OrderType(str, Enum):
    BUY = "BUY"
    SELL = "SELL"


class SignalStatus(str, Enum):
    ACTIVE = "ACTIVE"
    INVALIDATED = "INVALIDATED"
    EXPIRED = "EXPIRED"
    STALE = "STALE"
    SUPERSEDED = "SUPERSEDED"
    TP1_REACHED = "TP1_REACHED"
    TP2_REACHED = "TP2_REACHED"
    COMPLETED = "COMPLETED"


@dataclass
class SetupReasons:
    """Free-form human-readable reasons, shown in the Telegram message."""

    items: list[str] = field(default_factory=list)

    def add(self, reason: str) -> None:
        self.items.append(reason)


@dataclass
class TradeSetup:
    """Mirrors the `struct TradeSetup` in handbook section 3 exactly.

    invalidation and stop_loss are DELIBERATELY separate fields.
    Never collapse them into one — that was the bug the handbook calls
    out in section 4 ("the existing engine foundation must be changed
    so invalidation is persisted independently rather than being
    silently used as stop_loss").
    """

    type: OrderType
    entry_top: float
    entry_bottom: float

    # Strategy thesis boundary — where the IDEA is wrong.
    invalidation: float

    # Actual executable protective order — where the ORDER exits.
    stop_loss: float

    tp1: float
    tp2: float
    final_tp: float

    confidence: float  # 0.0-1.0 or 0-100, pick one convention and enforce it

    creation_time: datetime
    expiry_time: datetime | None = None
    active: bool = True

    reasons: SetupReasons = field(default_factory=SetupReasons)
    calibrated_probability: float | None = None
    calibration_sample: int | None = None

    def __post_init__(self) -> None:
        # Cheap sanity checks that would otherwise silently produce a
        # broken signal. These do NOT replace the fail-closed execution
        # validation in execution_validation.py — that's a separate,
        # broker/symbol-metadata-aware gate.
        if self.entry_top < self.entry_bottom:
            raise ValueError("entry_top must be >= entry_bottom")
        if self.type == OrderType.BUY and self.stop_loss >= self.entry_bottom:
            raise ValueError("BUY stop_loss must be below entry range")
        if self.type == OrderType.SELL and self.stop_loss <= self.entry_top:
            raise ValueError("SELL stop_loss must be above entry range")


@dataclass
class Signal:
    """The persisted, evolving record a TradeSetup becomes once emitted.

    Separate from TradeSetup because TradeSetup is the strategy engine's
    OUTPUT contract; Signal is the STATEFUL row that the lifecycle state
    machine, Telegram renderer, and copy-trading gate all read/write.
    """

    signal_id: str
    setup: TradeSetup
    status: SignalStatus = SignalStatus.ACTIVE
    invalidated_at: datetime | None = None
    invalidation_reason: str | None = None
    superseded_by: str | None = None
    tp1_reached_at: datetime | None = None
    tp2_reached_at: datetime | None = None
    completed_at: datetime | None = None

    @property
    def direction(self) -> OrderType:
        return self.setup.type

    @property
    def expires_at(self) -> datetime | None:
        return self.setup.expiry_time

    @property
    def invalidation(self) -> float:
        return self.setup.invalidation


def crosses_invalidation(direction: OrderType, market_price: float, invalidation: float) -> bool:
    if direction == OrderType.BUY:
        return market_price <= invalidation
    return market_price >= invalidation


def entry_is_stale(signal: Signal, market_price: float, *, max_drift_bp: float = 0.0) -> bool:
    """Placeholder staleness check.

    Handbook: "entry conditions cease -> STALE". What counts as "cease"
    is strategy-specific (e.g. price has drifted too far past the entry
    zone without triggering, or the setup's supporting structure has
    been invalidated by a *later* bar without formally crossing
    `invalidation`). Wire this to your real per-strategy staleness rule;
    this default only flags price that has moved through the entire
    entry zone without filling and past a drift tolerance.
    """
    top, bottom = signal.setup.entry_top, signal.setup.entry_bottom
    if bottom <= market_price <= top:
        return False
    if max_drift_bp <= 0:
        return False
    width = max(top - bottom, 1e-9)
    drift = min(abs(market_price - top), abs(market_price - bottom))
    return drift > width * (max_drift_bp / 10_000)


def update_target_progress(signal: Signal, market_price: float, now: datetime) -> None:
    """Advances ACTIVE -> TP1_REACHED -> TP2_REACHED -> COMPLETED.

    Mutates `signal` in place, matching the pseudocode's mutation style
    in handbook section 6.
    """
    s = signal.setup
    hit = (
        (lambda level: market_price >= level)
        if s.type == OrderType.BUY
        else (lambda level: market_price <= level)
    )

    if signal.status == SignalStatus.ACTIVE and hit(s.tp1):
        signal.status = SignalStatus.TP1_REACHED
        signal.tp1_reached_at = now
    if signal.status == SignalStatus.TP1_REACHED and hit(s.tp2):
        signal.status = SignalStatus.TP2_REACHED
        signal.tp2_reached_at = now
    if signal.status == SignalStatus.TP2_REACHED and hit(s.final_tp):
        signal.status = SignalStatus.COMPLETED
        signal.completed_at = now


def evaluate_signal(signal: Signal, market_price: float, now: datetime) -> SignalStatus:
    """Direct translation of handbook section 6's `evaluate_signal`.

    Call this on every tick/bar for every non-terminal signal. It is
    intentionally a pure state transition function — no I/O, no
    Telegram calls, no DB writes. The caller is responsible for
    persisting `signal` after this returns and for triggering
    `render_signal_controls` (telegram_controls.py) on any status
    change.
    """
    if signal.status not in (
        SignalStatus.ACTIVE,
        SignalStatus.TP1_REACHED,
        SignalStatus.TP2_REACHED,
    ):
        return signal.status

    if signal.expires_at and now >= signal.expires_at:
        signal.status = SignalStatus.EXPIRED
        return signal.status

    if crosses_invalidation(signal.direction, market_price, signal.invalidation):
        signal.status = SignalStatus.INVALIDATED
        signal.invalidated_at = now
        signal.invalidation_reason = "PRICE_CROSSED_THESIS_INVALIDATION"
        return signal.status

    if signal.status == SignalStatus.ACTIVE and entry_is_stale(signal, market_price):
        signal.status = SignalStatus.STALE
        return signal.status

    update_target_progress(signal, market_price, now)
    return signal.status


def signal_is_actionable(signal: Signal) -> bool:
    """Used by telegram_controls.py to decide whether to show Copy."""
    return signal.status in (
        SignalStatus.ACTIVE,
        SignalStatus.TP1_REACHED,
        SignalStatus.TP2_REACHED,
    )


def utcnow() -> datetime:
    return datetime.now(timezone.utc)
