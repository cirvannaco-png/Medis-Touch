"""
Idempotent payment -> subscription -> entitlement pipeline, and automatic
expiry/revocation.

Handbook sections 11-12. This is a direct, executable translation of the
pseudocode with the two required uniqueness constraints, a real
transaction boundary, and the webhook-signature verification made
mandatory (the pseudocode implied it via `provider.verify_and_normalize`;
here it's split into the two explicit PaymentProvider calls so a caller
can't accidentally skip verify_webhook()).

DB LAYER: written against a minimal Session/Repository protocol so this
file doesn't hard-depend on SQLAlchemy specifics you haven't shown me.
Adapt `Db` below to your actual `app/database.py` session factory —
the shape (a context-managed transaction + a handful of
upsert/lookup calls) should map directly onto SQLAlchemy.
"""

from __future__ import annotations

from contextlib import AbstractContextManager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Protocol

from .copy_trading import (
    Entitlement,
    EntitlementStatus,
    Subscription,
    SubscriptionStatus,
)
from .payments.base import NormalizedPaymentEvent, PaymentProvider


@dataclass
class Payment:
    payment_id: str
    provider: str
    provider_payment_id: str
    user_id: str
    status: str
    amount_minor_units: int
    currency: str


class Db(Protocol):
    def transaction(self) -> AbstractContextManager[None]: ...

    def payment_by_provider_reference(
        self, provider: str, provider_payment_id: str
    ) -> Payment | None: ...

    def create_payment(self, event: NormalizedPaymentEvent) -> Payment: ...

    def upsert_subscription(
        self,
        *,
        user_id: str,
        provider: str,
        provider_reference: str,
        status: SubscriptionStatus,
        expires_at: datetime | None,
        plan: str | None,
    ) -> Subscription: ...

    def upsert_entitlement(
        self,
        *,
        user_id: str,
        subscription_id: str,
        status: EntitlementStatus,
        copy_trading: bool,
        valid_until: datetime | None,
    ) -> Entitlement: ...


# --- Required database uniqueness (section 11) ---------------------------
#
# These are constraints your migration must add — this module can't
# create them, only depend on them being there:
#
#   UNIQUE(provider, provider_payment_id)   -- on payments
#   UNIQUE(idempotency_key)                 -- wherever you key copy events
#
# Without the DB-level UNIQUE constraint, the `existing = ...; if
# existing: return existing` check below is a check-then-act race under
# concurrent webhook delivery (providers do retry webhooks, sometimes
# concurrently). The Python-level check is a fast path / clarity aid;
# the DB constraint is what actually prevents a duplicate row, and your
# create_payment() should be prepared to catch a unique-violation and
# treat it the same as "existing found" rather than raising.


DEFAULT_SUBSCRIPTION_PERIOD = timedelta(days=30)


def calculate_expiry(event: NormalizedPaymentEvent, *, period: timedelta = DEFAULT_SUBSCRIPTION_PERIOD) -> datetime:
    # MUST be tz-aware. Everything downstream that compares expires_at
    # (can_copy(), revoke_expired()) uses datetime.now(timezone.utc).
    # datetime.utcnow() returns a *naive* datetime that looks correct
    # until the first comparison against an aware one, at which point
    # Python raises TypeError instead of just being wrong quietly. Fail
    # loud in dev, not in prod at 2am.
    return datetime.now(timezone.utc) + period


def map_payment_status(event: NormalizedPaymentEvent) -> SubscriptionStatus:
    if event.status == "succeeded":
        return SubscriptionStatus.ACTIVE
    if event.status == "refunded":
        return SubscriptionStatus.CANCELLED
    if event.status == "failed":
        return SubscriptionStatus.PAST_DUE
    return SubscriptionStatus.PAST_DUE


def process_payment_webhook(
    *,
    provider: PaymentProvider,
    headers: dict[str, str],
    raw_body: bytes,
    db: Db,
) -> Payment:
    """WEBHOOK -> VERIFY SIGNATURE -> NORMALIZE EVENT -> IDEMPOTENCY CHECK
    -> UPSERT PAYMENT -> UPSERT SUBSCRIPTION -> UPSERT ENTITLEMENT -> COMMIT

    Raises WebhookVerificationError (from provider.verify_webhook) if the
    signature doesn't check out — the caller (your FastAPI route) should
    map that to a 400/401 and MUST NOT call this function's body past
    that point. That mapping is intentionally not caught here so a bug
    can't silently swallow a verification failure into a 200 OK.
    """
    verified_payload = provider.verify_webhook(headers, raw_body)
    event = provider.normalize_event(verified_payload)

    with db.transaction():
        existing = db.payment_by_provider_reference(event.provider, event.provider_payment_id)
        if existing:
            return existing

        payment = db.create_payment(event)

        if event.status == "succeeded":
            subscription = db.upsert_subscription(
                user_id=event.user_id,
                provider=event.provider,
                provider_reference=event.provider_payment_id,
                status=map_payment_status(event),
                expires_at=calculate_expiry(event),
                plan=event.plan,
            )
            db.upsert_entitlement(
                user_id=event.user_id,
                subscription_id=subscription.subscription_id,
                status=EntitlementStatus.ACTIVE
                if subscription.status == SubscriptionStatus.ACTIVE
                else EntitlementStatus.INACTIVE,
                copy_trading=subscription.status == SubscriptionStatus.ACTIVE,
                valid_until=subscription.expires_at,
            )
        # else: failed/pending/refunded payments still get a Payment row
        # for audit, but deliberately do NOT touch subscription/entitlement
        # here — a failed payment must never grant access, and a refund
        # should go through its own explicit revocation path (below)
        # rather than being inferred from payment status alone.

        return payment


# --- Automatic expiry / revocation (section 12) ---------------------------


def revoke_expired(subscription: Subscription, entitlement: Entitlement, now: datetime) -> bool:
    """Returns True if this call changed anything (so the caller knows
    whether to persist + fan out the Telegram-access revocation).

    Call this from a scheduled job AND at request time (the handbook is
    explicit: "Request-time enforcement repeats expiry/entitlement
    checks on every copy poll and execution attempt" — don't rely on the
    scheduled sweep alone, since a subscription can expire mid-window
    before the next sweep runs).
    """
    changed = False
    if subscription.status == SubscriptionStatus.ACTIVE and subscription.expires_at and subscription.expires_at <= now:
        subscription.status = SubscriptionStatus.EXPIRED
        changed = True
    if subscription.status != SubscriptionStatus.ACTIVE and entitlement.status == EntitlementStatus.ACTIVE:
        entitlement.status = EntitlementStatus.INACTIVE
        entitlement.copy_trading = False
        entitlement.telegram_access = False
        changed = True
    return changed
