"""
Copy-trading entitlement gate.

Entitlement is evaluated at READ time, when a paying subscriber's own
copier polls GET /copy/feed. This service never places trades and never
handles subscriber broker credentials.
"""

from __future__ import annotations

from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Subscriber
from app.settings_store import is_copy_trading_enabled
from app.subscriptions import is_entitled


async def can_copy(session: AsyncSession, subscriber: Subscriber | None) -> bool:
    """Fail-closed gate: subscriber must be entitled and global copy trading on."""
    if subscriber is None:
        return False
    if not is_entitled(subscriber):
        return False
    return await is_copy_trading_enabled(session)
