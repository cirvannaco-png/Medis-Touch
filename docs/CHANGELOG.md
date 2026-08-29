# Changelog

## v2.10 — Confidence Engine Upgrade (diagnostic only)

Nothing in this release can change a trading decision. Every number added is
computed, logged, and read by no filter, no confidence value, no lot size and
no order — so the alternative model can be measured against the live one on
real resolved outcomes before it is trusted with money.

### Added
- `SetupReasons.contradiction_penalty` — counts only *actively opposing*
  conditions, so "no HTF read" stops costing the same as "fighting the HTF".
- `SetupReasons.env_score` / `exec_score` / `env_exec_confidence` — the
  multiplicative model: `Confidence x Env x Exec x (1 - Contradiction)`.
  Expresses "unsuitable market" in a way adding points cannot.
- `PendingSetup.confidenceAtSignal` / `confidenceDecayed` / `decayBars` —
  exponential half-life decay applied per **unfilled** bar and frozen at
  fill; a score is only true of the bar that produced it.
- `CScoringEngine::ConfigureLearnedDiagnostics()` and
  `COutcomeTracker::ConfigureConfidenceDecay()`.
- EA input group "Confidence Diagnostics (v2.10)":
  `InpDiagContradictionWeight`, `InpDiagEnvWeight`, `InpDiagExecWeight`,
  `InpDiagDecayHalfLifeBars` — all CSV-only in effect.
- `tools/medistouch_retrain.py` — offline AUC comparison of the additive vs.
  multiplicative vs. decayed score, with per-component correlation against
  realized R. Read-only; refuses a verdict below `--min-sample` trades.

### Changed
- Signals CSV gains `ContradictionPenalty`, `EnvScore`, `ExecScore`,
  `EnvExecConfidence`. Outcomes CSV gains those plus `ConfidenceAtSignal`,
  `ConfidenceDecayed`, `DecayBars`. Columns are **appended**, so
  position-based parsers keep working.

### Unchanged (deliberately)
- `CalculateConfidence()`'s return value, every entry filter, the
  news/session/sweep gates, sizing, and order placement. Promoting the
  multiplicative model is a future, explicit edit to `Analysis/Scoring.mqh`,
  justified by out-of-sample evidence from the script above.


