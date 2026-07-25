# Medis Touch — Telegram Bridge

Production-ready FastAPI service that receives trade signals from an MT5 EA
and forwards them to a private Telegram group.

## Key Features

- **Secure** – API key authentication via `X-API-Key` header, timing-safe comparison.
- **Robust** – Retry logic with exponential backoff for Telegram API failures, tuned to stay within a WebRequest-friendly timeout budget.
- **Idempotent** – Duplicate `signal_id` are ignored, including under concurrent request races.
- **Persistent** – PostgreSQL (or SQLite for local dev) stores all signals.
- **Rate limited** – Configurable per-window request cap, proxy-aware client identification, no external rate-limit dependency.
- **Body size limit** – Enforced against both the `Content-Length` header and actual streamed bytes.
- **Health checks** – `/health/db` verifies database connectivity.
- **Structured logging** – Every request tagged with `signal_id`, and that tag actually appears in the log output.
- **Bulk retry** – `/retry-failed` endpoint safely resends transiently-failed signals; permanently-failed signals are excluded so they don't retry forever.
- **Token verification** – On startup, checks if the bot token is valid.

## Quick Start

1. Copy `.env.example` to `.env` and fill in the required values.
2. Install dependencies: `pip install -r requirements.txt`
3. Run: `uvicorn app.main:app --reload`

## API Endpoints

| Method | Path            | Auth required | Description                                      |
|--------|-----------------|---------------|--------------------------------------------------|
| GET    | `/`             | No            | Basic health check                               |
| GET    | `/health/db`    | Yes           | Health check with live DB connectivity test      |
| POST   | `/signal`       | Yes           | Receive and forward a new trade signal           |
| POST   | `/retry-failed` | Yes           | Resend up to 5 transiently-failed signals        |

All endpoints except `GET /` require the header `X-API-Key: <your SECRET_KEY>`.

## Environment Variables

| Variable                          | Required | Default  | Description                                                  |
|-----------------------------------|----------|----------|--------------------------------------------------------------|
| `BOT_TOKEN`                       | ✅       | —        | Telegram bot token from @BotFather                           |
| `CHAT_ID`                         | ✅       | —        | Telegram chat/group ID to post signals into                  |
| `SECRET_KEY`                      | ✅       | —        | Shared secret for EA authentication (`X-API-Key` header)     |
| `DATABASE_URL`                    | ✅       | SQLite¹  | Async DB URL — use `postgresql+asyncpg://...` in production  |
| `LOG_LEVEL`                       | No       | `INFO`   | Loguru log level                                             |
| `RATE_LIMIT_ENABLED`              | No       | `true`   | Enable/disable the per-client rate limiter                   |
| `RATE_LIMIT_MAX_REQUESTS`         | No       | `5`      | Max requests per window                                      |
| `RATE_LIMIT_WINDOW_SECONDS`       | No       | `60`     | Window length in seconds                                     |
| `MAX_REQUEST_BODY_SIZE`           | No       | `10240`  | Max request body in bytes                                    |
| `ALLOWED_ORIGINS`                 | No       | `""`     | Comma-separated browser origins for CORS; leave empty for EA-only traffic |
| `TELEGRAM_TIMEOUT_SECONDS`        | No       | `8`      | Per-attempt HTTP timeout to Telegram                         |
| `TELEGRAM_MAX_RETRIES`            | No       | `3`      | Send attempts before giving up                               |
| `TELEGRAM_RETRY_MAX_WAIT_SECONDS` | No       | `4`      | Cap on exponential backoff between attempts                  |

¹ Default `DATABASE_URL` is `postgresql+asyncpg://user:pass@localhost:5432/medis_touch`.
  For local SQLite development set `DATABASE_URL=sqlite+aiosqlite:///./signals.db`.

> **EA timeout note:** keep `TELEGRAM_TIMEOUT_SECONDS × TELEGRAM_MAX_RETRIES` (plus backoff)
> comfortably under your EA's `WebRequest` timeout. If the EA times out first it will resend
> under a new `signal_id` while the bridge is still retrying the original.

## Deployment on Render

The `render.yaml` is pre-configured for Render's Docker runtime. Add the environment variables
(especially `DATABASE_URL` pointing at a Render PostgreSQL instance) and deploy.

## Rate Limiter Note

The rate limiter's state is **per-process**. A single-instance Render deployment is fine.
If you ever scale to multiple workers or instances, move the limiter to Redis (`INCR` + `EXPIRE`).

## Signal Payload

```json
{
  "signal_id": "unique-string-max-100-chars",
  "symbol": "EURUSD",
  "direction": "BUY",
  "entry": 1.08500,
  "sl": 1.08200,
  "tp1": 1.08800,
  "tp2": 1.09100,
  "confidence": 78,
  "reasons": ["SMC bullish OB on H4", "RSI divergence on M15"],
  "timeframe": "H1"
}
```

Valid timeframes: `M1 M5 M15 M30 H1 H4 D1 W1 MN`
