# Medis Touch — Telegram Bridge

Production-ready FastAPI service that receives trade signals from an MT5 EA
and forwards them to a private Telegram group. It also runs an **inbound
bot** in the same process (webhook mode) so the group can query the bridge
directly with commands like `/positions` or `/performance`.

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
- **Inbound bot** – `/start`, `/signal`, `/analysis`, `/positions`, `/risk`, `/performance`, `/help`, answered from the same `signals` / `trade_events` tables the outbound side writes to. Runs in Telegram webhook mode (not polling), so it needs no second process — see [Inbound bot](#inbound-bot) below.

## Quick Start

1. Copy `.env.example` to `.env` and fill in the required values.
2. Install dependencies: `pip install -r requirements.txt`
3. Run: `uvicorn app.main:app --reload`

## API Endpoints

| Method | Path                | Auth required | Description                                              |
|--------|---------------------|---------------|------------------------------------------------------------------|
| GET    | `/`                 | No            | Basic health check                                       |
| GET    | `/health/db`        | Yes           | Health check with live DB connectivity test              |
| POST   | `/signal`           | Yes           | Receive and forward a new trade signal                   |
| POST   | `/trade`            | Yes           | Receive and forward a trade lifecycle event               |
| POST   | `/retry-failed`     | Yes           | Resend up to 5 transiently-failed signals                |
| POST   | `/trade/retry-failed` | Yes         | Resend up to 5 transiently-failed trade events             |
| POST   | `/telegram/webhook` | Telegram only | Inbound updates from Telegram (verified via secret token) |

All endpoints except `GET /` and `POST /telegram/webhook` require the header `X-API-Key: <your SECRET_KEY>`.
`POST /telegram/webhook` instead requires `X-Telegram-Bot-Api-Secret-Token: <your WEBHOOK_SECRET_TOKEN>` —
Telegram sends this automatically once the webhook is registered (see below); nothing else should call this endpoint.

## Inbound bot

Commands, registered with Telegram on startup via `setMyCommands`:

| Command        | What it does                                                                 |
|----------------|-------------------------------------------------------------------------------|
| `/start`       | Confirms the bot is online                                                    |
| `/help`        | Lists commands                                                                |
| `/signal`      | Last 5 signals from the `signals` table                                      |
| `/analysis`    | Reasons/confidence behind the most recent signal                             |
| `/positions`   | Trades whose latest event isn't a close (`closed_tp1/tp2/sl/manual`)         |
| `/risk`        | Open position count, symbols exposed, total lot volume — *not* account equity or margin, which only exist inside the MT5 terminal |
| `/performance` | Win rate and total P/L over closed trades in the last 30 days                |

All commands are restricted to `CHAT_ID` — a message from any other chat is silently ignored.

**How it's wired:** this runs in Telegram **webhook** mode, not long-polling. On startup, `app/bot.py`
calls `setWebhook` pointing at `POST /telegram/webhook` on this same service, using
`RENDER_EXTERNAL_URL` (which Render sets automatically) or `WEBHOOK_URL` if you're running elsewhere.
Telegram then POSTs updates to that route, and they're handed to
[python-telegram-bot](https://github.com/python-telegram-bot/python-telegram-bot)'s `Application.process_update()`.
This means no second process/worker is needed — one Render web service serves both the EA-facing
`/signal`/`/trade` endpoints and the Telegram bot.

If Telegram is unreachable at startup (bad token, outage, offline dev environment), `app/bot.py` logs a
warning and the rest of the service starts normally — outbound signal/trade delivery via `/signal` and
`/trade` does not depend on the inbound bot being wired up.

## Environment Variables

| Variable                          | Required | Default  | Description                                                  |
|-----------------------------------|----------|----------|--------------------------------------------------------------|
| `BOT_TOKEN`                       | ✅       | —        | Telegram bot token from @BotFather                           |
| `CHAT_ID`                         | ✅       | —        | Telegram chat/group ID to post signals into, and the only chat the inbound bot responds to |
| `SECRET_KEY`                      | ✅       | —        | Shared secret for EA authentication (`X-API-Key` header)     |
| `WEBHOOK_SECRET_TOKEN`            | ✅       | —        | Shared secret Telegram must present on every inbound webhook call |
| `DATABASE_URL`                    | ✅       | SQLite¹  | Async DB URL — use `postgresql+asyncpg://...` in production  |
| `RENDER_EXTERNAL_URL`             | No       | —        | Set automatically by Render; used to build the webhook URL   |
| `WEBHOOK_URL`                     | No       | `""`     | Override for the public base URL (local tunneling, custom domains) |
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
(especially `DATABASE_URL` pointing at a Render PostgreSQL instance, and the new `WEBHOOK_SECRET_TOKEN`)
and deploy. `RENDER_EXTERNAL_URL` is injected automatically — no action needed for the webhook to
find its own public URL.

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

