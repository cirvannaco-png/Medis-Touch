"""
Fail-closed execution validation.

Handbook section 15. Core rule, verbatim: "Unknown/invalid critical
symbol metadata -> REFUSE TRADE." The specific bug called out:
"ValidateStopDistance must not return true merely because point
metadata is unavailable" — i.e. a `None`/missing value must be treated
as INVALID, never as "skip this check". This is the classic fail-open
bug: `if point_size and stop_distance < point_size: return False` looks
fine until `point_size` is None, at which point the whole condition is
falsy and the function returns... whatever the fall-through is, usually
True. Below, every check is written so that missing metadata is an
explicit rejection, not a bypassed branch.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class RejectionReason(str, Enum):
    MISSING_POINT_SIZE = "MISSING_POINT_SIZE"
    MISSING_TICK_SIZE = "MISSING_TICK_SIZE"
    MISSING_STOPS_LEVEL = "MISSING_STOPS_LEVEL"
    MISSING_FREEZE_LEVEL = "MISSING_FREEZE_LEVEL"
    MISSING_VOLUME_LIMITS = "MISSING_VOLUME_LIMITS"
    STOP_DISTANCE_TOO_TIGHT = "STOP_DISTANCE_TOO_TIGHT"
    FREEZE_DISTANCE_TOO_TIGHT = "FREEZE_DISTANCE_TOO_TIGHT"
    PRICE_NOT_NORMALIZED = "PRICE_NOT_NORMALIZED"
    INSUFFICIENT_MARGIN = "INSUFFICIENT_MARGIN"
    TRADING_NOT_PERMITTED = "TRADING_NOT_PERMITTED"
    SESSION_CLOSED = "SESSION_CLOSED"
    VOLUME_OUT_OF_RANGE = "VOLUME_OUT_OF_RANGE"


@dataclass(frozen=True)
class SymbolMetadata:
    """All fields Optional on purpose — that's the whole point of this
    module. A None here must fail the corresponding check, not skip it.
    """

    point_size: float | None
    tick_size: float | None
    stops_level_points: int | None
    freeze_level_points: int | None
    volume_min: float | None
    volume_max: float | None
    volume_step: float | None
    trading_permitted: bool | None
    session_open: bool | None
    price_digits: int | None


@dataclass(frozen=True)
class ValidationResult:
    ok: bool
    reason: RejectionReason | None = None
    detail: str = ""

    @staticmethod
    def reject(reason: RejectionReason, detail: str = "") -> ValidationResult:
        return ValidationResult(ok=False, reason=reason, detail=detail)

    @staticmethod
    def accept() -> ValidationResult:
        return ValidationResult(ok=True)


def validate_stop_distance(
    *,
    entry_price: float,
    stop_loss: float,
    meta: SymbolMetadata,
) -> ValidationResult:
    """The specific function the handbook calls out by name.

    Every metadata field this depends on is checked for None FIRST,
    before any numeric comparison — so "metadata unavailable" can never
    fall through to an implicit pass.
    """
    if meta.point_size is None:
        return ValidationResult.reject(RejectionReason.MISSING_POINT_SIZE)
    if meta.stops_level_points is None:
        return ValidationResult.reject(RejectionReason.MISSING_STOPS_LEVEL)

    distance_points = abs(entry_price - stop_loss) / meta.point_size
    min_required = meta.stops_level_points

    if distance_points < min_required:
        return ValidationResult.reject(
            RejectionReason.STOP_DISTANCE_TOO_TIGHT,
            detail=f"{distance_points:.1f} points < required {min_required}",
        )
    return ValidationResult.accept()


def validate_tick_size(price: float, meta: SymbolMetadata) -> ValidationResult:
    """Handbook section 15 explicitly requires validating tick_size,
    separately from point_size (many brokers/symbols have a coarser
    tradeable tick than the raw point precision — e.g. 5-digit pricing
    with a 1-tick minimum increment). None here is a hard reject, same
    fail-closed rule as everything else in this module.
    """
    if meta.tick_size is None:
        return ValidationResult.reject(RejectionReason.MISSING_TICK_SIZE)
    if meta.tick_size <= 0:
        return ValidationResult.reject(RejectionReason.MISSING_TICK_SIZE, "tick_size <= 0")
    remainder = price % meta.tick_size
    # tolerate float error on both sides of the modulus
    if remainder > 1e-9 and (meta.tick_size - remainder) > 1e-9:
        return ValidationResult.reject(
            RejectionReason.PRICE_NOT_NORMALIZED,
            detail=f"{price} not aligned to tick_size {meta.tick_size}",
        )
    return ValidationResult.accept()


def validate_freeze_level(
    *, entry_price: float, stop_loss: float, meta: SymbolMetadata
) -> ValidationResult:
    """Handbook section 15 requires validating freeze level alongside
    stops level. Stops level governs the minimum distance for
    SL/TP *placement*; freeze level governs the minimum distance within
    which an order can no longer be *modified or cancelled*. They are
    frequently different values and both matter: a stop that clears
    stops_level but sits inside freeze_level will place fine and then
    reject on the first modification attempt. That failure mode belongs
    here, not discovered later in production.
    """
    if meta.point_size is None:
        return ValidationResult.reject(RejectionReason.MISSING_POINT_SIZE)
    if meta.freeze_level_points is None:
        return ValidationResult.reject(RejectionReason.MISSING_FREEZE_LEVEL)

    distance_points = abs(entry_price - stop_loss) / meta.point_size
    if distance_points < meta.freeze_level_points:
        return ValidationResult.reject(
            RejectionReason.FREEZE_DISTANCE_TOO_TIGHT,
            detail=(
                f"{distance_points:.1f} points < freeze level "
                f"{meta.freeze_level_points}"
            ),
        )
    return ValidationResult.accept()


def validate_price_normalization(price: float, meta: SymbolMetadata) -> ValidationResult:
    if meta.price_digits is None:
        return ValidationResult.reject(RejectionReason.PRICE_NOT_NORMALIZED, "digits unknown")
    rounded = round(price, meta.price_digits)
    if abs(rounded - price) > 1e-12:
        return ValidationResult.reject(
            RejectionReason.PRICE_NOT_NORMALIZED,
            detail=f"{price} not aligned to {meta.price_digits} digits",
        )
    return ValidationResult.accept()


def validate_volume(volume: float, meta: SymbolMetadata) -> ValidationResult:
    if meta.volume_min is None or meta.volume_max is None or meta.volume_step is None:
        return ValidationResult.reject(RejectionReason.MISSING_VOLUME_LIMITS)
    if not (meta.volume_min <= volume <= meta.volume_max):
        return ValidationResult.reject(RejectionReason.VOLUME_OUT_OF_RANGE)
    # step alignment, tolerant of float error
    steps = (volume - meta.volume_min) / meta.volume_step
    if abs(steps - round(steps)) > 1e-6:
        return ValidationResult.reject(
            RejectionReason.VOLUME_OUT_OF_RANGE, detail="not aligned to volume_step"
        )
    return ValidationResult.accept()


def validate_trading_permissions(meta: SymbolMetadata) -> ValidationResult:
    if meta.trading_permitted is None or meta.trading_permitted is False:
        return ValidationResult.reject(RejectionReason.TRADING_NOT_PERMITTED)
    if meta.session_open is None or meta.session_open is False:
        return ValidationResult.reject(RejectionReason.SESSION_CLOSED)
    return ValidationResult.accept()


def validate_margin(required_margin: float | None, free_margin: float | None) -> ValidationResult:
    if required_margin is None or free_margin is None:
        return ValidationResult.reject(RejectionReason.INSUFFICIENT_MARGIN, "margin data unavailable")
    if required_margin > free_margin:
        return ValidationResult.reject(RejectionReason.INSUFFICIENT_MARGIN)
    return ValidationResult.accept()


def validate_execution(
    *,
    entry_price: float,
    stop_loss: float,
    volume: float,
    meta: SymbolMetadata,
    required_margin: float | None,
    free_margin: float | None,
) -> ValidationResult:
    """Runs every check; returns the first rejection, or accept() only
    if every single check explicitly passed. Order doesn't matter for
    correctness here since each check is independent and short-circuits
    on its own missing data — but cheap/metadata checks are ordered
    before the margin check to fail fast without needing an account
    snapshot for a trade that was already invalid on symbol grounds.
    """
    for result in (
        validate_stop_distance(entry_price=entry_price, stop_loss=stop_loss, meta=meta),
        validate_freeze_level(entry_price=entry_price, stop_loss=stop_loss, meta=meta),
        validate_tick_size(entry_price, meta),
        validate_price_normalization(entry_price, meta),
        validate_volume(volume, meta),
        validate_trading_permissions(meta),
        validate_margin(required_margin, free_margin),
    ):
        if not result.ok:
            return result
    return ValidationResult.accept()
