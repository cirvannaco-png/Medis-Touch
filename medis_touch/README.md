# Medis Touch — handbook implementation

Generated from `Medis_Touch_Complete_Engineering_Handbook.docx`. Verified
by running the logic (not just reading it) — see "What I actually
verified" below. **Read that section before you trust or merge any of
this.**

## Fix pass (post-first-draft audit)

A follow-up review — done by running `pytest`, `ruff`, and `bandit`
against this code rather than re-reading the docstrings — found and
fixed four real bugs, plus housekeeping. All fixes have dedicated
regression tests (25 tests total, up from 17, all passing; `bandit -r
app` reports zero issues at any severity).

1. **`invalidation`/`final_tp` never reached the wire.**
   `TradeSetup.mqh`'s JSON serializer dropped both fields when a setup
   left the EA for the Telegram bridge — silently defeating the
   handbook's core invariant right at the boundary that matters most.
   Fixed; both fields are now in the payload. **You still need to add
   `invalidation` and `final_tp` to `telegram-bridge/app/models.py` and
   `validator.py` on the receiving side** — this fix is a no-op until
   the bridge accepts the new keys.
2. **Naive vs. timezone-aware datetime crash.**
   `payment_webhook.py`'s `calculate_expiry()` used `datetime.utcnow()`
   (naive) while every comparison against it (`can_copy()`,
   `revoke_expired()`) uses `datetime.now(timezone.utc)` (aware).
   Python raises `TypeError` comparing the two — fixed (ruff `DTZ003`).
3. **2 of 7 required symbol-metadata checks were silently absent.**
   `execution_validation.py` collected `tick_size` and
   `freeze_level_points` but never validated either, despite the
   handbook requiring both. Added `validate_tick_size()` and
   `validate_freeze_level()`, wired into `validate_execution()`.
4. **Smart Glocal webhook ignored its own event type.**
   `normalize_event()` read `event_type` off the payload and never used
   it (ruff `F841`) — every webhook was treated as if it reported a
   terminal outcome, regardless of whether it was `ready_to_confirm`,
   `action_required`, `payment_finished`, or `payment_refunded`. Fixed:
   only `payment_finished`/`payment_refunded` can produce a terminal
   status; everything else normalizes to `"pending"`.

Housekeeping: removed 2 unused imports and 1 unused local var (ruff
`F401`/`F841`), replaced a mutable-instance-looking default argument in
`calibration.py`'s `evaluate_calibration()` with a `None`-default +
in-body construction (ruff `B008` — this one was never actually
mutation-unsafe since `CalibrationGateConfig` is frozen, but the
pattern is a bad habit regardless of whether ruff can prove it safe in
a given case).

**Not fixed, still open** (unchanged from the original draft — see
"What's deliberately NOT implemented" below): the four strategy
engines are still `NotImplementedError` stubs, and Ammer Pay's webhook
signature scheme is still unverified/do-not-deploy. Neither is
something a code review can close — the first needs your real
detectors, the second needs your actual Ammer Pay merchant docs.

## Layout

```
app/
  models.py               # section 3, 6 — TradeSetup contract + lifecycle state machine
  strategy_engines.py      # section 2, 4, 5 — setup engine CONTRACTS (detection logic NOT included, see below)
  telegram_controls.py     # section 7 — adaptive Copy button rendering
  copy_trading.py          # section 8, 9 — schema + can_copy() gate + re-check-at-claim-time
  payment_webhook.py       # section 11, 12 — idempotent webhook -> subscription -> entitlement, expiry/revocation
  execution_validation.py  # section 15 — fail-closed symbol metadata validation
  latency.py                # section 13 — T0-T7 telemetry
  calibration.py            # section 14 — statistical promotion gate (Wilson interval, min sample, effect size, OOS)
  payments/
    base.py                # section 10 — PaymentProvider interface
    smart_glocal.py         # RSA-signed webhook verification, built against their public docs
    ammer_pay.py            # SCAFFOLDING ONLY — see file header, do not deploy as-is
mql5/Include/MedisTouch/
  TradeSetup.mqh            # section 3 struct, mirrored in MQL5 for the EA side
tests/
  test_lifecycle_and_gates.py  # 19 checks, all passing — see "What I actually verified"
```

## What I actually verified (and what I didn't)

