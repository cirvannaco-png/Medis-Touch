from datetime import datetime, timezone
import enum
import sqlalchemy as sa
from sqlalchemy import Column, DateTime, Float, Index, Integer, String, Text
from app.database import Base

class SubscriptionStatus(str, enum.Enum):
    PENDING = "pending"
    ACTIVE = "active"
    EXPIRED = "expired"
    CANCELLED = "cancelled"
    SUSPENDED = "suspended"

class PaymentStatus(str, enum.Enum):
    PENDING = "pending"
    PAID = "paid"
    FAILED = "failed"
    REFUNDED = "refunded"

class EntitlementStatus(str, enum.Enum):
    ACTIVE = "active"
    EXPIRED = "expired"
    REVOKED = "revoked"

class CopyEventStatus(str, enum.Enum):
    PENDING = "pending"
    CLAIMED = "claimed"
    EXECUTED = "executed"
    SKIPPED = "skipped"
    FAILED = "failed"

class Payment(Base):
    __tablename__ = "payments"
    __table_args__ = (Index("ix_payments_user_status", "user_id", "status"),)
    id = Column(Integer, primary_key=True)
    payment_id = Column(String, unique=True, nullable=False, index=True)
    user_id = Column(String, nullable=False, index=True)
    provider = Column(String, nullable=False, default="generic")
    provider_reference = Column(String, nullable=True, index=True)
    amount = Column(Float, nullable=False)
    currency = Column(String, nullable=False, default="KES")
    plan = Column(String, nullable=False)
    status = Column(String, nullable=False, default=PaymentStatus.PENDING.value)
    paid_at = Column(DateTime(timezone=True), nullable=True)
    raw_payload = Column(sa.JSON, nullable=True)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

class Subscription(Base):
    __tablename__ = "subscriptions"
    __table_args__ = (Index("ix_subscriptions_user_status", "user_id", "status"),)
    id = Column(Integer, primary_key=True)
    subscription_id = Column(String, unique=True, nullable=False, index=True)
    user_id = Column(String, nullable=False, index=True)
    plan = Column(String, nullable=False)
    status = Column(String, nullable=False, default=SubscriptionStatus.PENDING.value)
    started_at = Column(DateTime(timezone=True), nullable=True)
    expires_at = Column(DateTime(timezone=True), nullable=True, index=True)
    payment_id = Column(String, nullable=True, index=True)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    updated_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))

class Entitlement(Base):
    __tablename__ = "entitlements"
    __table_args__ = (Index("ix_entitlements_user_status", "user_id", "status"),)
    id = Column(Integer, primary_key=True)
    entitlement_id = Column(String, unique=True, nullable=False, index=True)
    user_id = Column(String, nullable=False, index=True)
    subscription_id = Column(String, nullable=False, index=True)
    telegram_access = Column(sa.Boolean, nullable=False, default=True)
    signal_access = Column(sa.Boolean, nullable=False, default=True)
    copy_trading = Column(sa.Boolean, nullable=False, default=True)
    status = Column(String, nullable=False, default=EntitlementStatus.ACTIVE.value)
    valid_from = Column(DateTime(timezone=True), nullable=False)
    valid_until = Column(DateTime(timezone=True), nullable=False, index=True)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

class CopyAccount(Base):
    __tablename__ = "copy_accounts"
    __table_args__ = (Index("ix_copy_accounts_user_enabled", "user_id", "copy_enabled"),)
    id = Column(Integer, primary_key=True)
    account_id = Column(String, unique=True, nullable=False, index=True)
    user_id = Column(String, nullable=False, index=True)
    broker = Column(String, nullable=False)
    server = Column(String, nullable=True)
    ea_instance = Column(String, nullable=True)
    risk_mode = Column(String, nullable=False, default="percent")
    risk_value = Column(Float, nullable=False, default=0.5)
    copy_enabled = Column(sa.Boolean, nullable=False, default=True)
    last_seen_at = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

class CopyTradeEvent(Base):
    __tablename__ = "copy_trade_events"
    __table_args__ = (Index("ix_copy_events_account_status", "account_id", "status"), Index("ix_copy_events_signal", "signal_id"))
    id = Column(Integer, primary_key=True)
    copy_id = Column(String, unique=True, nullable=False, index=True)
    signal_id = Column(String, nullable=False, index=True)
    account_id = Column(String, nullable=False, index=True)
    strategy = Column(String, nullable=True)
    symbol = Column(String, nullable=False)
    direction = Column(String, nullable=False)
    entry = Column(Float, nullable=False)
    sl = Column(Float, nullable=False)
    tp1 = Column(Float, nullable=False)
    tp2 = Column(Float, nullable=False)
    final_tp = Column(Float, nullable=True)
    risk_mode = Column(String, nullable=False)
    risk_value = Column(Float, nullable=False)
    status = Column(String, nullable=False, default=CopyEventStatus.PENDING.value)
    broker_ticket = Column(String, nullable=True)
    error_message = Column(Text, nullable=True)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    claimed_at = Column(DateTime(timezone=True), nullable=True)
    executed_at = Column(DateTime(timezone=True), nullable=True)

class SignalMessageState(Base):
    __tablename__ = "signal_message_states"
    signal_id = Column(String, primary_key=True)
    telegram_message_id = Column(Integer, nullable=True)
    state = Column(String, nullable=False, default="valid")
    last_update_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
