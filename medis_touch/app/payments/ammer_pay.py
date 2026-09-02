"""
Ammer Pay payment provider adapter.

IMPORTANT — CONFIDENCE LEVEL ON THIS FILE IS LOWER THAN smart_glocal.py.

What I could confirm publicly: Ammer Pay is a Swiss-licensed
non-custodial CRYPTO payment processor (BTC/ETH/USDT/etc, invoices +
POS + Telegram shop integration), with a documented Telegram-bot
checkout flow via their Merchant Hub / BotFather integration. I could
NOT find their raw server-to-server REST API reference (request/response
shapes, webhook payload schema, or signature scheme) in what's publicly
indexed — their integration docs I found are focused on the Telegram
Bot Payments flow, not a general HTTP API.

Two consequences for you:

1. If you're actually using Ammer Pay through Telegram's native Bot
   Payments API (Telegram handles the checkout UI and sends YOU a
   `successful_payment` update via the Bot API, with Ammer Pay as the
   configured provider token) — this is a DIFFERENT integration shape
   than "your server calls Ammer Pay's REST API directly". In that
   case this file's create_checkout()/verify_webhook() split doesn't
   apply; you'd instead validate the `successful_payment` message
   inside your Telegram bot's update handler, and there's no separate
   webhook signature to verify because Telegram Bot API transport (HTTPS
   + your bot token in the URL path) is the trust boundary. Check
   ammer-tech.github.io/AmmerPayBotDocumentation and your BotFather
   payment provider setup to confirm which mode you're in before using
   this file at all.

2. If you DO have a direct merchant REST API integration (via their
   Merchant Platform, separate from Telegram Bot Payments), the
   scaffolding below is structurally correct (matches the
   PaymentProvider contract) but the endpoint paths, payload field
   names, and signature header/algorithm are PLACEHOLDERS marked
   TODO — pull them from your Ammer Pay merchant dashboard's API
   reference (usually under API keys / webhooks settings) and replace
   before this touches real payments. Do not deploy this file as-is.
"""

from __future__ import annotations

import hashlib
import hmac
import json
from typing import Any

import httpx

from .base import (
    CheckoutRequest,
    CheckoutResult,
    NormalizedPaymentEvent,
    PaymentProvider,
    WebhookVerificationError,
)


class AmmerPayProvider(PaymentProvider):
    name = "ammer_pay"

    def __init__(
        self,
        *,
        merchant_api_key: str,
        webhook_secret: str,  # TODO: confirm this is HMAC and get the real shared secret
        base_url: str = "https://api.ammer.io/v1",  # TODO: confirm real base URL
        http_client: httpx.Client | None = None,
    ) -> None:
        self._api_key = merchant_api_key
        self._webhook_secret = webhook_secret.encode("utf-8")
        self._base_url = base_url.rstrip("/")
        self._client = http_client or httpx.Client(timeout=10.0)

    def create_checkout(self, request: CheckoutRequest) -> CheckoutResult:
        # TODO: replace with the real invoice-creation endpoint/schema
        # from your Ammer Pay merchant dashboard docs. Crypto invoices
        # commonly need the fiat amount PLUS a settlement currency /
        # accepted-token list — that's not modeled in the generic
        # CheckoutRequest, so you'll likely need Ammer-specific fields.
        payload = {
            "amount": request.amount_minor_units,
            "currency": request.currency,
            "reference": request.idempotency_key,
            "metadata": {"user_id": request.user_id, "plan": request.plan},
            "return_url": request.return_url,
        }
        headers = {"Authorization": f"Bearer {self._api_key}"}
        resp = self._client.post(f"{self._base_url}/invoices", json=payload, headers=headers)
        resp.raise_for_status()
        data = resp.json()
        return CheckoutResult(
            provider_payment_id=data.get("id", ""),
            checkout_url=data.get("payment_url", ""),
            raw=data,
        )

    def verify_webhook(self, headers: dict[str, str], raw_body: bytes) -> dict[str, Any]:
        # TODO: confirm the actual signature header name and algorithm
        # from Ammer Pay's merchant docs. This assumes a common
        # HMAC-SHA256-over-raw-body scheme as a starting point — DO NOT
        # trust this in production until verified against their sandbox,
        # the same way smart_glocal.py's RSA scheme needs sandbox
        # confirmation. An unverifiable assumption here is worse than in
        # smart_glocal.py because I have no primary-source confirmation
        # at all for this provider's webhook scheme.
        signature = headers.get("X-Ammer-Signature") or headers.get("x-ammer-signature")
        if not signature:
            raise WebhookVerificationError("missing signature header (name unconfirmed — check docs)")

        expected = hmac.new(self._webhook_secret, raw_body, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature, expected):
            raise WebhookVerificationError("signature mismatch")

        try:
            return json.loads(raw_body)
        except json.JSONDecodeError as exc:
            raise WebhookVerificationError(f"invalid JSON body: {exc}") from exc

    def normalize_event(self, verified_payload: dict[str, Any]) -> NormalizedPaymentEvent:
        # TODO: field names are placeholders — align to the real payload
        # once you have the actual webhook schema.
        metadata = verified_payload.get("metadata", {})
        return NormalizedPaymentEvent(
            provider=self.name,
            provider_payment_id=verified_payload.get("id", ""),
            user_id=metadata.get("user_id", ""),
            status=verified_payload.get("status", "pending"),
            amount_minor_units=int(verified_payload.get("amount", 0)),
            currency=str(verified_payload.get("currency", "")).upper(),
            plan=metadata.get("plan"),
            raw=verified_payload,
        )

    def lookup_payment(self, provider_payment_id: str) -> dict[str, Any]:
        headers = {"Authorization": f"Bearer {self._api_key}"}
        resp = self._client.get(f"{self._base_url}/invoices/{provider_payment_id}", headers=headers)
        resp.raise_for_status()
        return resp.json()
