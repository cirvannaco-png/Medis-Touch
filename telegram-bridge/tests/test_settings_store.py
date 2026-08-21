"""Tests for app.settings_store and the Telegram command handlers built on
top of it (mute/unmute/muted/pause/resume/stats/symbols/status/retry/version).

Handlers are invoked directly with a fake Update/Context, the same pattern
test_bot.py uses for /signal and /positions - not via /telegram/webhook,
since that requires python-telegram-bot's Application to have actually
initialized against api.telegram.org, which this sandbox's network egress
does not allow (see test_bot.py's module docstring). Direct invocation
still exercises real handler code, real DB queries, and the real
@_authorized_only decorator; it just skips PTB's own update-routing, which
app/bot.py's CommandHandler registration already covers structurally (a
handler registered under the wrong command name would simply never be
reachable from Telegram, not something a unit test catches either way).
"""
import asyncio
import os

from tests.conftest import VALID_BUY_SIGNAL

AUTHORIZED_CHAT_ID = int(os.environ["ADMIN_CHAT_ID"])
UNAUTHORIZED_CHAT_ID = 999999999


class _FakeMessage:
    def __init__(self):
        self.replies: list[str] = []

    async def reply_text(self, text):
        self.replies.append(text)


class _FakeChat:
    def __init__(self, chat_id):
        self.id = chat_id


class _FakeUser:
    def __init__(self, user_id):
        self.id = user_id


class _FakeUpdate:
    def __init__(self, chat_id=AUTHORIZED_CHAT_ID, user_id=None):
        self.effective_chat = _FakeChat(chat_id)
        self.effective_user = _FakeUser(chat_id if user_id is None else user_id)
        self.message = _FakeMessage()


class _FakeContext:
    def __init__(self, args=None):
        self.args = args or []


def _run(handler, update, context=None):
    asyncio.run(handler(update, context))
    return update.message.replies


# ---------- settings_store + POST /signal suppression ----------

