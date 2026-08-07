"""
Tests for the inbound bot: webhook auth, and command handlers against
real (SQLite-backed) signals/trade_events data.

Network calls to Telegram itself (bot.initialize()'s get_me(), set_my_commands,
set_webhook) are not reachable in CI/sandboxed environments - app/bot.py
is written to catch and log those failures rather than raise (see
init_bot()), so the app still starts and `application` is still usable for
process_update() even when Telegram itself was unreachable at startup.
"""

import os

from tests.conftest import VALID_BUY_SIGNAL, VALID_TRADE_OPENED

AUTHORIZED_CHAT_ID = int(os.environ["CHAT_ID"])


def _update(text: str, chat_id: int = AUTHORIZED_CHAT_ID, update_id: int = 1):
    return {
        "update_id": update_id,
        "message": {
            "message_id": update_id,
            "date": 0,
            "chat": {"id": chat_id, "type": "group"},
            "from": {"id": chat_id, "is_bot": False, "first_name": "Kelson"},
            "text": text,
        },
    }


def test_webhook_rejects_missing_secret_token(client):
    resp = client.post("/telegram/webhook", json=_update("/start"))
    assert resp.status_code == 401


def test_webhook_rejects_wrong_secret_token(client):
    resp = client.post(
        "/telegram/webhook",
        json=_update("/start"),
        headers={"X-Telegram-Bot-Api-Secret-Token": "wrong"},
    )
    assert resp.status_code == 401


def test_webhook_accepts_correct_secret_token(client):
    headers = {"X-Telegram-Bot-Api-Secret-Token": os.environ["WEBHOOK_SECRET_TOKEN"]}
    resp = client.post("/telegram/webhook", json=_update("/start"), headers=headers)
    assert resp.status_code == 200
    assert resp.json() == {"ok": True}


def test_start_replies_only_to_authorized_chat(client):
    """
    An update from a chat_id other than settings.CHAT_ID must not produce a
    reply. We can't easily intercept the outbound sendMessage call (that's
    inside python-telegram-bot, not app.telegram), but we can assert the
    webhook itself still returns 200 (accepted, not an error) even though
    the handler internally no-ops for the wrong chat - i.e. it doesn't
    crash the request.
    """
    headers = {"X-Telegram-Bot-Api-Secret-Token": os.environ["WEBHOOK_SECRET_TOKEN"]}
    resp = client.post(
        "/telegram/webhook",
        json=_update("/start", chat_id=999999999, update_id=2),
        headers=headers,
    )
    assert resp.status_code == 200


def test_signal_handler_reflects_stored_signal(client, auth_headers):
    """/signal should reflect a signal that was actually POSTed and stored,
    not a canned response - exercises the real DB query path."""
    from app.bot_handlers import signal as signal_handler

    client.post("/signal", json=VALID_BUY_SIGNAL, headers=auth_headers)

    class _FakeMessage:
        def __init__(self):
            self.replies = []

        async def reply_text(self, text):
            self.replies.append(text)

    class _FakeChat:
        id = AUTHORIZED_CHAT_ID

    class _FakeUpdate:
        effective_chat = _FakeChat()
        message = _FakeMessage()

    import asyncio

    update = _FakeUpdate()
    asyncio.run(signal_handler(update, context=None))

    assert update.message.replies, "handler did not reply"
    assert VALID_BUY_SIGNAL["symbol"] in update.message.replies[0]
    assert VALID_BUY_SIGNAL["direction"] in update.message.replies[0]


def test_positions_handler_reflects_open_trade(client, auth_headers):
    """/positions should list a trade that was opened but never closed."""
    from app.bot_handlers import positions as positions_handler

    client.post("/trade", json=VALID_TRADE_OPENED, headers=auth_headers)

    class _FakeMessage:
        def __init__(self):
            self.replies = []

        async def reply_text(self, text):
            self.replies.append(text)

    class _FakeChat:
        id = AUTHORIZED_CHAT_ID

    class _FakeUpdate:
        effective_chat = _FakeChat()
        message = _FakeMessage()

    import asyncio

    update = _FakeUpdate()
    asyncio.run(positions_handler(update, context=None))

    assert update.message.replies
    assert VALID_TRADE_OPENED["symbol"] in update.message.replies[0]


def test_unauthorized_chat_gets_no_reply():
    """The _authorized_only decorator must short-circuit before touching
    the DB or replying, for any chat_id other than settings.CHAT_ID."""
    import asyncio

    from app.bot_handlers import start as start_handler

    class _FakeMessage:
        def __init__(self):
            self.replies = []

        async def reply_text(self, text):
            self.replies.append(text)

    class _FakeChat:
        id = 424242

    class _FakeUpdate:
        effective_chat = _FakeChat()
        message = _FakeMessage()

    update = _FakeUpdate()
    asyncio.run(start_handler(update, context=None))

    assert update.message.replies == []
