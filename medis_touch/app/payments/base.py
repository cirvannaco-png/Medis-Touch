"""
PaymentProvider abstract interface.

Handbook section 10. Environment-based provider selection, never commit
credentials (section 22 repeats this as a hard security rule).
"""

from __future__ import annotations

import abc
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class CheckoutRequest:
    user_id: str
    plan: str
    amount_minor_units: int  # e.g. cents — never use floats for money
    currency: str
    idempotency_key: str
    return_url: str | None = None


@dataclass(frozen=True)
class CheckoutResult:
    provider_payment_id: str
    checkout_url: str
    raw: dict[str, Any]


@dataclass(frozen=True)
class NormalizedPaymentEvent:
    """What every provider's webhook gets normalized into, regardless of
    the wildly different wire formats providers actually use."""

    provider: str
    provider_payment_id: str
    user_id: str
    status: str  # "succeeded" | "failed" | "pending" | "refunded"
    amount_minor_units: int
    currency: str
    plan: str | None
    raw: dict[str, Any]


class WebhookVerificationError(Exception):
    """Raised when a webhook's signature does not verify. Callers MUST
    reject the request (typically HTTP 400/401) and MUST NOT proceed to
    normalize_event() or mutate any state on a failed verification."""


class PaymentProvider(abc.ABC):
    name: str

    @abc.abstractmethod
    def create_checkout(self, request: CheckoutRequest) -> CheckoutResult:
        raise NotImplementedError

    @abc.abstractmethod
    def verify_webhook(self, headers: dict[str, str], raw_body: bytes) -> dict[str, Any]:
        """Verify signature/authenticity and return the parsed payload.

        Must raise WebhookVerificationError on any failure — wrong
        signature, missing header, expired timestamp, whatever the
        provider's scheme requires. Never return a "best guess" parsed
        body from an unverified request.
        """
        raise NotImplementedError

    @abc.abstractmethod
    def normalize_event(self, verified_payload: dict[str, Any]) -> NormalizedPaymentEvent:
        raise NotImplementedError

    @abc.abstractmethod
    def lookup_payment(self, provider_payment_id: str) -> dict[str, Any]:
        """Server-to-server status check, used for reconciliation and
        for confirming a webhook against source-of-truth state rather
        than trusting the webhook body alone for high-value events."""
        raise NotImplementedError
