"""Subscriber entitlement and idempotent Telegram payment domain logic."""

from __future__ import annotations

import secrets
from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.logger import logger
from app.payment_models import PAYMENT_STATUS_SUCCEEDED, SUBSCRIBER_STATUS_ACTIVE, SUBSCRIBER_STATUS_PENDING, Payment, Subscriber


def _generate_copy_feed_key() -> str:
    return secrets.token_urlsafe(32)


def _as_utc(dt: datetime | None) -> datetime | None:
    return dt.replace(tzinfo=timezone.utc) if dt is not None and dt.tzinfo is None else dt


async def get_subscriber_by_user_id(session: AsyncSession, telegram_user_id: str) -> Subscriber | None:
    return await session.scalar(select(Subscriber).where(Subscriber.telegram_user_id == str(telegram_user_id)))


async def get_subscriber_by_copy_feed_key(session: AsyncSession, copy_feed_api_key: str) -> Subscriber | None:
    if not copy_feed_api_key:
        return None
    return await session.scalar(select(Subscriber).where(Subscriber.copy_feed_api_key == copy_feed_api_key))


async def get_or_create_subscriber(session: AsyncSession, telegram_user_id: str, telegram_username: str | None) -> Subscriber:
    subscriber = await get_subscriber_by_user_id(session, telegram_user_id)
    if subscriber is not None:
        if telegram_username and subscriber.telegram_username != telegram_username:
            subscriber.telegram_username = telegram_username
            await session.commit()
        return subscriber
    subscriber = Subscriber(telegram_user_id=str(telegram_user_id), telegram_username=telegram_username, status=SUBSCRIBER_STATUS_PENDING)
    session.add(subscriber)
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        subscriber = await get_subscriber_by_user_id(session, telegram_user_id)
    return subscriber


def is_entitled(subscriber: Subscriber | None) -> bool:
    if subscriber is None or subscriber.status != SUBSCRIBER_STATUS_ACTIVE:
        return False
    end = _as_utc(subscriber.current_period_end)
    return end is not None and end > datetime.now(timezone.utc)


async def record_payment(session: AsyncSession, subscriber: Subscriber, *, telegram_payment_charge_id: str, amount: int, currency: str, invoice_payload: str, raw_payload: dict, period_days: int | None = None) -> Payment | None:
    period_days = period_days or settings.SUBSCRIPTION_PERIOD_DAYS
    payment = Payment(telegram_payment_charge_id=telegram_payment_charge_id, subscriber_id=subscriber.id, amount=amount, currency=currency, period_days=period_days, invoice_payload=invoice_payload, status=PAYMENT_STATUS_SUCCEEDED, raw_payload=raw_payload)
    session.add(payment)
    try:
        await session.flush()
    except IntegrityError:
        await session.rollback()
        await session.refresh(subscriber)
        logger.info("Duplicate successful_payment ignored (telegram_payment_charge_id=%s)", telegram_payment_charge_id)
        return None
    now = datetime.now(timezone.utc)
    existing_end = _as_utc(subscriber.current_period_end)
    base = existing_end if existing_end and existing_end > now else now
    subscriber.current_period_end = base + timedelta(days=period_days)
    subscriber.status = SUBSCRIBER_STATUS_ACTIVE
    subscriber.copy_feed_api_key = _generate_copy_feed_key()
    subscriber.warned_at = None
    await session.commit()
    return payment
