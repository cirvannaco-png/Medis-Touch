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

from app import bot as bot_module
from app.config import APP_VERSION, settings
from app.database import check_db_connection, get_session
from app.formatter import format_lifecycle_banner, format_signal_message, format_trade_message
from app.logger import logger
from app.models import (
    Signal,
    SignalLifecycleStatus,
    SignalStatus,
    TradeEvent,
    TradeEventStatus,
    TradeEventType,
)
from app.ratelimit import enforce_rate_limit
from app.settings_store import is_broadcast_paused, is_symbol_muted
from app.telegram import NonRetryableError, edit_telegram_message, send_telegram_message
from app.utils import measure_latency
from app.validator import validate_signal, validate_trade_event

router = APIRouter()

VALID_TIMEFRAMES = {"M1", "M5", "M15", "M30", "H1", "H4", "D1", "W1", "MN"}


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
    # v2.9: optional so pre-v2.9 EA builds keep working unmodified — see
    # models.py:Signal.extra. Not validated field-by-field on purpose;
    # this is display-only diagnostic data (sweep grade, BOS strength,
    # decay, chase distance, news risk, calibrated probability, pip
    # distances), never used for trading logic on the bridge side, so a
    # missing or malformed key degrades the Telegram card, not a decision.
    extra: dict | None = Field(default=None)

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
    # Using the enum type directly keeps routes.py and models.py in sync
    # automatically — adding a new TradeEventType member covers it here too.
    # Pydantic v2 accepts the string value and coerces it to the enum instance.
    event: TradeEventType
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
@router.head("/")
async def health_check():
    # Liveness probe: deliberately cheap, no DB round-trip. Use /health/db
    # for a readiness check that verifies the database is reachable.
    # HEAD is registered alongside GET because Render's platform health
    # check probes with HEAD / before a deploy is marked live - FastAPI
    # doesn't add HEAD support to a GET route automatically, so without
    # this it 405s on every deploy (harmless, but noisy in logs and a
    # false-down for any external monitor that defaults to HEAD).
    return {"status": "online", "version": APP_VERSION, "database": "not checked"}


@router.get("/health/db", response_model=HealthResponse)
async def health_db():
    db_ok = await check_db_connection()
    return {
        "status": "online" if db_ok else "degraded",
        "version": APP_VERSION,
        "database": "connected" if db_ok else "disconnected"
    }


@router.post("/telegram/webhook")
async def telegram_webhook(
    request: Request,
    x_telegram_bot_api_secret_token: str | None = Header(default=None),
):
    """
    Telegram delivers inbound updates (users typing /start, /positions,
    etc. to the bot) here. Telegram signs every delivery with the secret
    token set via bot.set_webhook(secret_token=...) in app/bot.py; anything
    that doesn't match is rejected before the payload is even parsed, so
    this endpoint can't be used to inject fake commands from outside
    Telegram.
    """
    if not secrets.compare_digest(
        x_telegram_bot_api_secret_token or "", settings.WEBHOOK_SECRET_TOKEN
    ):
        logger.warning("Rejected Telegram webhook call with invalid secret token")
        raise HTTPException(status_code=401, detail="Invalid secret token")

    payload = await request.json()

    # Temporary discovery aid: log the chat id of every inbound update so
    # the group's chat id can be read straight out of the service logs and
    # set as GROUP_CHAT_ID. Safe to remove once that's configured.
    try:
        _chat = (payload.get("message") or payload.get("channel_post") or {}).get("chat") or {}
        _from = (payload.get("message") or {}).get("from") or {}
        logger.info(
            f"Telegram update from chat_id={_chat.get('id')} "
            f"type={_chat.get('type')} title={_chat.get('title')} "
            f"user_id={_from.get('id')}"
        )
    except AttributeError:
        logger.info("Telegram update with unexpected payload shape")

    try:
        await bot_module.process_update(payload)
    except Exception as e:
        # Never let a malformed/unexpected update 500 back to Telegram -
        # Telegram retries 5xx responses, which would hammer this endpoint
        # for an update it will never be able to parse successfully.
        logger.error(f"Failed to process Telegram update ({type(e).__name__}): {e}")

    return {"ok": True}


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
        extra=payload.extra,
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
    #
    # /mute <SYMBOL> and /pause (Telegram, admin-only - see bot_handlers.py)
    # write here: a muted symbol or a global pause suppresses the outbound
    # broadcast without touching the EA at all, and without losing the
    # signal - it's still recorded as ACTIVE (nothing about the signal
    # itself failed) with telegram_message_id left null. This mirrors
    # what /muted and /signal already show, since a muted signal still
    # counts toward win-rate stats.
    if await is_broadcast_paused(session) or await is_symbol_muted(session, payload.symbol):
        db_signal.status = SignalStatus.ACTIVE
        db_signal.error_message = "Broadcast suppressed (paused or symbol muted)"
        await session.commit()
        log.info(f"Signal broadcast suppressed for {payload.symbol}")
        return SignalResponse(
            status="suppressed",
            signal_id=payload.signal_id,
            details="Broadcast paused or symbol muted - signal recorded, not sent to Telegram.",
        )

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


