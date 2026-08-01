import asyncio
import secrets
import time
from datetime import datetime, timedelta, timezone
from typing import Literal

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import APP_VERSION, settings
from app.database import check_db_connection, get_session
from app.formatter import format_signal_message, format_trade_message
from app.logger import logger
from app.models import Signal, SignalStatus, TradeEvent, TradeEventStatus, TradeEventType
from app.ratelimit import enforce_rate_limit
from app.telegram import NonRetryableError, send_telegram_message
from app.utils import measure_latency
from app.validator import validate_signal, validate_trade_event

router = APIRouter()

VALID_TIMEFRAMES = {"M1", "M5", "M15", "M30", "H1", "H4", "D1", "W1", "MN"}

# Derive the allowed event values directly from the TradeEventType enum so
# that routes.py and models.py can never silently drift apart. Adding a new
# enum member automatically extends this Literal at import time.
_TradeEventLiteralValues = tuple(e.value for e in TradeEventType)
_TradeEventTypeLiteral = Literal[_TradeEventLiteralValues]  # type: ignore[valid-type]


# ---------- Request/Response Schemas ----------
class SignalRequest(BaseModel):
    signal_id: str = Field(..., min_length=1, max_length=100)
    symbol: str = Field(..., min_length=1, max_length=20)
    direction: Literal["BUY", "SELL"]
    entry: float = Field(..., gt=0)
    sl: float = Field(..., gt=0)
    tp1: float = Field(..., gt=0)
    tp2: float = Field(..., gt=0)
    confidence: int = Field(..., ge=0, le=100)
    reasons: list[str] = Field(..., min_length=1)
    timeframe: str

    @field_validator("reasons")
    @classmethod
    def check_reason_lengths(cls, v):
        for i, reason in enumerate(v):
            if len(reason) > 200:
                raise ValueError(f"reason at index {i} too long (max 200)")
        return v

    @field_validator("timeframe")
    @classmethod
    def validate_timeframe(cls, v):
        if v not in VALID_TIMEFRAMES:
            raise ValueError(f"timeframe must be one of {sorted(VALID_TIMEFRAMES)}")
        return v


class TradeEventRequest(BaseModel):
    event_id: str = Field(..., min_length=1, max_length=150)
    trade_id: str = Field(..., min_length=1, max_length=100)
    signal_id: str | None = Field(default=None, max_length=100)
    symbol: str = Field(..., min_length=1, max_length=20)
    direction: Literal["BUY", "SELL"]
    # Derived from TradeEventType enum — single source of truth, no manual sync needed.
    event: _TradeEventTypeLiteral
    volume: float = Field(..., gt=0)
    price: float = Field(..., gt=0)
    sl: float | None = Field(default=None, gt=0)
    tp1: float | None = Field(default=None, gt=0)
    tp2: float | None = Field(default=None, gt=0)
    profit: float | None = None
    balance: float | None = Field(default=None, ge=0)
    equity: float | None = Field(default=None, ge=0)
    comment: str | None = Field(default=None, max_length=200)


class TradeEventResponse(BaseModel):
    status: str
    event_id: str
    trade_id: str
    duplicate: bool = False
    telegram_message_id: int | None = None


class HealthResponse(BaseModel):
    status: str
    version: str
    database: str | None = None


class SignalResponse(BaseModel):
    status: str
    signal_id: str
    duplicate: bool = False
    telegram_message_id: int | None = None
    details: str | None = None


# ---------- Auth Dependency ----------
async def verify_api_key(x_api_key: str = Header(..., alias="X-API-Key")):
    # Timing-safe comparison - a naive `!=` leaks how many leading bytes
    # matched via response-time variance.
    if not secrets.compare_digest(x_api_key, settings.SECRET_KEY):
        logger.warning("Invalid API key attempt")
        raise HTTPException(status_code=401, detail="Invalid API key")
    return True


