# Medis Touch v3 — Copy Trading + Payment Pipeline

## Canonical flow

`Signal -> lifecycle validity -> entitlement -> copy event -> subscriber EA -> broker -> acknowledgement`

Payment never directly opens a trade. Payment creates/extends a subscription; the subscription creates an entitlement; the entitlement permits Telegram/signal/copy access.

## Payment initialization

Set these Render environment variables:

- `PAYMENT_WEBHOOK_SECRET` — HMAC-SHA256 secret shared with the payment provider adapter.
- `DEFAULT_PLAN_PRICE` — display price used by `/subscribe`.
- `DEFAULT_CURRENCY=KES`
- `DEFAULT_PLAN_DAYS=30`
- Optional per-plan overrides: `PLAN_MONTHLY_PRICE`, `PLAN_MONTHLY_DAYS`, etc.
- `GROUP_CHAT_ID` — Telegram group/supergroup ID if membership enforcement is enabled by the deployment layer.

The provider callback is:

`POST /commerce/payment/webhook`

Header: `X-Payment-Signature: hex(HMAC-SHA256(raw_request_body, PAYMENT_WEBHOOK_SECRET))`

A successful `paid` callback atomically creates/updates `Payment`, `Subscription`, and `Entitlement`.

## Copy account

Register an MT5 subscriber account with:

`POST /commerce/account`

The account must already have an active copy-trading entitlement.

The subscriber EA then polls:

`GET /commerce/poll/{account_id}`

and acknowledges execution with:

`POST /commerce/ack`

The polling contract is intentionally pull-based. It is resilient to Telegram delays and Render restarts.

## Adaptive signal validity

Only signals satisfying all of these are returned to the copy EA:

- delivery status is `active`
- lifecycle status is `valid`
- `expires_at` is absent or in the future
- subscriber entitlement is active
- `copy_trading=true`
- account `copy_enabled=true`

A stale/expired/invalidated signal therefore disappears from the copy queue instead of remaining actionable.

The existing EA lifecycle publisher already sends `stale`, `expired`, and `invalidated` transitions; the bridge edits the Telegram message rather than treating the original post as permanently valid.

## Strategy setup contract

SMC remains the baseline. When the strategy selector chooses a challenger, the selected strategy must itself manufacture the complete normalized `TradeSetup`:

- entry zone
- invalidation
- stop loss
- TP1
- TP2
- final target
- strategy identity
- setup confidence
- invalidation rationale

Risk, portfolio, execution, recovery, outcome and calibration remain common downstream layers.

## Subscriber EA

`EA/MedisTouch_CopyTrader.mq5` is a separate EA for subscriber accounts. It polls the entitlement-gated queue and sizes orders from the subscriber's own equity when `risk_mode=percent`.

It does not trust Telegram text as an execution source.

## Safety rules

- No payment callback without a valid HMAC signature.
- No copy event without an active entitlement.
- No execution of stale/expired/invalidated signals.
- No fallback from a selected strategy to SMC when the selected strategy cannot build a valid setup.
- Subscriber broker minimum lot can cause an event to be skipped rather than silently exceeding the requested percentage risk.
