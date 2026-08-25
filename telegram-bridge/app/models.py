import enum
from datetime import datetime, timezone

from sqlalchemy import JSON, Column, DateTime, Float, Index, Integer, String, Text
from sqlalchemy.dialects.postgresql import ENUM as PG_ENUM

from app.database import Base


class SignalStatus(str, enum.Enum):
    PENDING = "pending"                  # signal_id reserved, Telegram call not yet resolved
    ACTIVE = "active"
    FAILED = "failed"                    # transient failure, eligible for /retry-failed
    PERMANENTLY_FAILED = "permanently_failed"  # NonRetryableError - do not keep retrying
    DUPLICATE = "duplicate"


# v2.9 addition. Distinct from SignalStatus above: SignalStatus tracks
# DELIVERY (did the Telegram call succeed), lifecycle_status tracks
# MARKET VALIDITY (does this setup still describe current price action).
# A signal can be status=ACTIVE (delivered fine) and lifecycle_status=
# STALE (price ran away from it) at the same time — these are
# orthogonal, not a single combined state machine.
class SignalLifecycleStatus(str, enum.Enum):
    VALID = "valid"              # default — setup still describes current conditions
    STALE = "stale"              # price moved meaningfully past the intended entry zone
    EXPIRED = "expired"          # unfilled for too long; EA gave up waiting
    INVALIDATED = "invalidated"  # an opposing BOS or other structural break contradicts the original setup


class TradeEventStatus(str, enum.Enum):
    PENDING = "pending"                  # event_id reserved, Telegram call not yet resolved
    ACTIVE = "active"
    FAILED = "failed"                    # transient failure, eligible for retry
    PERMANENTLY_FAILED = "permanently_failed"


class TradeEventType(str, enum.Enum):
    OPENED = "opened"
    MODIFIED = "modified"
    PARTIAL_CLOSE = "partial_close"
    CLOSED_TP1 = "closed_tp1"
    CLOSED_TP2 = "closed_tp2"
    CLOSED_SL = "closed_sl"
    CLOSED_MANUAL = "closed_manual"


# FIX: Use PG_ENUM (sqlalchemy.dialects.postgresql.ENUM) instead of the
# generic SAEnum (sa.Enum / from sqlalchemy import Enum as SAEnum).
#
# The generic class silently discards create_type=False — the keyword is
# accepted into **kwargs and thrown away, and the Postgres dialect adapter
# then builds a brand-new ENUM object with its own default of create_type=True,
# completely independent of what was passed to the generic class. The result
# is that op.create_table() fires an unguarded CREATE TYPE, which collides
# with the type the DO $$ block just created and raises:
#   sqlalchemy.exc.ProgrammingError: asyncpg.exceptions.DuplicateObjectError
#
# PG_ENUM stores and respects create_type=False directly. Verified against
# sqlalchemy[asyncio]==2.0.25, the exact version pinned in requirements.txt.
# SQLite is unaffected (enums map to VARCHAR there).
_signal_status_type = PG_ENUM(
    SignalStatus,
    name="signalstatus",
    create_type=False,
)
# v2.9. Same PG_ENUM + create_type=False pattern as _signal_status_type
# above, for the exact DuplicateObjectError reason documented there.
_signal_lifecycle_status_type = PG_ENUM(
    SignalLifecycleStatus,
    name="signallifecyclestatus",
    create_type=False,
)
_trade_event_status_type = PG_ENUM(
    TradeEventStatus,
    name="tradeeventstatus",
    create_type=False,
)
_trade_event_type_type = PG_ENUM(
    TradeEventType,
    name="tradeeventtype",
    create_type=False,
)


class BotSetting(Base):
    """
    Generic key/value store for operator-facing bridge controls that must
    survive restarts (Render redeploys, dyno cycling) - the kind of thing
    that otherwise accumulates as one dedicated column + migration per
    flag. Two keys currently in use:

      "muted_symbols"    -> JSON list[str], e.g. ["XAUUSD", "GBPJPY"]
      "broadcast_paused" -> JSON bool

    See app/settings_store.py for the read/write helpers; nothing should
    query this table directly outside that module.
    """
    __tablename__ = "bot_settings"

    key = Column(String, primary_key=True)
    value = Column(JSON, nullable=False)
    updated_at = Column(
        DateTime(timezone=True),
        default=lambda: datetime.now(timezone.utc),
        onupdate=lambda: datetime.now(timezone.utc),
    )