# ---------- Endpoints ----------
@router.get("/", response_model=HealthResponse)
async def health_check():
    # Liveness probe: deliberately cheap, no DB round-trip. Use /health/db
    # for a readiness check that verifies the database is reachable.
    return {"status": "online", "version": APP_VERSION, "database": "not checked"}


@router.get("/health/db", response_model=HealthResponse)
async def health_db():
    db_ok = await check_db_connection()
    return {
        "status": "online" if db_ok else "degraded",
        "version": APP_VERSION,
        "database": "connected" if db_ok else "disconnected"
    }


@router.post("/signal", response_model=SignalResponse)
async def receive_signal(
    request: Request,
    payload: SignalRequest,
    session: AsyncSession = Depends(get_session),
    _auth: bool = Depends(verify_api_key),
    _rate: None = Depends(enforce_rate_limit),
):
    start_time = time.time()
    log = logger.bind(signal_id=payload.signal_id)
    log.info("Signal received")

    # Business rule validation (SL/TP side-of-entry, ordering)
    valid, errors = validate_signal(payload.model_dump())
    if not valid:
        raise HTTPException(
            status_code=400,
            detail={"signal_id": payload.signal_id, "errors": errors}
        )

    # ---- Reserve signal_id BEFORE contacting Telegram ----
    # Previously the duplicate check was a pre-check SELECT followed by an
    # INSERT *after* the Telegram call: two concurrent requests for the same
    # signal_id could both pass the SELECT and both call Telegram, producing
    # two messages even though only one DB row would ultimately survive the
    # unique-constraint race. That's a real duplicate-alert bug for a trading
    # signal, not a cosmetic one.
    #
    # Fix: insert a PENDING placeholder row first and rely on the unique
    # constraint on signal_id as the single source of truth. Only the
    # request that wins this insert is allowed to proceed to the external
    # call, so Telegram is contacted at most once per signal_id.
    db_signal = Signal(
        signal_id=payload.signal_id,
        symbol=payload.symbol,
        direction=payload.direction,
        entry=payload.entry,
        sl=payload.sl,
        tp1=payload.tp1,
        tp2=payload.tp2,
        confidence=payload.confidence,
        reasons=payload.reasons,
        timeframe=payload.timeframe,
        status=SignalStatus.PENDING,
    )
    session.add(db_signal)
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        log.info("Duplicate signal ignored (reservation lost)")
        return SignalResponse(status="duplicate", signal_id=payload.signal_id, duplicate=True)

    # From here on this request exclusively owns signal_id - safe to call
    # Telegram exactly once.
    message_text = format_signal_message(payload.model_dump())
    try:
        msg_id = await send_telegram_message(message_text)
        status_signal = SignalStatus.ACTIVE
        error_msg = None
    except NonRetryableError as e:
        log.error(f"Non-retryable failure: {e}")
        msg_id = None
        status_signal = SignalStatus.PERMANENTLY_FAILED
        error_msg = str(e)
    except Exception as e:
        log.error(f"Sending failed after retries ({type(e).__name__}): {e}")
        msg_id = None
        status_signal = SignalStatus.FAILED
        error_msg = str(e)

    latency = measure_latency(start_time)

    db_signal.telegram_message_id = msg_id
    db_signal.status = status_signal
    db_signal.error_message = error_msg
    db_signal.latency_ms = latency
    await session.commit()

    if status_signal in (SignalStatus.FAILED, SignalStatus.PERMANENTLY_FAILED):
        raise HTTPException(
            status_code=500,
            detail=f"Telegram sending failed. Signal saved with status '{status_signal.value}'."
        )

    return SignalResponse(status="sent", signal_id=payload.signal_id, telegram_message_id=msg_id)


