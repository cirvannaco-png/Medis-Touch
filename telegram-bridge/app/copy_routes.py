from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.copy_trading import can_copy
from app.database import async_session, get_session
from app.group_enforcement import run_subscription_enforcement
from app.models import Signal, SignalLifecycleStatus, SignalStatus
from app.subscriptions import get_subscriber_by_copy_feed_key
from app.database import get_session
from app.database import check_db_connection

router = APIRouter()


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
    signals: list[CopySignalItem]


@router.get("/copy/feed", response_model=CopyFeedResponse)
async def get_copy_feed(x_copy_key: str = Header(..., alias="X-Copy-Key"), session: AsyncSession = Depends(get_session)):
    subscriber = await get_subscriber_by_copy_feed_key(session, x_copy_key)
    if subscriber is None:
        raise HTTPException(status_code=401, detail="Unrecognized copy-feed key")
    if not await can_copy(session, subscriber):
        raise HTTPException(status_code=403, detail="Copy trading is not currently active for this subscriber")
    result = await session.execute(select(Signal).where(Signal.status == SignalStatus.ACTIVE, Signal.lifecycle_status == SignalLifecycleStatus.VALID).order_by(Signal.received_at.desc()).limit(settings.COPY_FEED_MAX_SIGNALS))
    signals = result.scalars().all()
    return CopyFeedResponse(copy_trading_enabled=True, signals=[CopySignalItem(signal_id=s.signal_id, symbol=s.symbol, direction=s.direction, entry=s.entry, sl=s.sl, tp1=s.tp1, tp2=s.tp2, confidence=s.confidence, timeframe=s.timeframe, received_at=s.received_at.isoformat() if s.received_at else "") for s in signals])


@router.post("/admin/check-subscriptions")
async def check_subscriptions(_auth: bool = Depends(__import__("app.routes", fromlist=["verify_api_key"]).verify_api_key)):
    async with async_session() as session:
        return await run_subscription_enforcement(session)
