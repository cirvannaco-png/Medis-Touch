"""
tools/tests/conftest.py — shared fixtures for the tools/ test suite.

metrics_engine.py and walk_forward.py import telegram-bridge's `app`
package at module level (DB models/session, reused rather than
duplicated -- see tools/_pathutil.py). Constructing app.config.Settings()
requires these env vars to be set BEFORE that import happens, same
requirement telegram-bridge/tests/conftest.py has for the exact same
reason (Settings is a module-level singleton). Set here, at collection
time, not inside a fixture, for the same reason that file does it that
way -- by the time a fixture function body runs, collection has already
imported every test module, which is too late.

gating.py and stats.py have no such dependency at module level -- these
vars are harmless no-ops for those test files.
"""
import os

os.environ.setdefault("BOT_TOKEN", "123456:test-token")
os.environ.setdefault("CHAT_ID", "-1000000000")
os.environ.setdefault("ADMIN_CHAT_ID", "777000777")
os.environ.setdefault("SECRET_KEY", "test-secret-key")
os.environ.setdefault("WEBHOOK_SECRET_TOKEN", "test-webhook-secret")
os.environ.setdefault("DATABASE_URL", "sqlite+aiosqlite:///./tools_test.db")
os.environ.setdefault("RATE_LIMIT_MAX_REQUESTS", "5")
os.environ.setdefault("RATE_LIMIT_WINDOW_SECONDS", "60")

import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone

import pytest

_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_TOOLS_DIR = os.path.dirname(_TESTS_DIR)
if _TOOLS_DIR not in sys.path:
    sys.path.insert(0, _TOOLS_DIR)


@dataclass
class FakeOutcome:
    """
    Stand-in for app.models.SignalOutcome carrying exactly the attributes
    every function under test reads by name (see that model's own field
    list in telegram-bridge/app/models.py) -- NOT a copy of the ORM
    class, since none of compute_report(), compute_regime_matrix(),
    split_train_holdout(), or decide() touch the database; they only
    ever do plain attribute access on whatever `rows` they're handed.
    Constructing real ORM instances here would need a live DB session
    for zero benefit -- these functions can't tell the difference.
    """
    symbol: str = "XAUUSD"
    direction: str = "BUY"
    outcome: str = "win"          # win | loss | scratch | no_fill | ambiguous
    realized_r: float | None = None
    regime: str | None = None
    session: str | None = None
    sweep_grade: str | None = None
    htf_ob_aligned: bool | None = None
    weight_version: str | None = "v2.11-baseline"
    confidence_at_signal: float | None = None
    received_at: datetime | None = field(default_factory=lambda: datetime.now(timezone.utc))


@pytest.fixture
def make_outcome():
    """Factory fixture -- e.g. make_outcome(outcome="win", realized_r=1.5)."""
    def _make(**kwargs) -> FakeOutcome:
        return FakeOutcome(**kwargs)
    return _make
