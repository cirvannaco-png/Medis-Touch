from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app import telegram
from app.config import settings
from app.logger import logger
from app.payment_models import SUBSCRIBER_STATUS_ACTIVE, SUBSCRIBER_STATUS_EXPIRED, SUBSCRIBER_STATUS_REMOVED, Subscriber


async def sweep_subscriber_statuses(session: AsyncSession) -> dict[str, list[Subscriber]]:
    now = datetime.now(timezone.utc)
    warning_cutoff = now + timedelta(hours=settings.SUBSCRIPTION_WARNING_HOURS_BEFORE_EXPIRY)
    grace_cutoff = now - timedelta(days=settings.SUBSCRIPTION_GRACE_PERIOD_DAYS)
    to_warn = (await session.execute(select(Subscriber).where(Subscriber.status == SUBSCRIBER_STATUS_ACTIVE, Subscriber.current_period_end.is_not(None), Subscriber.current_period_end <= warning_cutoff, Subscriber.current_period_end > now, Subscriber.warned_at.is_(None)))).scalars().all()
    for s in to_warn:
        s.warned_at = now
    to_expire = (await session.execute(select(Subscriber).where(Subscriber.status == SUBSCRIBER_STATUS_ACTIVE, Subscriber.current_period_end.is_not(None), Subscriber.current_period_end <= now))).scalars().all()
    for s in to_expire:
        s.status = SUBSCRIBER_STATUS_EXPIRED
    to_remove = (await session.execute(select(Subscriber).where(Subscriber.status == SUBSCRIBER_STATUS_EXPIRED, Subscriber.current_period_end.is_not(None), Subscriber.current_period_end <= grace_cutoff))).scalars().all()
    for s in to_remove:
        s.status = SUBSCRIBER_STATUS_REMOVED
    await session.commit()
    return {"warn": to_warn, "expire": to_expire, "remove": to_remove}


async def run_subscription_enforcement(session: AsyncSession) -> dict:
    result = await sweep_subscriber_statuses(session)
    warned = 0
    for s in result["warn"]:
        warned += int(await telegram.send_dm(s.telegram_user_id, f"⏳ Your Medis Touch access expires {s.current_period_end.strftime('%Y-%m-%d %H:%M UTC')} — send /subscribe to renew."))
    removed = 0
    for s in result["remove"]:
        if settings.GROUP_CHAT_ID:
            await telegram.ban_chat_member(settings.GROUP_CHAT_ID, s.telegram_user_id)
            await telegram.unban_chat_member(settings.GROUP_CHAT_ID, s.telegram_user_id)
        else:
            logger.warning("GROUP_CHAT_ID not set — subscriber %s marked REMOVED", s.telegram_user_id)
        await telegram.send_dm(s.telegram_user_id, "Your Medis Touch subscription lapsed and the grace period ended. Send /subscribe to rejoin.")
        removed += 1
    return {"warned": warned, "expired": len(result["expire"]), "removed": removed}
