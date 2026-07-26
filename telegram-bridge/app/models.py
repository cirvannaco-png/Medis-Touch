import enum
from datetime import datetime, timezone

from sqlalchemy import JSON, Column, DateTime, Float, Index, Integer, String, Text
from sqlalchemy import Enum as SAEnum

from app.database import Base


class SignalStatus(str, enum.Enum):
    PENDING = "pending"                  # signal_id reserved, Telegram call not yet resolved
    ACTIVE = "active"
    FAILED = "failed"                    # transient failure, eligible for /retry-failed
    PERMANENTLY_FAILED = "permanently_failed"  # NonRetryableError - do not keep retrying
    DUPLICATE = "duplicate"


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
    status = Column(SAEnum(SignalStatus), nullable=False, default=SignalStatus.PENDING)
    error_message = Column(Text, nullable=True)
    latency_ms = Column(Integer, nullable=True)
