from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Literal

from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.application.copy_service import CopyAuthorizationContext, CopyService
from app.config import settings
from app.copy_trading import can_copy
from app.database import async_session, get_session
from app.domain.brokers import normalize_broker, supported_brokers
from app.domain.copy import CopyStage
from app.group_enforcement import run_subscription_enforcement
from app.models import Signal, SignalLifecycleStatus, SignalStatus
from app.routes import verify_api_key
from app.subscriptions import get_subscriber_by_copy_feed_key

router = APIRouter()
copy_service = CopyService()
COPY_FEED_MAX_AGE_SECONDS = 300


class CopySignalItem(BaseModel):
    signal_id: str
    symbol: str
    direction: Literal["BUY", "SELL"]
    entry: float
    sl: float
    tp1: float
    tp2: float
    confidence: int
    timeframe: str
    received_at: str


class CopyFeedResponse(BaseModel):
    copy_trading_enabled: bool
    broker: str | None = None
    supported_brokers: tuple[str, ...]
    signals: list[CopySignalItem]


class CopyAuthorizationRequest(BaseModel):
    broker: str = Field(..., min_length=2, max_length=40)
    symbol: str = Field(..., min_length=1, max_length=20)
    direction: Literal["BUY", "SELL"]
    risk_percent: float = Field(..., gt=0, le=2.0)
    account_equity: float = Field(..., gt=0)


class CopyAuthorizationResponse(BaseModel):
    allowed: bool
    stage: str
    reason: str
    broker: str | None = None
    next_stage: str


@router.get("/copy/feed", response_model=CopyFeedResponse)
async def get_copy_feed(
    x_copy_key: str = Header(..., alias="X-Copy-Key"),
    x_broker: str | None = Header(default=None, alias="X-Broker"),
    session: AsyncSession = Depends(get_session),
):
    """Return only currently-valid, recent signals to an entitled subscriber.

    Broker selection is allowlisted but credentials never pass through this
    API. Broker credentials stay on the user's MT5/connector side. The feed
    is deliberately not an execution authority; the final risk/portfolio
    admission must happen again immediately before broker submission.
    """
    broker = None
    if x_broker:
        try:
            broker = normalize_broker(x_broker)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    subscriber = await get_subscriber_by_copy_feed_key(session, x_copy_key)
    if subscriber is None:
        raise HTTPException(status_code=401, detail="Unrecognized copy-feed key")
    if not await can_copy(session, subscriber):
        raise HTTPException(status_code=403, detail="Copy trading is not currently active for this subscriber")

    cutoff = datetime.now(timezone.utc) - timedelta(seconds=COPY_FEED_MAX_AGE_SECONDS)
    result = await session.execute(
        select(Signal)
        .where(
            Signal.status == SignalStatus.ACTIVE,
            Signal.lifecycle_status == SignalLifecycleStatus.VALID,
            Signal.received_at >= cutoff,
        )
        .order_by(Signal.received_at.desc())
        .limit(settings.COPY_FEED_MAX_SIGNALS)
    )
    signals = result.scalars().all()
    return CopyFeedResponse(
        copy_trading_enabled=True,
        broker=broker.value if broker else None,
        supported_brokers=supported_brokers(),
        signals=[
            CopySignalItem(
                signal_id=s.signal_id,
                symbol=s.symbol,
                direction=s.direction,
                entry=s.entry,
                sl=s.sl,
                tp1=s.tp1,
                tp2=s.tp2,
                confidence=s.confidence,
                timeframe=s.timeframe,
                received_at=s.received_at.isoformat() if s.received_at else "",
            )
            for s in signals
        ],
    )


@router.post("/copy/authorize", response_model=CopyAuthorizationResponse)
async def authorize_copy_request(
    payload: CopyAuthorizationRequest,
    x_copy_key: str = Header(..., alias="X-Copy-Key"),
    session: AsyncSession = Depends(get_session),
):
    """Run the non-broker portion of the copy admission pipeline.

    This endpoint intentionally cannot authorize execution by itself. The
    portfolio gate is fail-closed here because current cross-symbol exposure
    belongs to the execution coordinator. A future executor may supply a
    server-side admission result, but it must never be accepted from the
    caller as a trusted boolean.
    """
    subscriber = await get_subscriber_by_copy_feed_key(session, x_copy_key)
    if subscriber is None:
        raise HTTPException(status_code=401, detail="Unrecognized copy-feed key")

    entitled = await can_copy(session, subscriber)
    decision = copy_service.authorize(
        CopyAuthorizationContext(
            broker=payload.broker,
            symbol=payload.symbol,
            direction=payload.direction,
            risk_percent=payload.risk_percent,
            account_equity=payload.account_equity,
            subscription_entitled=entitled,
            copy_authorized=entitled,
            portfolio_admitted=False,
        )
    )
    next_stage = CopyStage.EXECUTION.value if decision.allowed else decision.stage.value
    return CopyAuthorizationResponse(
        allowed=decision.allowed,
        stage=decision.stage.value,
        reason=decision.reason,
        broker=decision.broker.value if decision.broker else None,
        next_stage=next_stage,
    )


@router.post("/admin/check-subscriptions")
async def check_subscriptions(_auth: bool = Depends(verify_api_key)):
    async with async_session() as session:
        return await run_subscription_enforcement(session)