@router.post("/trade", response_model=TradeEventResponse)
async def receive_trade_event(
    request: Request,
    payload: TradeEventRequest,
    session: AsyncSession = Depends(get_session),
    _auth: bool = Depends(verify_api_key),
    _rate: None = Depends(enforce_rate_limit),
):
    """
    Receives a trade lifecycle event from the EA's OrderManager/PositionManager
    after it has actually placed, modified, or closed an order with the
    broker - as distinct from POST /signal, which is a pre-trade alert with
    no guarantee an order was ever opened. Same idempotency shape as
    /signal: reserve a PENDING row keyed on the caller-supplied event_id
    before contacting Telegram, so a WebRequest retry from the EA after a
    dropped response can never produce a duplicate Telegram message.
    """
    start_time = time.time()
    log = logger.bind(event_id=payload.event_id, trade_id=payload.trade_id)
    log.info("Trade event received")

    valid, errors = validate_trade_event(payload.model_dump())
    if not valid:
        raise HTTPException(
            status_code=400,
            detail={"event_id": payload.event_id, "errors": errors}
        )

    db_event = TradeEvent(
        event_id=payload.event_id,
        trade_id=payload.trade_id,
        signal_id=payload.signal_id,
        symbol=payload.symbol,
        direction=payload.direction,
        event=TradeEventType(payload.event),
        volume=payload.volume,
        price=payload.price,
        sl=payload.sl,
        tp1=payload.tp1,
        tp2=payload.tp2,
        profit=payload.profit,
        balance=payload.balance,
        equity=payload.equity,
        comment=payload.comment,
        status=TradeEventStatus.PENDING,
    )
    session.add(db_event)
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        log.info("Duplicate trade event ignored (reservation lost)")
        return TradeEventResponse(
            status="duplicate", event_id=payload.event_id,
            trade_id=payload.trade_id, duplicate=True,
        )

    message_text = format_trade_message(payload.model_dump())
    try:
        msg_id = await send_telegram_message(message_text)
        status_event = TradeEventStatus.ACTIVE
        error_msg = None
    except NonRetryableError as e:
        log.error(f"Non-retryable failure: {e}")
        msg_id = None
        status_event = TradeEventStatus.PERMANENTLY_FAILED
        error_msg = str(e)
    except Exception as e:
        log.error(f"Sending failed after retries ({type(e).__name__}): {e}")
        msg_id = None
        status_event = TradeEventStatus.FAILED
        error_msg = str(e)

    latency = measure_latency(start_time)

    db_event.telegram_message_id = msg_id
    db_event.status = status_event
    db_event.error_message = error_msg
    db_event.latency_ms = latency
    await session.commit()

    if status_event in (TradeEventStatus.FAILED, TradeEventStatus.PERMANENTLY_FAILED):
        raise HTTPException(
            status_code=500,
            detail=f"Telegram sending failed. Trade event saved with status '{status_event.value}'."
        )

    return TradeEventResponse(
        status="sent", event_id=payload.event_id,
        trade_id=payload.trade_id, telegram_message_id=msg_id,
    )


# ---------- Retry Failed Trade Events Endpoint ----------
@router.post("/trade/retry-failed")
async def retry_failed_trade_events(
    session: AsyncSession = Depends(get_session),
    _auth: bool = Depends(verify_api_key),
    _rate: None = Depends(enforce_rate_limit),
):
    """Mirrors /retry-failed but for the trade_events table - see that
    endpoint's comments for why PENDING rows older than
    PENDING_STALE_SECONDS are reclaimed alongside FAILED ones."""
    stale_before = datetime.now(timezone.utc) - timedelta(seconds=settings.PENDING_STALE_SECONDS)
    result = await session.execute(
        select(TradeEvent)
        .where(
            (TradeEvent.status == TradeEventStatus.FAILED)
            | ((TradeEvent.status == TradeEventStatus.PENDING) & (TradeEvent.received_at < stale_before))
        )
        .limit(5)
    )
    failed_events = result.scalars().all()
    if not failed_events:
        return {"message": "No failed trade events to retry."}

    retried_count = 0
    for db_event in failed_events:
        event_dict = {
            "event_id": db_event.event_id,
            "trade_id": db_event.trade_id,
            "signal_id": db_event.signal_id,
            "symbol": db_event.symbol,
            "direction": db_event.direction,
            "event": db_event.event.value,
            "volume": db_event.volume,
            "price": db_event.price,
            "sl": db_event.sl,
            "tp1": db_event.tp1,
            "tp2": db_event.tp2,
            "profit": db_event.profit,
            "balance": db_event.balance,
            "equity": db_event.equity,
            "comment": db_event.comment,
        }
        message_text = format_trade_message(event_dict)
        log = logger.bind(event_id=db_event.event_id, trade_id=db_event.trade_id)
        try:
            msg_id = await send_telegram_message(message_text)
            db_event.status = TradeEventStatus.ACTIVE
            db_event.telegram_message_id = msg_id
            db_event.error_message = None
            log.info("Retried trade event successfully")
            retried_count += 1
        except NonRetryableError as e:
            log.error(f"Permanent failure during retry: {e}")
            db_event.status = TradeEventStatus.PERMANENTLY_FAILED
            db_event.error_message = f"Retry failed permanently: {e}"
        except Exception as e:
            log.error(f"Retry failed ({type(e).__name__}): {e}")
            db_event.error_message = f"Retry failed: {e}"
        await session.commit()
        await asyncio.sleep(0.5)

    return {
        "message": f"Processed {len(failed_events)} failed trade events. Retried {retried_count} successfully.",
        "remaining_failed": len(failed_events) - retried_count
    }


