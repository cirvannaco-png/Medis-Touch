from __future__ import annotations

from dataclasses import dataclass

from app.domain.brokers import Broker
from app.domain.copy import CopyDecision, CopyRequest, authorize_copy


@dataclass(frozen=True)
class CopyAuthorizationContext:
    broker: Broker | str
    symbol: str
    direction: str
    risk_percent: float
    account_equity: float
    subscription_entitled: bool
    copy_authorized: bool
    portfolio_admitted: bool


class CopyService:
    """Application boundary for copy-trading authorization.

    The service deliberately contains no FastAPI or SQLAlchemy concerns. A
    route/controller resolves dependencies and passes a complete context;
    this makes the security-critical policy straightforward to unit-test.
    """

    def authorize(self, context: CopyAuthorizationContext) -> CopyDecision:
        broker = context.broker.value if isinstance(context.broker, Broker) else str(context.broker)
        return authorize_copy(
            CopyRequest(
                broker=broker,
                symbol=context.symbol,
                direction=context.direction,
                risk_percent=context.risk_percent,
                account_equity=context.account_equity,
                subscription_entitled=context.subscription_entitled,
                copy_authorized=context.copy_authorized,
                portfolio_admitted=context.portfolio_admitted,
            )
        )
