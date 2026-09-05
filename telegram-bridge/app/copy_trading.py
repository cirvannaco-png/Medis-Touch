from __future__ import annotations

from sqlalchemy.ext.asyncio import AsyncSession

from app.copy_settings import is_copy_trading_enabled
from app.payment_models import Subscriber
from app.subscriptions import is_entitled


async def can_copy(session: AsyncSession, subscriber: Subscriber | None) -> bool:
    """Fail-closed gate: subscriber must be entitled and global copy trading on."""
    if subscriber is None or not is_entitled(subscriber):
        return False
    return await is_copy_trading_enabled(session)