# ---------- Retry Failed Signals Endpoint ----------
@router.post("/retry-failed")
async def retry_failed_signals(
    session: AsyncSession = Depends(get_session),
    _auth: bool = Depends(verify_api_key),
    _rate: None = Depends(enforce_rate_limit),
):
    # FAILED (transient) signals are retried. PERMANENTLY_FAILED signals
    # (NonRetryableError - e.g. malformed chat_id, bot blocked) are excluded
    # on purpose, otherwise they'd be re-selected and re-fail forever.
    #
    # PENDING rows older than PENDING_STALE_SECONDS are also reclaimed: a
    # process crash/restart between reserving signal_id and resolving the
    # Telegram send leaves the row at PENDING with no other path back to
    # ACTIVE/FAILED. A fresh PENDING row (still in-flight in another
    # request right now) is excluded via the age cutoff.
    stale_before = datetime.now(timezone.utc) - timedelta(seconds=settings.PENDING_STALE_SECONDS)
    result = await session.execute(
        select(Signal)
        .where(
            (Signal.status == SignalStatus.FAILED)
            | ((Signal.status == SignalStatus.PENDING) & (Signal.received_at < stale_before))
        )
        .limit(5)
    )
    failed_signals = result.scalars().all()
    if not failed_signals:
        return {"message": "No failed signals to retry."}

    retried_count = 0
    for db_signal in failed_signals:
        signal_dict = {
            "signal_id": db_signal.signal_id,
            "symbol": db_signal.symbol,
            "direction": db_signal.direction,
            "entry": db_signal.entry,
            "sl": db_signal.sl,
            "tp1": db_signal.tp1,
            "tp2": db_signal.tp2,
            "confidence": db_signal.confidence,
            "reasons": db_signal.reasons,
            "timeframe": db_signal.timeframe
        }
        message_text = format_signal_message(signal_dict)
        log = logger.bind(signal_id=db_signal.signal_id)
        try:
            msg_id = await send_telegram_message(message_text)
            db_signal.status = SignalStatus.ACTIVE
            db_signal.telegram_message_id = msg_id
            db_signal.error_message = None
            log.info("Retried signal successfully")
            retried_count += 1
        except NonRetryableError as e:
            log.error(f"Permanent failure during retry: {e}")
            db_signal.status = SignalStatus.PERMANENTLY_FAILED
            db_signal.error_message = f"Retry failed permanently: {e}"
        except Exception as e:
            log.error(f"Retry failed ({type(e).__name__}): {e}")
            db_signal.error_message = f"Retry failed: {e}"
        await session.commit()
        await asyncio.sleep(0.5)

    return {
        "message": f"Processed {len(failed_signals)} failed signals. Retried {retried_count} successfully.",
        "remaining_failed": len(failed_signals) - retried_count
    }
