from unittest.mock import AsyncMock, patch

from tests.conftest import VALID_BUY_SIGNAL


def test_health_check_no_auth_required(client):
    resp = client.get("/")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "online"
    assert body["database"] == "not checked"


def test_health_db_reports_connected(client):
    resp = client.get("/health/db")
    assert resp.status_code == 200
    assert resp.json()["database"] == "connected"


def test_signal_without_api_key_rejected(client):
    resp = client.post("/signal", json=VALID_BUY_SIGNAL)
    assert resp.status_code == 422  # missing required header


def test_signal_with_wrong_api_key_rejected(client):
    resp = client.post("/signal", json=VALID_BUY_SIGNAL, headers={"X-API-Key": "wrong"})
    assert resp.status_code == 401


def test_valid_signal_accepted_and_sent(client, auth_headers):
    payload = {**VALID_BUY_SIGNAL, "signal_id": "sig-accept-1"}
    resp = client.post("/signal", json=payload, headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "sent"
    assert body["telegram_message_id"] == 42


def test_business_rule_violation_rejected(client, auth_headers):
    payload = {**VALID_BUY_SIGNAL, "signal_id": "sig-bad-1", "sl": 1.15}  # SL wrong side
    resp = client.post("/signal", json=payload, headers=auth_headers)
    assert resp.status_code == 400
    assert "errors" in resp.json()["detail"]


def test_invalid_direction_rejected_by_schema(client, auth_headers):
    payload = {**VALID_BUY_SIGNAL, "signal_id": "sig-bad-2", "direction": "HOLD"}
    resp = client.post("/signal", json=payload, headers=auth_headers)
    assert resp.status_code == 422


def test_duplicate_signal_id_returns_duplicate_status(client, auth_headers):
    payload = {**VALID_BUY_SIGNAL, "signal_id": "sig-dup-1"}
    first = client.post("/signal", json=payload, headers=auth_headers)
    second = client.post("/signal", json=payload, headers=auth_headers)
    assert first.json()["status"] == "sent"
    assert second.status_code == 200
    assert second.json()["status"] == "duplicate"
    assert second.json()["duplicate"] is True


def test_rate_limit_enforced_after_max_requests(client, auth_headers, forced_rate_limit):
    # The limiter is force-enabled at max_requests=5 by the fixture, so this
    # test does not depend on RATE_LIMIT_* env vars (CI sets
    # RATE_LIMIT_ENABLED=false, which would otherwise make 429 unreachable).
    codes = []
    for i in range(7):
        payload = {**VALID_BUY_SIGNAL, "signal_id": f"sig-rl-{i}"}
        resp = client.post("/signal", json=payload, headers=auth_headers)
        codes.append(resp.status_code)
    assert codes[:5] == [200] * 5
    assert codes[5:] == [429, 429]


def test_telegram_send_failure_marks_signal_failed(client, auth_headers):
    from app.telegram import TelegramSendError
    with patch("app.routes.send_telegram_message", new=AsyncMock(side_effect=TelegramSendError("boom"))):
        payload = {**VALID_BUY_SIGNAL, "signal_id": "sig-fail-1"}
        resp = client.post("/signal", json=payload, headers=auth_headers)
    assert resp.status_code == 500


def test_retry_failed_requires_auth(client):
    resp = client.post("/retry-failed")
    assert resp.status_code == 422


def test_retry_failed_with_no_failed_signals(client, auth_headers):
    resp = client.post("/retry-failed", headers=auth_headers)
    assert resp.status_code == 200
    assert "No failed signals" in resp.json()["message"]


def test_signal_id_reserved_before_telegram_is_called_once(client, auth_headers):
    """
    Regression test for the double-send race: a signal_id that has already
    been reserved (PENDING row present) must short-circuit to "duplicate"
    without calling Telegram again, even if the first request never
    resolved. This is what actually prevents two Telegram messages for one
    signal_id under a real concurrent race - previously the reservation
    didn't exist and both requests could reach send_telegram_message.
    """
    import asyncio

    from app.database import async_session
    from app.models import Signal, SignalStatus

    payload = {**VALID_BUY_SIGNAL, "signal_id": "sig-race-1"}

    async def _seed_pending_row():
        async with async_session() as session:
            session.add(Signal(
                signal_id=payload["signal_id"],
                symbol=payload["symbol"],
                direction=payload["direction"],
                entry=payload["entry"],
                sl=payload["sl"],
                tp1=payload["tp1"],
                tp2=payload["tp2"],
                confidence=payload["confidence"],
                reasons=payload["reasons"],
                timeframe=payload["timeframe"],
                status=SignalStatus.PENDING,
            ))
            await session.commit()

    asyncio.run(_seed_pending_row())

    with patch("app.routes.send_telegram_message", new=AsyncMock(return_value=99)) as mock_send:
        resp = client.post("/signal", json=payload, headers=auth_headers)

    assert resp.status_code == 200
    assert resp.json()["status"] == "duplicate"
    mock_send.assert_not_called()


def test_retry_failed_reclaims_stale_pending_rows(client, auth_headers):
    """A row stuck at PENDING (e.g. process crashed mid-send) older than
    PENDING_STALE_SECONDS should be picked up by /retry-failed, same as a
    FAILED row - otherwise it never recovers."""
    import asyncio
    from datetime import datetime, timedelta, timezone

    from app.database import async_session
    from app.models import Signal, SignalStatus

    payload = {**VALID_BUY_SIGNAL, "signal_id": "sig-stale-pending-1"}
    stale_time = datetime.now(timezone.utc) - timedelta(seconds=999)

    async def _seed_stale_pending_row():
        async with async_session() as session:
            session.add(Signal(
                signal_id=payload["signal_id"],
                symbol=payload["symbol"],
                direction=payload["direction"],
                entry=payload["entry"],
                sl=payload["sl"],
                tp1=payload["tp1"],
                tp2=payload["tp2"],
                confidence=payload["confidence"],
                reasons=payload["reasons"],
                timeframe=payload["timeframe"],
                status=SignalStatus.PENDING,
                received_at=stale_time,
            ))
            await session.commit()

    asyncio.run(_seed_stale_pending_row())

    resp = client.post("/retry-failed", headers=auth_headers)
    assert resp.status_code == 200
    assert "Processed 1 failed signals" in resp.json()["message"]
