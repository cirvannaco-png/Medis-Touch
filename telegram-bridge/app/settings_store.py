"""
Read/write helpers for app.models.BotSetting.

This backs the operator controls exposed via Telegram (/mute, /unmute,
/pause, /resume) and consulted by POST /signal before it broadcasts a new
signal to CHAT_ID. Kept as a tiny module of its own, rather than folding
straight into routes.py or bot_handlers.py, so both can import the same
read path without a circular import (routes.py needs it to gate
broadcasting; bot_handlers.py needs it to report/change state).

Every function opens nothing itself - callers pass in an already-open
AsyncSession (the same pattern used throughout routes.py/bot_handlers.py)
so this stays transaction-agnostic and testable.
"""

from __future__ import annotations

from sqlalchemy.ext.asyncio import AsyncSession

from app.models import BotSetting

_KEY_MUTED_SYMBOLS = "muted_symbols"
_KEY_BROADCAST_PAUSED = "broadcast_paused"


async def _get(session: AsyncSession, key: str, default):
    row = await session.get(BotSetting, key)
    return row.value if row is not None else default


async def _set(session: AsyncSession, key: str, value) -> None:
    row = await session.get(BotSetting, key)
    if row is None:
        session.add(BotSetting(key=key, value=value))
    else:
        row.value = value
    await session.commit()


async def get_muted_symbols(session: AsyncSession) -> set[str]:
    return set(await _get(session, _KEY_MUTED_SYMBOLS, []))


async def mute_symbol(session: AsyncSession, symbol: str) -> set[str]:
    symbols = await get_muted_symbols(session)
    symbols.add(symbol.upper())
    await _set(session, _KEY_MUTED_SYMBOLS, sorted(symbols))
    return symbols


async def unmute_symbol(session: AsyncSession, symbol: str) -> set[str]:
    symbols = await get_muted_symbols(session)
    symbols.discard(symbol.upper())
    await _set(session, _KEY_MUTED_SYMBOLS, sorted(symbols))
    return symbols


async def is_symbol_muted(session: AsyncSession, symbol: str) -> bool:
    return symbol.upper() in await get_muted_symbols(session)


async def is_broadcast_paused(session: AsyncSession) -> bool:
    return bool(await _get(session, _KEY_BROADCAST_PAUSED, False))


async def set_broadcast_paused(session: AsyncSession, paused: bool) -> None:
    await _set(session, _KEY_BROADCAST_PAUSED, paused)