# v2.9 addition — signal lifecycle (review: "SCANNING -> QUALIFIED ->
# POSTED -> ACTIVE -> TP/SL/EXPIRED/INVALIDATED"). This endpoint handles
# the STALE/EXPIRED/INVALIDATED transitions the EA detects post-publish
# (see EA/includes/Signals/SignalPublisher.mqh::PublishStatusUpdate()).
# TP/SL resolution is already covered separately by POST /trade's
# closed_tp1/closed_tp2/closed_sl events — this endpoint is only for "this
# setup is no longer a valid reason to enter", not fills/closes.
class LifecycleUpdateRequest(BaseModel):
    status: Literal["stale", "expired", "invalidated", "valid"]
    reason: str = Field(..., min_length=1, max_length=300)


class LifecycleUpdateResponse(BaseModel):
    signal_id: str
    lifecycle_status: str
    message_edited: bool


@router.patch("/signal/{signal_id}/status", response_model=LifecycleUpdateResponse)
async def update_signal_lifecycle(
    signal_id: str,
    payload: LifecycleUpdateRequest,
    session: AsyncSession = Depends(get_session),
    _auth: bool = Depends(verify_api_key),
):
    log = logger.bind(signal_id=signal_id)
    result = await session.execute(select(Signal).where(Signal.signal_id == signal_id))
    db_signal = result.scalar_one_or_none()
    if db_signal is None:
        raise HTTPException(status_code=404, detail=f"No signal found with signal_id={signal_id}")

    new_status = SignalLifecycleStatus(payload.status)
    # A signal that was never successfully delivered (no telegram_message_id)
    # has nothing to edit — still record the status change, just skip the
    # Telegram call rather than erroring the whole request over it.
    edited = False
    if db_signal.telegram_message_id is not None and new_status != SignalLifecycleStatus.VALID:
        original_text = format_signal_message(
            {
                "signal_id": db_signal.signal_id,
                "symbol": db_signal.symbol,
                "direction": db_signal.direction,
                "entry": db_signal.entry,
                "sl": db_signal.sl,
                "tp1": db_signal.tp1,
                "tp2": db_signal.tp2,
                "timeframe": db_signal.timeframe,
                "confidence": db_signal.confidence,
                "reasons": db_signal.reasons,
                "extra": db_signal.extra,
            }
        )
        banner = format_lifecycle_banner(new_status.value, payload.reason)
        edited = await edit_telegram_message(db_signal.telegram_message_id, banner + "\n\n" + original_text)
        if not edited:
            log.warning(f"Lifecycle status DB-updated to {new_status.value} but Telegram edit failed")

    db_signal.lifecycle_status = new_status
    db_signal.lifecycle_reason = payload.reason
    db_signal.lifecycle_updated_at = datetime.now(timezone.utc)
    await session.commit()
    log.info(f"Lifecycle status -> {new_status.value}: {payload.reason}")

    return LifecycleUpdateResponse(signal_id=signal_id, lifecycle_status=new_status.value, message_edited=edited)


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
        event=payload.event,  # already a TradeEventType; Pydantic coerced it
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


# ---------- Retry Failed Trade Events (core + HTTP endpoint) ----------
# Split into a plain async function (retry_failed_trade_events_core) and a
# thin route wrapper so app/bot_handlers.py's /retry command can call the
# exact same logic from an already-open session, instead of the bot having
# to make an HTTP call to itself with its own SECRET_KEY (which it doesn't
# have configured, on purpose - see verify_api_key).
async def retry_failed_trade_events_core(session: AsyncSession) -> dict:
    """Mirrors retry_failed_signals_core but for the trade_events table -
    see that function's comments for why PENDING rows older than
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


@router.post("/trade/retry-failed")
async def retry_failed_trade_events(
    session: AsyncSession = Depends(get_session),
    _auth: bool = Depends(verify_api_key),
    _rate: None = Depends(enforce_rate_limit),
):
    return await retry_failed_trade_events_core(session)


# ---------- Retry Failed Signals (core + HTTP endpoint) ----------
async def retry_failed_signals_core(session: AsyncSession) -> dict:
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


@router.post("/retry-failed")
async def retry_failed_signals(
    session: AsyncSession = Depends(get_session),
    _auth: bool = Depends(verify_api_key),
    _rate: None = Depends(enforce_rate_limit),
):
    return await retry_failed_signals_core(session)
