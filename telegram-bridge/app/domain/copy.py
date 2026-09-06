from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum

from app.domain.brokers import Broker, normalize_broker


class CopyStage(StrEnum):
    SIGNAL = "signal"
    ELIGIBILITY = "eligibility"
    SUBSCRIPTION_ENTITLEMENT = "subscription_entitlement"
    COPY_AUTHORIZATION = "copy_trading_authorization"
    RISK_VALIDATION = "risk_validation"
    PORTFOLIO_ADMISSION = "portfolio_admission"
    EXECUTION = "execution"
    BROKER_ACKNOWLEDGEMENT = "broker_acknowledgement"
    RECONCILIATION = "reconciliation"
    OUTCOME = "outcome"


@dataclass(frozen=True)
class CopyRequest:
    broker: str
    symbol: str
    direction: str
    risk_percent: float
    account_equity: float
    subscription_entitled: bool
    copy_authorized: bool
    portfolio_admitted: bool


@dataclass(frozen=True)
class CopyDecision:
    allowed: bool
    stage: CopyStage
    reason: str
    broker: Broker | None = None


MAX_COPY_RISK_PERCENT = 2.0
MIN_COPY_RISK_PERCENT = 0.1
MAX_SYMBOL_LENGTH = 20
ALLOWED_DIRECTIONS = {"BUY", "SELL"}


def authorize_copy(request: CopyRequest) -> CopyDecision:
    """Pure, fail-closed copy-trading admission policy.

    This function has no database, Telegram, broker, or network dependency,
    making the security-critical decision path deterministic and unit-testable.
    Callers must still re-check risk and portfolio limits at execution time;
    this decision is not a substitute for broker-side validation.
    """
    try:
        broker = normalize_broker(request.broker)
    except ValueError as exc:
        return CopyDecision(False, CopyStage.ELIGIBILITY, str(exc))

    symbol = request.symbol.strip().upper()
    direction = request.direction.strip().upper()

    if not symbol or len(symbol) > MAX_SYMBOL_LENGTH:
        return CopyDecision(False, CopyStage.SIGNAL, "Invalid symbol", broker)
    if direction not in ALLOWED_DIRECTIONS:
        return CopyDecision(False, CopyStage.SIGNAL, "Invalid direction", broker)
    if request.account_equity <= 0:
        return CopyDecision(False, CopyStage.RISK_VALIDATION, "Account equity must be positive", broker)
    if not MIN_COPY_RISK_PERCENT <= request.risk_percent <= MAX_COPY_RISK_PERCENT:
        return CopyDecision(
            False,
            CopyStage.RISK_VALIDATION,
            f"Risk must be between {MIN_COPY_RISK_PERCENT}% and {MAX_COPY_RISK_PERCENT}%",
            broker,
        )
    if not request.subscription_entitled:
        return CopyDecision(False, CopyStage.SUBSCRIPTION_ENTITLEMENT, "Subscription entitlement is inactive", broker)
    if not request.copy_authorized:
        return CopyDecision(False, CopyStage.COPY_AUTHORIZATION, "Copy trading is not authorized", broker)
    if not request.portfolio_admitted:
        return CopyDecision(False, CopyStage.PORTFOLIO_ADMISSION, "Portfolio risk admission denied", broker)

    return CopyDecision(True, CopyStage.PORTFOLIO_ADMISSION, "Copy request admitted", broker)
