from datetime import datetime, timezone

from sqlalchemy import JSON, Column, DateTime, Index, Integer, String

from app.database import Base

SUBSCRIBER_STATUS_PENDING = "pending"
SUBSCRIBER_STATUS_ACTIVE = "active"
SUBSCRIBER_STATUS_EXPIRED = "expired"
SUBSCRIBER_STATUS_REMOVED = "removed"

PAYMENT_STATUS_SUCCEEDED = "succeeded"
PAYMENT_STATUS_REFUNDED = "refunded"


class Subscriber(Base):
    __tablename__ = "subscribers"
    __table_args__ = (Index("ix_subscribers_status", "status"),)

    id = Column(Integer, primary_key=True, autoincrement=True)
    telegram_user_id = Column(String, unique=True, nullable=False, index=True)
    telegram_username = Column(String, nullable=True)
    status = Column(String, nullable=False, default=SUBSCRIBER_STATUS_PENDING)
    current_period_end = Column(DateTime(timezone=True), nullable=True)
    copy_feed_api_key = Column(String, unique=True, nullable=True, index=True)
    warned_at = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    updated_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))


class Payment(Base):
    __tablename__ = "payments"
    __table_args__ = (Index("ix_payments_subscriber_id", "subscriber_id"),)

    id = Column(Integer, primary_key=True, autoincrement=True)
    telegram_payment_charge_id = Column(String, unique=True, nullable=False, index=True)
    subscriber_id = Column(Integer, nullable=False)
    amount = Column(Integer, nullable=False)
    currency = Column(String, nullable=False)
    period_days = Column(Integer, nullable=False)
    invoice_payload = Column(String, nullable=False)
    status = Column(String, nullable=False, default=PAYMENT_STATUS_SUCCEEDED)
    raw_payload = Column(JSON, nullable=True)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
