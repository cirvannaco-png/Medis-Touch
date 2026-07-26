# Changelog

All notable changes to Medis Touch are documented here.  
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
