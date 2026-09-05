from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy.ext.asyncio import AsyncSession

from app.models import BotSetting

KEY_ENABLED = "copy_trading_enabled"
KEY_PENDING_ON = "copy_trading_pending_on"


async def _get(session: AsyncSession, key: str, default=None):
    row = await session.get(BotSetting, key)
    return row.value if row is not None else default


async def _set(session: AsyncSession, key: str, value) -> None:
    row = await session.get(BotSetting, key)
    if row is None:
        session.add(BotSetting(key=key, value=value))
    else:
        row.value = value
    await session.commit()


async def is_copy_trading_enabled(session: AsyncSession) -> bool:
    return bool(await _get(session, KEY_ENABLED, False))


async def set_copy_trading_enabled(session: AsyncSession, enabled: bool) -> None:
    await _set(session, KEY_ENABLED, bool(enabled))


async def request_copy_trading_on(session: AsyncSession, user_id: str, ttl_seconds: int) -> None:
    await _set(session, KEY_PENDING_ON, {"user_id": str(user_id), "expires_at": datetime.now(timezone.utc).timestamp() + ttl_seconds})


async def get_pending_copy_trading_on(session: AsyncSession) -> dict | None:
    value = await _get(session, KEY_PENDING_ON, None)
    if not isinstance(value, dict):
        return None
    if float(value.get("expires_at", 0)) <= datetime.now(timezone.utc).timestamp():
        await _set(session, KEY_PENDING_ON, None)
        return None
    return value


async def confirm_copy_trading_on(session: AsyncSession, user_id: str) -> bool:
    pending = await get_pending_copy_trading_on(session)
    if not pending or str(pending.get("user_id")) != str(user_id):
        return False
    await _set(session, KEY_ENABLED, True)
    await _set(session, KEY_PENDING_ON, None)
    return True