All notable changes to Medis Touch are documented here.  
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Added
- **`telegram-bridge/` — 10 new admin Telegram commands (bridge v1.4.0).**
  `/stats`, `/symbols`, `/status`, `/mute`, `/unmute`, `/muted`, `/pause`,
  `/resume`, `/retry`, `/version`. Backed by a new `bot_settings` key/value
  table (migration `0003_bot_settings_table.py`, `app/settings_store.py`)
  that persists mute/pause state across Render redeploys. `POST /signal`
  now checks this state before contacting Telegram: a muted symbol or a
  global pause suppresses the broadcast but still records the `Signal` row
  (status `ACTIVE`, `telegram_message_id` left null) so `/stats` and win-rate
  history stay accurate. `/retry` reuses the exact same retry logic as the
  `/retry-failed` and `/trade/retry-failed` HTTP endpoints (both refactored
  into `retry_failed_signals_core()` / `retry_failed_trade_events_core()`
  in `app/routes.py` so there's one implementation, not two).

- **`EA/` — MedisTouch v2.8 MQL5 source is now in the repository.**
  `EA/MedisTouch_v2.8.mq5` (Expert Advisor), `EA/MedisTouch_Indicator_v2.8.mq5`
  (visuals-only chart indicator, since MQL5 forbids trading calls from an
  indicator context) and the full engine under `EA/includes/`. Three facade
  headers expose the v2.8 additions at stable include paths:
  `includes/InducementEngine.mqh`, `includes/HTF_OrderBlock.mqh`,
  `includes/VolatilityRegime.mqh`.
- **`Decision/` layer completed.** The tree referenced
  `Decision/DecisionEngine.mqh` and `Decision/TradeDecision.mqh` which did not
  exist, and `Decision/DecisionStore.mqh` was committed empty — the EA could
  not compile at all. Now implemented:
  - `TradeDecision.mqh` — `TradeDecisionRecord`, `ExecutionRecord` and
    `ENUM_TRADE_POLICY` (`IGNORE`/`SIGNAL_ONLY`/`EXECUTE_ONLY`/`EXECUTE_AND_SIGNAL`),
    shared by the router, order manager, publisher and store so all four act on
    one immutable record.
  - `DecisionEngine.mqh` — policy router: confidence thresholds per channel,
    an execution-only spread gate (a wide spread ruins the fill, it does not
    invalidate the analysis, so subscribers still get the signal),
    `reduce_risk` below `InpFullRiskConfidence`, and monotonic decision IDs
    with `SeedNextId()` so a restarted terminal never reissues an ID already
    baked into a broker order comment.
  - `DecisionStore.mqh` — append-only CSV persistence in `MQL5/Files`
    (`MedisTouch_Decisions_<SYMBOL>.csv`, `MedisTouch_Executions_<SYMBOL>.csv`)
    with an in-memory mirror, idempotent saves, and a flush+close per write so
    a decision is durable before the order that follows it can fill. This is
    the half of the state `RecoveryEngine` cannot get from the broker.
- **Root `.gitignore`** covering compiled MQL5 output (`*.ex5`, `*.ex4`),
  Python/pytest/ruff caches, local SQLite files and `.env` (with
  `.env.example` kept).
- **`ea-validate` CI workflow** (`tools/validate_mql5.py`). MetaEditor is
  Windows-only, so CI does a structural check instead of a compile: every
  `#include` must resolve (case-sensitively), no header may be empty, include
  guards must balance, and no compiled binary may be committed.

### Changed
- **`ADMIN_CHAT_ID` split out from `CHAT_ID`.** `CHAT_ID` is now purely the
  outbound broadcast destination (the signal group), while the inbound bot
  accepts commands (`/positions`, `/risk`, ...) only from `ADMIN_CHAT_ID` —
  normally your personal DM. Previously anyone in the signal group could
  query live positions and P/L. `ADMIN_CHAT_ID` is required at startup, the
  same treatment as `BOT_TOKEN`; set it in Render (or `.env`) before
  deploying, and add it as a repository secret for the Render sync workflow.
  The `ADMIN_CHAT_ID` repository secret is configured, so
  `.github/workflows/render-secrets.yml` can push it to Render; the value is
  never committed.


## [1.3.0] — POST /trade, Render blueprint fixes, dependency refresh

### Added
- **`POST /trade`** and **`POST /trade/retry-failed`** — new trade lifecycle
  event endpoint, distinct from `/signal`. A `Signal` is a pre-trade alert
  with no guarantee an order was ever opened; a `TradeEvent` is reported by
  the EA's `OrderManager`/`PositionManager` *after* it actually placed,
  modified, or closed a real order. Backed by a new `trade_events` table
  (migration `0002`) with its own idempotency key (`event_id`, not
  `trade_id` — the same `trade_id` legitimately recurs across
  `opened → partial_close → closed_tp1`). Same PENDING-row-reservation
  pattern as `/signal` to prevent double-sends under concurrent
  WebRequest retries from the EA. See `README.md` for the payload shape.
- `validate_trade_event()` in `validator.py` — lighter than
  `validate_signal()`: SL/TP are optional since close events legitimately
  omit them once the position is flat.

### Fixed
- **Root cause of the recurring Render Blueprint deploy failure** identified
  and documented in `render.yaml`/`Dockerfile`: the container's first
  command (`alembic upgrade head`) imports `app.config`, which raises a
  `pydantic.ValidationError` and exits non-zero if `BOT_TOKEN`/`CHAT_ID`/
  `SECRET_KEY` aren't set — and Blueprint sync creates those slots
  (`sync: false`) without populating them, so a fresh deploy could never
  reach a healthy state without a manual dashboard step. Dockerfile `CMD`
  now checks for this up front and fails with a readable message instead
  of a raw traceback buried in `alembic`'s output.
- Removed non-existent top-level `version:` key from `render.yaml` (not
  part of Render's Blueprint schema — services/databases/envVarGroups/
  projects/ungrouped/previews are the only root keys).
- `env: docker` → `runtime: docker` (the `env` key for specifying the
  runtime is deprecated in Render's current Blueprint spec; still accepted
  today but shouldn't be relied on).
- Removed a factually incorrect comment in `Dockerfile` claiming
  `dockerContext` is "not supported in render.yaml" — it is a valid,
  documented field, and it's exactly what `render.yaml` already relies on
  to make the `COPY telegram-bridge/...` paths resolve.
- Added explicit `healthCheckPath: /` to `render.yaml`.
- `pydantic-settings` bumped `2.1.0` → `2.14.2` and `httpx` bumped
  `0.26.0` → `0.28.1` — both were roughly two years stale relative to the
  `fastapi==0.140.0` pin they shipped alongside, an accident waiting to
  surface as a transitive resolver conflict on some future rebuild.
  `asyncpg` bumped `0.29.0` → `0.31.0` for the same reason.

### Docs
- `README.md`: documented the free-tier Render Postgres 30-day hard expiry
  — it is **not** an inactivity timer, so logging into the dashboard does
  not delay or prevent it (only the free *web service*'s 15-minute
  spin-down is activity-based, and pinging the dashboard doesn't touch
  that either — only real traffic to the service does).
- `README.md`: documented the required manual secrets step in the Render
  deployment section, and added the `/trade` endpoint to the API table
  and payload examples.

---

## [1.2.0] — race-condition fix, packaging, migrations, docs honesty

### Fixed
- **Duplicate-send race closed.** `POST /signal` previously ran the
  Telegram send *before* the DB insert that provides duplicate protection,
  so two concurrent requests for the same `signal_id` could both pass the
  pre-check and both call Telegram - only one row would survive the unique
  constraint, but two messages could already be sent. Now the row is
  inserted as `PENDING` first (reserving `signal_id` via the unique
  constraint) and only the request that wins the insert proceeds to call
  Telegram, so the external call happens at most once per `signal_id`.
- `/retry-failed` now also reclaims signals stuck at `PENDING` for longer
  than `PENDING_STALE_SECONDS` (default 120s) - closes the gap where a
  process crash/restart between reserving `signal_id` and resolving the
  Telegram send left a row with no path back to `ACTIVE`/`FAILED`.
- Root `README.md` no longer claims the MQL5 EA source exists in
  `mql5/Experts/MedisTouch/`. It doesn't yet. Added a `Status` section and
  per-folder placeholder `README.md` files so the directory tree matches
  reality instead of describing a future state as if it were current.

### Fixed (security)
- `fastapi` bumped `0.109.0` → `0.140.0` (pulls `starlette` `1.3.1`). The
  previous pins carried 8 disclosed vulnerabilities (`PYSEC-2024-38` and
  7 `starlette` CVEs) that `bandit`'s code-pattern scanning would never
  have caught - only `pip-audit` (added in this release, see below)
  surfaces known-CVE-in-a-pinned-version issues. Full test suite re-run
  and green at the new pins.

### Changed
- `requirements.txt` no longer installs `pytest`/`pytest-asyncio` into the
  production Docker image. Test/lint tooling moved to
  `requirements-dev.txt` (and mirrored in `pyproject.toml`'s
  `[project.optional-dependencies].dev`).
- CI now installs `requirements-dev.txt` and runs `pip-audit` against
  `requirements.txt` - bandit catches risky code patterns, not known CVEs
  in pinned dependency versions, so this closes that gap.

### Added
- Alembic migrations (`migrations/`), with an initial revision (`0001`)
  matching the schema `Base.metadata.create_all()` previously created
  implicitly at startup. `init_db()` remains for local/test convenience
  only; production schema changes now go through `alembic upgrade head`
  instead of an implicit, un-versioned `create_all()`.

---

## [1.1.0] — telegram-bridge rewrite

### Added
- `SignalStatus.PERMANENTLY_FAILED` — signals that hit a `NonRetryableError` are
  marked with this status so `/retry-failed` never re-selects them.
- `MaxBodySizeMiddleware` — raw ASGI middleware enforces the body-size cap against
  both `Content-Length` (cheap path) and actual streamed bytes (handles chunked
  transfer and lying clients).
- Index on `Signal.status` to keep `/retry-failed`'s `WHERE status = 'failed'`
  query fast as the table grows.
- `check_bot_token()` called at startup; logs a warning rather than crashing if
  the token is invalid, so the process still starts and the ops team can fix the
  secret without a full redeploy.
- Structured logging extras now rendered — `logger.bind(signal_id=...)` values
  actually appear in log output after fixing the format string.
- `TELEGRAM_TIMEOUT_SECONDS`, `TELEGRAM_MAX_RETRIES`, `TELEGRAM_RETRY_MAX_WAIT_SECONDS`
  config knobs with sensible defaults; worst-case retry window is now bounded and
  documented for the EA's WebRequest timeout budget.

### Changed
- Rate limiter rewritten from scratch (`app/ratelimit.py`) — dropped `slowapi`
  (maintenance concern; the `@limiter.limit(... if enabled else None)` pattern
  raises at import time when the limiter is disabled). Replaced with an
  in-memory fixed-window limiter that uses `X-Forwarded-For` for client
  identification (Render terminates TLS and `request.client.host` alone would
  collapse every caller into one bucket).
- CORS only applied when `ALLOWED_ORIGINS` lists explicit origins. The previous
  `allow_origins=["*"] + allow_credentials=True` combination is rejected by
  browsers per spec.
- API key comparison is now timing-safe (`secrets.compare_digest`).
- Shared `httpx.AsyncClient` created at startup and reused across all Telegram
  calls — avoids a fresh TCP+TLS handshake per signal.
- `@app.on_event("startup")` replaced with a `lifespan` context manager
  (the event-hook API is deprecated in current FastAPI).
- `payload.dict()` (Pydantic v1, deprecated) replaced with `payload.model_dump()`.
- `config.py` migrated from `class Config:` to `SettingsConfigDict` (Pydantic v2).
- Telegram `parse_mode` field omitted from the API payload (previously set to
  `null`, which is a no-op but noisy).

### Fixed
- Duplicate-insert race condition — two concurrent requests for the same
  `signal_id` could both pass the pre-check `SELECT` and one would raise an
  unhandled `IntegrityError` (500). Now caught explicitly; session is rolled
  back and the caller receives a clean duplicate response.
- TP1/TP2 validation added to `validator.py` — previously only stop-loss
  side-of-entry was checked. Now TP1 and TP2 must be on the correct side of
  entry and TP2 must be farther from entry than TP1.
- `entry`, `sl`, `tp1`, `tp2` fields now have `gt=0` Pydantic constraints.

---

## [1.0.0] — initial telegram-bridge

- Basic FastAPI service with `/signal`, `/health/db`, and `/retry-failed`.
- SQLAlchemy async + PostgreSQL persistence.
- `slowapi`-based rate limiting (superseded in 1.1.0).
- Pydantic v1 style settings and model helpers.

---

## MALI Audit History

Versioned audit reports are stored in [`mali-audit-reports/`](mali-audit-reports/).

> **Note:** As of this commit, `mali-audit-reports/` contains no report files
> (only a `.gitkeep` placeholder). The `47/100` score previously cited here
> belongs to the separate MedisTouch EA (MQL5) audit, not this telegram-bridge
> service - it was carried over into this changelog by mistake. Add the actual
> report file(s) for this repo before citing a score here again.
