from unittest.mock import AsyncMock, patch

from tests.conftest import VALID_TRADE_OPENED


def test_trade_without_api_key_rejected(client):
    resp = client.post("/trade", json=VALID_TRADE_OPENED)
    assert resp.status_code == 422  # missing required header


def test_trade_with_wrong_api_key_rejected(client):
    resp = client.post("/trade", json=VALID_TRADE_OPENED, headers={"X-API-Key": "wrong"})
    assert resp.status_code == 401


def test_valid_trade_opened_accepted_and_sent(client, auth_headers):
    payload = {**VALID_TRADE_OPENED, "event_id": "evt-accept-1"}
    resp = client.post("/trade", json=payload, headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "sent"
    assert body["telegram_message_id"] == 42


def test_trade_close_event_without_sl_tp_is_valid(client, auth_headers):
    """Close events legitimately omit sl/tp1/tp2 - they shouldn't be required."""
    payload = {
        "event_id": "evt-close-1",
        "trade_id": "1000123",
        "symbol": "EURUSD",
        "direction": "BUY",
        "event": "closed_tp1",
        "volume": 0.10,
        "price": 1.1050,
        "profit": 48.0,
        "balance": 10048.0,
        "equity": 10048.0,
    }
    resp = client.post("/trade", json=payload, headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["status"] == "sent"


def test_trade_business_rule_violation_rejected(client, auth_headers):
    payload = {**VALID_TRADE_OPENED, "event_id": "evt-bad-1", "sl": 1.15}  # SL wrong side for BUY
    resp = client.post("/trade", json=payload, headers=auth_headers)
    assert resp.status_code == 400
    assert "errors" in resp.json()["detail"]


def test_invalid_event_type_rejected_by_schema(client, auth_headers):
    payload = {**VALID_TRADE_OPENED, "event_id": "evt-bad-2", "event": "not_a_real_event"}
    resp = client.post("/trade", json=payload, headers=auth_headers)
    assert resp.status_code == 422


def test_duplicate_event_id_returns_duplicate_status(client, auth_headers):
    payload = {**VALID_TRADE_OPENED, "event_id": "evt-dup-1"}
    first = client.post("/trade", json=payload, headers=auth_headers)
    second = client.post("/trade", json=payload, headers=auth_headers)
    assert first.json()["status"] == "sent"
    assert second.status_code == 200
    assert second.json()["status"] == "duplicate"
    assert second.json()["duplicate"] is True


def test_same_trade_id_different_events_both_accepted(client, auth_headers):
    """The same trade_id recurs across its lifecycle - only event_id is
    the idempotency key, so opened and closed_tp1 for the same trade_id
    must both succeed rather than the second being treated as a dup."""
    opened = {**VALID_TRADE_OPENED, "event_id": "1000999:opened", "trade_id": "1000999"}
    closed = {
        "event_id": "1000999:closed_tp1",
        "trade_id": "1000999",
        "symbol": "EURUSD",
        "direction": "BUY",
        "event": "closed_tp1",
        "volume": 0.10,
        "price": 1.1050,
        "profit": 48.0,
    }
    first = client.post("/trade", json=opened, headers=auth_headers)
    second = client.post("/trade", json=closed, headers=auth_headers)
    assert first.json()["status"] == "sent"
    assert second.json()["status"] == "sent"


def test_telegram_send_failure_marks_trade_event_failed(client, auth_headers):
    from app.telegram import TelegramSendError
    with patch("app.routes.send_telegram_message", new=AsyncMock(side_effect=TelegramSendError("boom"))):
        payload = {**VALID_TRADE_OPENED, "event_id": "evt-fail-1"}
        resp = client.post("/trade", json=payload, headers=auth_headers)
    assert resp.status_code == 500


def test_trade_retry_failed_requires_auth(client):
    resp = client.post("/trade/retry-failed")
    assert resp.status_code == 422


def test_trade_retry_failed_with_no_failed_events(client, auth_headers):
    resp = client.post("/trade/retry-failed", headers=auth_headers)
    assert resp.status_code == 200
    assert "No failed trade events" in resp.json()["message"]


def test_event_id_reserved_before_telegram_is_called_once(client, auth_headers):
    """Same race-condition regression test as signals: a pre-existing
    PENDING row for this event_id must short-circuit to duplicate without
    calling Telegram again."""
    import asyncio
    from app.database import async_session
    from app.models import TradeEvent, TradeEventStatus, TradeEventType

    payload = {**VALID_TRADE_OPENED, "event_id": "evt-race-1"}

    async def _seed_pending_row():
        async with async_session() as session:
            session.add(TradeEvent(
                event_id=payload["event_id"],
                trade_id=payload["trade_id"],
                signal_id=payload["signal_id"],
                symbol=payload["symbol"],
                direction=payload["direction"],
                event=TradeEventType(payload["event"]),
                volume=payload["volume"],
                price=payload["price"],
                sl=payload["sl"],
                tp1=payload["tp1"],
                tp2=payload["tp2"],
                status=TradeEventStatus.PENDING,
            ))
            await session.commit()

    asyncio.run(_seed_pending_row())

    with patch("app.routes.send_telegram_message", new=AsyncMock(return_value=99)) as mock_send:
        resp = client.post("/trade", json=payload, headers=auth_headers)

    assert resp.status_code == 200
    assert resp.json()["status"] == "duplicate"
    mock_send.assert_not_called()


def test_trade_retry_failed_reclaims_stale_pending_rows(client, auth_headers):
    import asyncio
    from datetime import datetime, timedelta, timezone
    from app.database import async_session
    from app.models import TradeEvent, TradeEventStatus, TradeEventType

    payload = {**VALID_TRADE_OPENED, "event_id": "evt-stale-pending-1"}
    stale_time = datetime.now(timezone.utc) - timedelta(seconds=999)

    async def _seed_stale_pending_row():
        async with async_session() as session:
            session.add(TradeEvent(
                event_id=payload["event_id"],
                trade_id=payload["trade_id"],
                signal_id=payload["signal_id"],
                symbol=payload["symbol"],
                direction=payload["direction"],
                event=TradeEventType(payload["event"]),
                volume=payload["volume"],
                price=payload["price"],
                sl=payload["sl"],
                tp1=payload["tp1"],
                tp2=payload["tp2"],
                status=TradeEventStatus.PENDING,
                received_at=stale_time,
            ))
            await session.commit()

    asyncio.run(_seed_stale_pending_row())

    resp = client.post("/trade/retry-failed", headers=auth_headers)
    assert resp.status_code == 200
    assert "Processed 1 failed trade events" in resp.json()["message"]
