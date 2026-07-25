import secrets
import time
import asyncio
from typing import List, Optional, Literal

from fastapi import APIRouter, Depends, HTTPException, Header, Request
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.models import Signal, SignalStatus
from app.database import get_session, check_db_connection
from app.validator import validate_signal
from app.formatter import format_signal_message
from app.telegram import send_telegram_message, TelegramSendError, NonRetryableError
from app.logger import logger
from app.utils import measure_latency
from app.ratelimit import enforce_rate_limit

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
    reasons: List[str] = Field(..., min_length=1)
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


class HealthResponse(BaseModel):
    status: str
    version: str
    database: Optional[str] = None


class SignalResponse(BaseModel):
    status: str
    signal_id: str
    duplicate: bool = False
    telegram_message_id: Optional[int] = None
    details: Optional[str] = None


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
    return {"status": "online", "version": "1.0.0", "database": "not checked"}


@router.get("/health/db", response_model=HealthResponse)
async def health_db():
    db_ok = await check_db_connection()
    return {
        "status": "online" if db_ok else "degraded",
        "version": "1.0.0",
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

    # Duplicate check (best-effort pre-check; the real guarantee is the
    # unique constraint + IntegrityError handling below, since two
    # concurrent requests for the same signal_id can both pass this SELECT).
    result = await session.execute(
        select(Signal).where(Signal.signal_id == payload.signal_id)
    )
    existing = result.scalar_one_or_none()
    if existing:
        log.info("Duplicate signal ignored (pre-check)")
        return SignalResponse(status="duplicate", signal_id=payload.signal_id, duplicate=True)

    # Format and send
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
        log.error(f"Sending failed after retries: {e}")
        msg_id = None
        status_signal = SignalStatus.FAILED
        error_msg = str(e)

    latency = measure_latency(start_time)

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
        telegram_message_id=msg_id,
        status=status_signal,
        error_message=error_msg,
        latency_ms=latency
    )
    session.add(db_signal)
    try:
        await session.commit()
    except IntegrityError:
        # Lost the race: another request inserted this signal_id first.
        # The Telegram message we may have just sent is now an orphan
        # (can't be un-sent) - log it clearly so it's visible in ops,
        # then report to the caller as a duplicate rather than a 500.
        await session.rollback()
        log.warning(
            "Duplicate signal_id lost insert race"
            + (f" - Telegram message {msg_id} was already sent" if msg_id else "")
        )
        return SignalResponse(status="duplicate", signal_id=payload.signal_id, duplicate=True)

    if status_signal in (SignalStatus.FAILED, SignalStatus.PERMANENTLY_FAILED):
        raise HTTPException(
            status_code=500,
            detail=f"Telegram sending failed. Signal saved with status '{status_signal.value}'."
        )

    return SignalResponse(status="sent", signal_id=payload.signal_id, telegram_message_id=msg_id)


# ---------- Retry Failed Signals Endpoint ----------
@router.post("/retry-failed")
async def retry_failed_signals(
    session: AsyncSession = Depends(get_session),
    _auth: bool = Depends(verify_api_key),
):
    # Only FAILED (transient) signals are retried. PERMANENTLY_FAILED signals
    # (NonRetryableError - e.g. malformed chat_id, bot blocked) are excluded
    # on purpose, otherwise they'd be re-selected and re-fail forever.
    result = await session.execute(
        select(Signal).where(Signal.status == SignalStatus.FAILED).limit(5)
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
            log.error(f"Retry failed: {e}")
            db_signal.error_message = f"Retry failed: {e}"
        await session.commit()
        await asyncio.sleep(0.5)

    return {
        "message": f"Processed {len(failed_signals)} failed signals. Retried {retried_count} successfully.",
        "remaining_failed": len(failed_signals) - retried_count
    }
