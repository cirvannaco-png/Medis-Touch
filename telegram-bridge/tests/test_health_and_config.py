"""Regression tests for the health-check route and config validation.

Covers two production findings from the 2026-08-07 deploy log:
  * Render's platform probe sends `HEAD /` before marking a deploy live;
    FastAPI does not add HEAD to a GET route automatically, so it 405'd.
  * WEBHOOK_SECRET_TOKEN must match Telegram's ^[A-Za-z0-9_-]{1,256}$ or
    set_webhook() fails with a BadRequest that init_bot() swallows.
"""

import pytest
from pydantic import ValidationError


def test_health_check_get(client):
    response = client.get("/")
    assert response.status_code == 200
    assert response.json()["status"] == "online"


def test_health_check_head(client):
    """Render's health probe uses HEAD - must not 405."""
    response = client.head("/")
    assert response.status_code == 200


@pytest.mark.parametrize("bad_token", ["bad token!", "abc+def", "a/b", "eq=", ""])
def test_invalid_webhook_secret_token_rejected(bad_token, monkeypatch):
    from app.config import Settings

    monkeypatch.setenv("WEBHOOK_SECRET_TOKEN", bad_token)
    with pytest.raises(ValidationError):
        Settings()


def test_valid_webhook_secret_token_accepted(monkeypatch):
    from app.config import Settings

    monkeypatch.setenv("WEBHOOK_SECRET_TOKEN", "a1b2c3d4-e5f6_7890")
    assert Settings().WEBHOOK_SECRET_TOKEN == "a1b2c3d4-e5f6_7890"