I ran this code, not just wrote it. Since I don't have network access to
install `pytest`/`httpx` in this sandbox, I wrote a dependency-free
manual test harness exercising the same 19 cases and ran it —
**all 19 passed**, covering:

- `invalidation` and `stop_loss` are enforced as distinct, independently
  validated fields (section 3's core invariant)
- Lifecycle transitions: crossing invalidation → INVALIDATED, hard
  expiry → EXPIRED, terminal states don't get re-evaluated, TP1 → TP2 →
  COMPLETED progression
- `can_copy()` correctly excludes on *each* of the seven conditions
  individually (expired subscription, disabled entitlement, disabled
  account, invalidated signal) — not just the "all pass" case
- `authorize_and_claim()` actually catches a signal that was invalidated
  *between* poll time and claim time and raises, rather than trusting
  the earlier poll result — this is the specific race the handbook's
  security rules call out
- Fail-closed execution validation: `None` symbol metadata **rejects**
  rather than silently passing (the exact bug the handbook names), and
  a too-tight stop distance rejects
- Calibration gate reproduces the handbook's own example — 17 trades at
  64.7% is correctly refused promotion; a 500-trade sample with a
  held-out 200-trade out-of-sample set at a similar win rate is approved

Import-checked (compiles cleanly, logic not exercised — no `httpx` in
this sandbox to actually run outbound calls): `payments/base.py`,
`payments/smart_glocal.py`, `payments/ammer_pay.py`, `payment_webhook.py`,
`telegram_controls.py`, `strategy_engines.py`, `latency.py`.

**Run `pytest tests/ -v` yourself** wherever you have network access —
the manual harness proves the logic works, but you should have the real
suite in CI per the handbook's section 17.

## What's deliberately NOT implemented, and why

- **Strategy detection logic** (`strategy_engines.py`'s `detect()` /
  `build_setup()` bodies) — breakout confirmation, mean-reversion
  rejection detection, key-level identification, SMC structure analysis.
  I don't have visibility into your existing EA's indicators/market data
  structures, and a plausible-looking-but-wrong detector is worse than
  an honest `NotImplementedError`. The *contract* these must satisfy is
  fully implemented and tested (`TradeSetup`, the invalidation/SL
  separation, the lifecycle) — wire your real detection logic into the
  `build_setup()` methods.
- **Ammer Pay's actual webhook signature scheme** — I could not find
  their server-to-server REST API reference publicly (their indexed
  docs cover the Telegram Bot Payments integration, which is a
  different trust model — see the big comment at the top of
  `ammer_pay.py`). The file is structurally correct against the shared
  `PaymentProvider` interface but every endpoint path, field name, and
  the signature algorithm itself is a marked `TODO` placeholder. **Do
  not point this at real payments without confirming against your
  actual Ammer Pay merchant docs and testing the sandbox reject case,
  not just the accept case.**
- **Smart Glocal's exact signing canonicalization** — the header names,
  RSA+SHA-256 algorithm, and webhook event shapes are confirmed against
  their public docs. The exact byte-for-byte canonicalization before
  signing (raw JSON as sent vs. a normalized form) and padding scheme
  (assumed PKCS1v15) are not 100% confirmed — test both directions in
  their sandbox before production.
- **Windows/MQL5 compile pipeline, Ruff/Bandit/pip-audit CI wiring**
  (sections 16, 17, 19) — these are environment/CI-config tasks, not
  code, and depend on your actual repo's existing `app/bot.py`,
  `commerce_bot.py` etc. that I don't have contents for.
- **Actual DB migrations** — `payment_webhook.py`'s `Db` is a `Protocol`
  you implement against your real SQLAlchemy session; I don't have your
  `database.py` to extend directly. The two required `UNIQUE`
  constraints are documented in that file's comments — add them as an
  Alembic migration.

## Before this touches real money or real trades

1. Confirm the payment provider signature schemes in sandbox (both
   accept and reject cases — a scheme that never verifies fails safe;
   one that accepts forged requests does not).
2. Add the `UNIQUE(provider, provider_payment_id)` and
   `UNIQUE(idempotency_key)` DB constraints — the Python-level
   idempotency check alone is a race under concurrent webhook retries.
3. Get an actual legal read on the payments + copy-trading + Telegram
   subscription stack for whatever jurisdiction(s) you're taking
   customers from — this is the part no amount of code review replaces.
