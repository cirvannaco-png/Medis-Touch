import asyncio
import os

# Must be set before app.config.settings is constructed (module-level
# singleton), so this runs at collection time via env vars rather than
# a fixture. Using SQLite in-memory-per-file avoids touching Postgres
# or the network in CI.
os.environ.setdefault("BOT_TOKEN", "123456:test-token")
os.environ.setdefault("CHAT_ID", "-1000000000")
os.environ.setdefault("SECRET_KEY", "test-secret-key")
os.environ.setdefault("DATABASE_URL", "sqlite+aiosqlite:///./test_signals.db")
os.environ.setdefault("RATE_LIMIT_MAX_REQUESTS", "5")
os.environ.setdefault("RATE_LIMIT_WINDOW_SECONDS", "60")

import pytest
from unittest.mock import AsyncMock, patch

VALID_BUY_SIGNAL = {
    "signal_id": "test-signal-1",
    "symbol": "EURUSD",
    "direction": "BUY",
    "entry": 1.1000,
    "sl": 1.0950,
    "tp1": 1.1050,
    "tp2": 1.1100,
    "confidence": 80,
    "reasons": ["structure break confirmed", "liquidity sweep"],
    "timeframe": "M15",
}

VALID_TRADE_OPENED = {
    "event_id": "1000123:opened",
    "trade_id": "1000123",
    "signal_id": "test-signal-1",
    "symbol": "EURUSD",
    "direction": "BUY",
    "event": "opened",
    "volume": 0.10,
    "price": 1.1002,
    "sl": 1.0950,
    "tp1": 1.1050,
    "tp2": 1.1100,
}


@pytest.fixture(scope="session", autouse=True)
def _create_test_tables():
    """
    Create SQLite tables once for the entire test session.

    init_db() was intentionally removed from the app lifespan (Alembic owns
    DDL in production), but the test suite runs against SQLite with no
    migration runner, so we call it explicitly here. SQLite maps all
    PG_ENUM/Enum columns to VARCHAR — no Postgres dialect required.

    CRITICAL: app.models must be imported *before* init_db() runs. Base is a
    bare declarative_base() defined in app.database; the Signal/TradeEvent
    tables only register onto Base.metadata as a side effect of importing
    app.models. Without this import, create_all() silently creates zero
    tables and every DB-touching test fails with "no such table: signals" -
    which is exactly what happens on a clean checkout today.
    """
    import app.models  # noqa: F401 - registers Signal/TradeEvent on Base.metadata
    from app.database import engine, init_db

    async def _setup():
        await init_db()
        # Dispose the pool immediately so the connections created in this
        # event loop are not reused by subsequent asyncio.run() calls (which
        # create new event loops).  aiosqlite connections are bound to the
        # loop that created them; reusing a stale connection in a new loop
        # causes SQLAlchemy to silently open an in-memory DB instead of the
        # file, producing "no such table" errors in later teardowns.
        await engine.dispose()

    asyncio.run(_setup())


@pytest.fixture(autouse=True)
def _reset_rate_limiter():
    """Each test gets a clean rate-limit bucket state (module-level singleton)."""
    from app.ratelimit import rate_limiter
    rate_limiter._buckets.clear()
    yield
    rate_limiter._buckets.clear()


@pytest.fixture()
def client():
    """TestClient with Telegram sends mocked out - no real network calls.

    Each test gets a clean `signals` table: the app uses a single shared
    SQLite file for the whole test session, so without this a signal
    inserted by one test (e.g. a FAILED one) would leak into the next
    test's assertions about table state.
    """
    with patch("app.routes.send_telegram_message", new=AsyncMock(return_value=42)):
        from fastapi.testclient import TestClient
        from app.main import app
        from app.database import engine
        from app.models import Signal, TradeEvent

        with TestClient(app) as c:
            yield c

        async def _truncate():
            # Evict any connections that were created in a previous event
            # loop (e.g. from asyncio.run() seeding helpers in the test
            # body).  Without this, aiosqlite may silently "connect" to an
            # empty in-memory DB rather than the test file, causing
            # "no such table: signals" on every DELETE in teardown.
            await engine.dispose()
            async with engine.begin() as conn:
                await conn.run_sync(lambda sync_conn: sync_conn.execute(Signal.__table__.delete()))
                await conn.run_sync(lambda sync_conn: sync_conn.execute(TradeEvent.__table__.delete()))

        asyncio.run(_truncate())


@pytest.fixture()
def auth_headers():
    return {"X-API-Key": os.environ["SECRET_KEY"]}
