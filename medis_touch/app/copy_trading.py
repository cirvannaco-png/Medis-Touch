"""
Copy-trading schema and authorization gate.

Handbook sections 8-9. Security rule, verbatim (section 22): "Never
trust Telegram button presence as authorization. Re-check copy
authorization immediately before execution." This module implements
that as two call sites: `can_copy()` for the polling query filter, and
`authorize_and_claim()` which re-runs the exact same check inside the
DB transaction that claims the copy event, immediately before an order
is sent to the broker.

Table shapes below are dataclasses standing in for whatever ORM you're
using (SQLAlchemy per telegram-bridge/app/database.py). Port the field
lists directly into your models — they're taken verbatim from the
handbook's schema section.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from enum import Enum


class CopyEventStatus(str, Enum):
    PENDING = "PENDING"
    CLAIMED = "CLAIMED"
    EXECUTED = "EXECUTED"
    REJECTED = "REJECTED"
    SKIPPED = "SKIPPED"
    ERROR = "ERROR"


class SubscriptionStatus(str, Enum):
    ACTIVE = "ACTIVE"
    EXPIRED = "EXPIRED"
    CANCELLED = "CANCELLED"
    PAST_DUE = "PAST_DUE"


class EntitlementStatus(str, Enum):
    ACTIVE = "ACTIVE"
    INACTIVE = "INACTIVE"


@dataclass
class CopyAccount:
    account_id: str
    user_id: str
    broker: str
    broker_account_reference: str
    enabled: bool
    risk_mode: str  # e.g. "fixed_lot" | "percent_equity" | "fixed_risk_amount"
    risk_value: float


@dataclass
class Subscription:
    subscription_id: str
    user_id: str
    plan: str
    provider: str  # "ammer_pay" | "smart_glocal"
    provider_reference: str
    status: SubscriptionStatus
    started_at: datetime
    expires_at: datetime | None


@dataclass
class Entitlement:
    entitlement_id: str
    user_id: str
    subscription_id: str
    status: EntitlementStatus
    copy_trading: bool
    signal_access: bool
    telegram_access: bool
    valid_from: datetime
    valid_until: datetime | None


@dataclass
class CopyTradeEvent:
    copy_id: str
    signal_id: str
    user_id: str
    account_id: str
    status: CopyEventStatus
    idempotency_key: str
    created_at: datetime
    broker_ticket: str | None = None
    claimed_at: datetime | None = None
    executed_at: datetime | None = None
    error: str | None = None


# --- The gate ------------------------------------------------------------
#
# Minimal duck-typed protocol so this stays independent of your ORM.
# `signal` here is app.models.Signal, kept loosely typed to avoid an
# import cycle with whatever persistence layer wraps it.


def can_copy(
    subscription: Subscription,
    entitlement: Entitlement,
    account: CopyAccount,
    signal,  # app.models.Signal
    now: datetime,
) -> bool:
    """Direct translation of handbook section 8's `can_copy`.

    ALL seven conditions must hold. Do not shortcut this with an ORM
    query that only checks some of them "because the others are usually
    true" — that's exactly how a stale entitlement or a disabled
    account ends up executing a trade.
    """
    from .models import SignalStatus  # local import avoids cycle

    return (
        subscription.status == SubscriptionStatus.ACTIVE
        and subscription.expires_at is not None
        and subscription.expires_at > now
        and entitlement.status == EntitlementStatus.ACTIVE
        and entitlement.copy_trading is True
        and account.enabled is True
        and signal.status == SignalStatus.ACTIVE
        and signal.invalidated_at is None
        and (signal.expires_at is None or signal.expires_at > now)
    )


# --- Copy polling contract -------------------------------------------------
#
# The SQL filter equivalent, for wherever you build the polling query
# (handbook section 9). Keep this string in sync with can_copy() above
# by hand — there is no automatic way to guarantee an ORM query and a
# Python predicate stay identical, so if you change one, change both
# and add a test that exercises both paths against the same fixture.

COPY_POLLING_WHERE_CLAUSE = """
WHERE subscription.status = 'ACTIVE'
  AND subscription.expires_at > NOW()
  AND entitlement.status = 'ACTIVE'
  AND entitlement.copy_trading = TRUE
  AND account.enabled = TRUE
  AND signal.status = 'ACTIVE'
  AND signal.invalidated_at IS NULL
  AND (signal.expires_at IS NULL OR signal.expires_at > NOW())
"""


class AuthorizationError(Exception):
    """Raised when a claim attempt fails the immediate-pre-execution
    re-check. The caller must treat this as a hard stop, never a retry
    with relaxed conditions."""


def authorize_and_claim(
    *,
    subscription: Subscription,
    entitlement: Entitlement,
    account: CopyAccount,
    signal,
    copy_event: CopyTradeEvent,
    now: datetime,
) -> CopyTradeEvent:
    """Re-run can_copy() *inside* the transaction that claims the copy
    event, immediately before the order is sent to the broker.

    This is the second of the two mandatory checks (section 9: "Perform
    the authorization check again immediately before execution. A stale
    Telegram button or cached poll must never authorize a trade.").

    Caller is responsible for wrapping this in a DB transaction with a
    row lock (SELECT ... FOR UPDATE on the copy_event row, or an
    UPDATE ... WHERE status = 'PENDING' compare-and-swap) so two workers
    can't both claim the same event — that's a concurrency concern this
    pure function can't enforce on its own.
    """
    if not can_copy(subscription, entitlement, account, signal, now):
        copy_event.status = CopyEventStatus.REJECTED
        copy_event.error = "authorization_failed_at_claim_time"
        raise AuthorizationError(
            f"copy_id={copy_event.copy_id} failed re-authorization at claim time"
        )

    copy_event.status = CopyEventStatus.CLAIMED
    copy_event.claimed_at = now
    return copy_event