def test_muted_symbol_suppresses_broadcast(client, auth_headers):
    from app.database import async_session
    from app.settings_store import mute_symbol

    async def _mute():
        async with async_session() as session:
            await mute_symbol(session, "EURUSD")

    asyncio.run(_mute())

    resp = client.post("/signal", json=VALID_BUY_SIGNAL, headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "suppressed"
    assert body["telegram_message_id"] is None


def test_unmuted_symbol_still_broadcasts(client, auth_headers):
    resp = client.post("/signal", json=VALID_BUY_SIGNAL, headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["status"] == "sent"


def test_paused_broadcast_suppresses_all_symbols(client, auth_headers):
    from app.database import async_session
    from app.settings_store import set_broadcast_paused

    async def _pause():
        async with async_session() as session:
            await set_broadcast_paused(session, True)

    asyncio.run(_pause())

    resp = client.post("/signal", json=VALID_BUY_SIGNAL, headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["status"] == "suppressed"


# ---------- /mute, /unmute, /muted ----------

def test_mute_command_then_signal_suppressed(client, auth_headers):
    from app.bot_handlers import mute as mute_handler

    replies = _run(mute_handler, _FakeUpdate(), _FakeContext(["EURUSD"]))
    assert replies and "EURUSD" in replies[0]

    resp = client.post("/signal", json=VALID_BUY_SIGNAL, headers=auth_headers)
    assert resp.json()["status"] == "suppressed"


def test_unmute_command_restores_broadcast(client, auth_headers):
    from app.bot_handlers import mute as mute_handler
    from app.bot_handlers import unmute as unmute_handler

    _run(mute_handler, _FakeUpdate(), _FakeContext(["EURUSD"]))
    replies = _run(unmute_handler, _FakeUpdate(), _FakeContext(["EURUSD"]))
    assert replies and "unmuted" in replies[0].lower()

    resp = client.post("/signal", json=VALID_BUY_SIGNAL, headers=auth_headers)
    assert resp.json()["status"] == "sent"


def test_mute_command_without_symbol_argument_shows_usage():
    """/mute with no argument must not raise IndexError on empty context.args -
    it should reply with usage guidance instead."""
    from app.bot_handlers import mute as mute_handler

    replies = _run(mute_handler, _FakeUpdate(), _FakeContext([]))
    assert replies and "usage" in replies[0].lower()


def test_muted_command_lists_muted_symbols():
    from app.bot_handlers import mute as mute_handler
    from app.bot_handlers import muted_command

    _run(mute_handler, _FakeUpdate(), _FakeContext(["GBPJPY"]))
    replies = _run(muted_command, _FakeUpdate(), _FakeContext())
    assert replies and "GBPJPY" in replies[0]


def test_unauthorized_chat_cannot_mute(client, auth_headers):
    """Same authorization boundary as every other command - a message from
    outside ADMIN_CHAT_ID must not be able to mute a symbol."""
    from app.bot_handlers import mute as mute_handler

    replies = _run(mute_handler, _FakeUpdate(UNAUTHORIZED_CHAT_ID), _FakeContext(["EURUSD"]))
    assert replies == []  # _authorized_only short-circuits before any reply

    resp = client.post("/signal", json=VALID_BUY_SIGNAL, headers=auth_headers)
    assert resp.json()["status"] == "sent"  # mute never actually applied


# ---------- /pause, /resume ----------

def test_pause_then_resume_commands(client, auth_headers):
    from app.bot_handlers import pause as pause_handler
    from app.bot_handlers import resume as resume_handler

    signal_a = {**VALID_BUY_SIGNAL, "signal_id": "pause-test-1"}
    signal_b = {**VALID_BUY_SIGNAL, "signal_id": "pause-test-2"}

    _run(pause_handler, _FakeUpdate(), _FakeContext())
    resp = client.post("/signal", json=signal_a, headers=auth_headers)
    assert resp.json()["status"] == "suppressed"

    _run(resume_handler, _FakeUpdate(), _FakeContext())
    resp = client.post("/signal", json=signal_b, headers=auth_headers)
    assert resp.json()["status"] == "sent"


# ---------- reply-only commands: stats, symbols, status, version, retry ----------

def test_stats_command_reflects_stored_signal(client, auth_headers):
    from app.bot_handlers import stats as stats_handler

    client.post("/signal", json=VALID_BUY_SIGNAL, headers=auth_headers)
    replies = _run(stats_handler, _FakeUpdate(), _FakeContext())
    assert replies and "Signals received: 1" in replies[0]


def test_symbols_command_lists_muted_and_active(client, auth_headers):
    from app.bot_handlers import mute as mute_handler
    from app.bot_handlers import symbols_command

    client.post("/signal", json=VALID_BUY_SIGNAL, headers=auth_headers)
    _run(mute_handler, _FakeUpdate(), _FakeContext(["GBPJPY"]))

    replies = _run(symbols_command, _FakeUpdate(), _FakeContext())
    assert replies
    assert VALID_BUY_SIGNAL["symbol"] in replies[0]
    assert "GBPJPY" in replies[0] and "muted" in replies[0]


def test_status_command_reports_db_connected():
    from app.bot_handlers import status as status_handler

    replies = _run(status_handler, _FakeUpdate(), _FakeContext())
    assert replies and "connected" in replies[0]


def test_version_command_reports_version():
    from app.bot_handlers import version_command
    from app.config import APP_VERSION

    replies = _run(version_command, _FakeUpdate(), _FakeContext())
    assert replies and APP_VERSION in replies[0]


def test_retry_command_runs_without_error():
    """/retry exercises the shared retry_failed_*_core() helpers from
    app/routes.py through the bot handler - confirms the deferred import
    (used to avoid a circular import with app.routes) actually resolves
    at call time and the handler completes."""
    from app.bot_handlers import retry as retry_handler

    replies = _run(retry_handler, _FakeUpdate(), _FakeContext())
    assert len(replies) == 2  # "Retrying..." ack, then the result summary
    assert "Signals:" in replies[1] and "Trade events:" in replies[1]