class TradeEvent(Base):
    """
    A single lifecycle event for a live trade the EA has actually placed
    with the broker (open/modify/partial-close/close). Distinct from
    Signal, which is a pre-trade alert - a Signal is "here's a setup",
    a TradeEvent is "the EA's OrderManager/PositionManager did something
    with a real order ticket". One signal_id can have zero, one, or many
    TradeEvents (opened, then later closed_tp1, closed_manual, etc.).
    """
    __tablename__ = "trade_events"
    __table_args__ = (
        Index("ix_trade_events_status", "status"),
        Index("ix_trade_events_trade_id", "trade_id"),
    )

    id = Column(Integer, primary_key=True, autoincrement=True)
    # Caller-supplied idempotency key, one per physical event (NOT per trade -
    # the same trade_id legitimately recurs across opened -> closed_tp1 etc).
    # Recommended convention: f"{trade_id}:{event}" or ticket+timestamp.
    event_id = Column(String, unique=True, nullable=False, index=True)
    trade_id = Column(String, nullable=False)          # broker ticket / position id
    signal_id = Column(String, nullable=True, index=True)  # links back to originating Signal, if any
    symbol = Column(String, nullable=False)
    direction = Column(String, nullable=False)
    event = Column(_trade_event_type_type, nullable=False)
    volume = Column(Float, nullable=False)
    price = Column(Float, nullable=False)
    sl = Column(Float, nullable=True)
    tp1 = Column(Float, nullable=True)
    tp2 = Column(Float, nullable=True)
    profit = Column(Float, nullable=True)               # realized P/L, set on close events
    balance = Column(Float, nullable=True)
    equity = Column(Float, nullable=True)
    comment = Column(String, nullable=True)
    received_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    telegram_message_id = Column(Integer, nullable=True)
    status = Column(_trade_event_status_type, nullable=False, default=TradeEventStatus.PENDING)
    error_message = Column(Text, nullable=True)
    latency_ms = Column(Integer, nullable=True)


class Signal(Base):
    __tablename__ = "signals"
    __table_args__ = (
        Index("ix_signals_status", "status"),
    )

    id = Column(Integer, primary_key=True, autoincrement=True)
    signal_id = Column(String, unique=True, nullable=False, index=True)
    symbol = Column(String, nullable=False)
    direction = Column(String, nullable=False)
    entry = Column(Float, nullable=False)
    sl = Column(Float, nullable=False)
    tp1 = Column(Float, nullable=False)
    tp2 = Column(Float, nullable=False)
    confidence = Column(Integer, nullable=False)
    reasons = Column(JSON, nullable=False)
    timeframe = Column(String, nullable=False)
    received_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    telegram_message_id = Column(Integer, nullable=True)
    # Default to PENDING: the route inserts a PENDING row first to reserve
    # the signal_id, then resolves it to ACTIVE/FAILED after the Telegram call.
    # This Python-level default matches that intent; the migration's
    # server_default is aligned to "pending" for the same reason.
    status = Column(_signal_status_type, nullable=False, default=SignalStatus.PENDING)
    error_message = Column(Text, nullable=True)
    latency_ms = Column(Integer, nullable=True)
    # --- v2.9 additions -----------------------------------------------
    lifecycle_status = Column(_signal_lifecycle_status_type, nullable=False, default=SignalLifecycleStatus.VALID)
    lifecycle_reason = Column(String, nullable=True)          # human-readable, mirrors NewsFilter/chase-filter style reasons
    lifecycle_updated_at = Column(DateTime(timezone=True), nullable=True)
    expires_at = Column(DateTime(timezone=True), nullable=True)  # EA-computed hard expiry; NULL = no expiry set
    # Freeform diagnostics that don't warrant their own column yet: sweep
    # grade, BOS strength, decay %, chase distance, news risk tier,
    # calibrated probability + sample size, pip distances. Kept as JSON
    # (not `reasons`, which is a fixed list[str] the validator/formatter
    # already depend on) so the schema can absorb new EA-side fields
    # without a migration each time. NULL for signals from an EA build
    # older than v2.9 — formatter.py must degrade gracefully, not assume
    # this is always populated.
    extra = Column(JSON, nullable=True)
