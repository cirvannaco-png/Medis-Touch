"""
Smart Glocal payment provider adapter.

Built against Smart Glocal's published API docs (developer.smart-glocal.com):
  - Auth: every request carries X-PARTNER-PROJECT and X-PARTNER-SIGN
    headers; signatures are RSA, and Smart Glocal verifies your outbound
    requests with your public key while you verify their inbound
    webhooks with THEIR public key.
  - Flow: session/create (or session/init/payment) -> session/start/payment
    -> wait for `ready_to_confirm` webhook -> session/confirm or
    session/cancel -> wait for `payment_finished` webhook.
  - Other webhook types you'll see: `action_required` (e.g. 3DS or a
    local-method redirect), `payment_refunded`.
  - Idempotency: Smart Glocal supports an idempotency key on requests
    (see their "API interaction" docs) — pass CheckoutRequest.idempotency_key
    through as that header/field.

WHAT I VERIFIED vs. WHAT'S AN ASSUMPTION, explicitly:
  VERIFIED (from their docs): header names, RSA + SHA-256, webhook
  event type names and rough payload shape (session.id, status,
  acquiring_payments[].status, customer.reference, metadata).
  ASSUMED / NOT VERIFIED: exact canonicalization of the request body
  before signing (e.g. whether it's the raw JSON bytes as sent, or a
  normalized form), and the exact padding scheme (PKCS1v15 vs PSS).
  The implementation below signs/verifies over the raw JSON bytes with
  RSA-PKCS1v15/SHA-256, which is the most common convention for this
  kind of "X-PARTNER-SIGN" header — but CONFIRM THIS AGAINST YOUR SMART
  GLOCAL SANDBOX before trusting it with real payments. A signature
  scheme that "looks right" but silently never verifies fails safe
  (nothing goes through); a signature scheme that's subtly wrong in the
  other direction (accepts unsigned/forged requests) does not fail
  safe. Test the sandbox reject case, not just the accept case.
"""

from __future__ import annotations

import base64
import json
from typing import Any

import httpx
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

from .base import (
    CheckoutRequest,
    CheckoutResult,
    NormalizedPaymentEvent,
    PaymentProvider,
    WebhookVerificationError,
)

_TERMINAL_STATUS_MAP = {
    "succeeded": "succeeded",
    "failed": "failed",
    "declined": "failed",
    "refunded": "refunded",
}

# Per the module docstring's documented webhook types: only these two
# represent a settled outcome. `ready_to_confirm` means the flow is
# mid-way (waiting on your session/confirm call) and `action_required`
# means the customer still has a step to complete (3DS, redirect). Prior
# to this fix, normalize_event() read `event_type` and then ignored it,
# so an intermediate `ready_to_confirm` webhook could be interpreted the
# same as a terminal `payment_finished` one if the nested payment status
# happened to already read "succeeded" mid-flow.
_TERMINAL_EVENT_TYPES = {"payment_finished", "payment_refunded"}


class SmartGlocalProvider(PaymentProvider):
    name = "smart_glocal"

    def __init__(
        self,
        *,
        project_name: str,
        private_key_pem: bytes,  # yours, for signing outbound requests
        smart_glocal_public_key_pem: bytes,  # theirs, for verifying inbound webhooks
        base_url: str = "https://api.smart-glocal.com/api/v1",
        http_client: httpx.Client | None = None,
    ) -> None:
        self._project_name = project_name
        self._private_key = serialization.load_pem_private_key(private_key_pem, password=None)
        self._their_public_key = serialization.load_pem_public_key(smart_glocal_public_key_pem)
        self._base_url = base_url.rstrip("/")
        self._client = http_client or httpx.Client(timeout=10.0)

    def _sign(self, body_bytes: bytes) -> str:
        signature = self._private_key.sign(body_bytes, padding.PKCS1v15(), hashes.SHA256())
        return base64.b64encode(signature).decode("ascii")

    def _post(self, path: str, body: dict[str, Any]) -> dict[str, Any]:
        body_bytes = json.dumps(body, separators=(",", ":")).encode("utf-8")
        headers = {
            "Content-Type": "application/json",
            "X-PARTNER-PROJECT": self._project_name,
            "X-PARTNER-SIGN": self._sign(body_bytes),
        }
        resp = self._client.post(f"{self._base_url}/{path}", content=body_bytes, headers=headers)
        resp.raise_for_status()
        return resp.json()

    def create_checkout(self, request: CheckoutRequest) -> CheckoutResult:
        payload = {
            "session": {
                "amount_details": {
                    "amount": request.amount_minor_units,
                    "currency": request.currency.lower(),
                },
                "customer": {"reference": request.user_id},
                "metadata": json.dumps({"plan": request.plan, "user_id": request.user_id}),
                "payment_options": {"return_url": request.return_url},
            },
            "idempotency_key": request.idempotency_key,
        }
        result = self._post("session/init/payment", payload)
        session = result.get("session", {})
        return CheckoutResult(
            provider_payment_id=session.get("id", ""),
            checkout_url=session.get("actions", {}).get("redirect_url", ""),
            raw=result,
        )

    def verify_webhook(self, headers: dict[str, str], raw_body: bytes) -> dict[str, Any]:
        signature_b64 = headers.get("X-PARTNER-SIGN") or headers.get("x-partner-sign")
        if not signature_b64:
            raise WebhookVerificationError("missing X-PARTNER-SIGN header")

        try:
            signature = base64.b64decode(signature_b64)
            self._their_public_key.verify(
                signature, raw_body, padding.PKCS1v15(), hashes.SHA256()
            )
        except (InvalidSignature, ValueError) as exc:
            raise WebhookVerificationError(f"signature verification failed: {exc}") from exc

        try:
            return json.loads(raw_body)
        except json.JSONDecodeError as exc:
            raise WebhookVerificationError(f"invalid JSON body: {exc}") from exc

    def normalize_event(self, verified_payload: dict[str, Any]) -> NormalizedPaymentEvent:
        event_type = verified_payload.get("type")
        session = verified_payload.get("session", {})
        payments = session.get("acquiring_payments") or session.get("payments") or []
        payment = payments[0] if payments else {}

        metadata_raw = payment.get("metadata") or session.get("metadata") or "{}"
        try:
            metadata = json.loads(metadata_raw) if isinstance(metadata_raw, str) else metadata_raw
        except json.JSONDecodeError:
            metadata = {}

        # Only a terminal event type is allowed to report a terminal
        # status. `ready_to_confirm` / `action_required` webhooks are
        # always normalized to "pending" regardless of what the nested
        # payment.status field happens to say — the flow isn't done
        # until Smart Glocal sends payment_finished (or payment_refunded
        # for a later refund), and process_payment_webhook() only
        # grants a subscription/entitlement on status == "succeeded".
        if event_type in _TERMINAL_EVENT_TYPES:
            status = _TERMINAL_STATUS_MAP.get(payment.get("status", ""), "pending")
        else:
            status = "pending"
        amount_details = payment.get("amount_details", {})

        return NormalizedPaymentEvent(
            provider=self.name,
            provider_payment_id=payment.get("id") or session.get("id", ""),
            user_id=metadata.get("user_id")
            or payment.get("customer", {}).get("reference", ""),
            status=status,
            amount_minor_units=int(amount_details.get("amount", 0)),
            currency=str(amount_details.get("currency", "")).upper(),
            plan=metadata.get("plan"),
            raw=verified_payload,
        )

    def lookup_payment(self, provider_payment_id: str) -> dict[str, Any]:
        return self._post("session/status", {"session_id": provider_payment_id})
