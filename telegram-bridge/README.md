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
- **Trade tagging** – every signal and every resolved outcome carries structured regime/session/sweep-grade/HTF-alignment/weight-version tags (`signals` + `signal_outcomes` tables) — see [Trade tagging & recalibration](#trade-tagging--recalibration).
- **Tap-to-approve recalibration** – a scheduled cycle computes coverage/expectancy stats with confidence intervals, decides PROMOTE/HOLD/ROLLBACK per weight version, and only a genuine promotion candidate waits on a Telegram button tap — a contradiction between cycles auto-rolls-back and is never silently reconciled.

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
| POST   | `/outcome`          | Yes           | Receive a resolved (or no-fill) setup outcome from the EA's OutcomeTracker — see [Trade tagging & recalibration](#trade-tagging--recalibration) |
| GET    | `/config/{symbol}`  | Yes           | Polled by `ConfigSync.mqh` — reports the most recently approved weight_version, if any. Dormant: null until a real promotion happens |
| POST   | `/admin/run-cycle`  | Yes           | Trigger one recalibration cycle (metrics → gating decision → Telegram card / auto-rollback). Meant to be called by a scheduler, not a person — see [Scheduling](#scheduling-the-recalibration-cycle) |
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
| `/signal`      | Last 5 signals from the `signals` table — add a symbol to filter, e.g. `/signal XAUUSD` |
| `/analysis`    | Reasons/confidence behind the most recent signal                             |
| `/positions`   | Trades whose latest event isn't a close (`closed_tp1/tp2/sl/manual`)         |
| `/risk`        | Open position count, symbols exposed, total lot volume — *not* account equity or margin, which only exist inside the MT5 terminal |
| `/performance` | Win rate and total P/L over closed trades in the last 30 days                |
| `/stats`       | Today's summary: signals received, trades opened/closed, realized P/L        |
| `/symbols`     | Symbols with signal activity in the last 7 days, flagging muted ones         |
| `/status`      | Bridge health: DB connectivity, broadcast pause state, muted symbols, last signal age |
| `/mute SYMBOL` | Stop broadcasting new signals for a symbol (signal is still recorded, just not sent) |
| `/unmute SYMBOL` | Resume broadcasting for a previously muted symbol                          |
| `/muted`       | List currently muted symbols                                                 |
| `/pause`       | Pause outbound signal broadcasts for **all** symbols                         |
| `/resume`      | Resume outbound signal broadcasts                                            |
| `/retry`       | Manually retry failed/stuck signal and trade-event deliveries                |
| `/version`     | Reports the running bridge version                                           |

All commands are restricted to `ADMIN_CHAT_ID` — a message from any other chat, including the `CHAT_ID` signal group, is silently ignored.

**Tap-to-approve promotion cards** aren't commands — they're inline-keyboard buttons (✅ Approve / ❌ Reject) attached to a recalibration cycle's Telegram summary when that cycle's decision is `PROMOTE`. Same `ADMIN_CHAT_ID`-only authorization as the commands above, enforced in `app/bot_promotions.py` rather than the `_authorized_only` decorator (a callback-query update carries the tapping user differently than a message update does). A `ROLLBACK` decision never shows buttons — per the recalibration spec, a genuine contradiction between cycles auto-executes and is only ever flagged, never gated behind a tap. See [Trade tagging & recalibration](#trade-tagging--recalibration).

`/mute`, `/unmute`, and `/pause`/`/resume` are backed by a small `bot_settings` key/value
table (see `app/settings_store.py`) so the state survives a Render redeploy. `POST /signal`
checks this state before contacting Telegram — a muted or paused signal is still saved to
the `signals` table (so `/stats` and win-rate history stay accurate), it's just not sent.

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
| `CHAT_ID`                         | ✅       | —        | Telegram chat/group ID to broadcast signals into |
| `ADMIN_CHAT_ID`                   | ✅       | —        | The only chat the inbound bot accepts commands from (your DM) |
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

## Trade tagging & recalibration

Every signal is tagged at creation with `regime`, `session`, `sweep_grade`, `htf_ob_aligned`,
and `weight_version` (promoted out of the free-form `extra` JSON into indexed columns —
see `app/models.py:Signal`). Every setup the EA's `OutcomeTracker` simulator resolves — win,
loss, scratch, or no-fill — is posted back via `POST /outcome` into `signal_outcomes`, carrying
the same tags plus realized R / MFE / MAE. Before this existed, a resolved outcome only ever
reached a local CSV on the MT5 terminal; "why did we lose" was a CSV grep, not a query.

On top of that table, `tools/` (not part of the deployed image except where noted below) provides:

| Script                        | What it answers                                                                 |
|--------------------------------|----------------------------------------------------------------------------------|
| `tools/metrics_engine.py`      | Coverage vs. expectancy, reported as two separate tracks, never blended — plus `--regime-matrix` for the Symbol × Session × Volatility breakdown (trades, win %, avg R, profit factor, max drawdown) |
| `tools/calibration_matrix.py`  | Per-tag 4-week-baseline vs. 2-week-recent expectancy delta, with a sample-size-aware `Keep / Investigate / Reduce confidence / Insufficient` action column |
| `tools/stats.py`               | Wilson CI (win rate), AUC + Hanley-McNeil CI (does confidence discriminate win/loss), Pearson r + Fisher z CI (confidence vs. realized R) — no numpy/scipy |
| `tools/gating.py`              | Turns a *history* of cycle reports into a PROMOTE / HOLD / ROLLBACK decision: overlapping confidence intervals across consecutive cycles means "no significant change, don't act"; promotion requires the same direction to persist across `MIN_PERSISTENCE` (default 2) consecutive cycles; a genuine contradiction auto-rolls-back rather than being reconciled |
| `tools/generate_synthetic_cycles.py` | Fabricates cycle reports in `gating.py`'s exact input shape, tagged `source: synthetic`, so the gating logic can be rehearsed before any live data exists |

**Why "dummy data now, real data later" is safe, not a hack:** every cycle is tagged
`source: "live"` or `"synthetic"`. `gating.py` hard-refuses to compute a decision from a
history that mixes the two — there's no flag to flip once real cycles start arriving; a
synthetic cycle simply can never satisfy the source-purity check a real decision requires.

In production these three pieces run inside the deployed bridge, not by hand:

- `app/calibration.py` computes a `metrics_engine` report over the trailing window, persists it
  to the `calibration_cycles` table (the Postgres replacement for `tools/cycle_store.py`'s local
  JSON files — full audit trail, not just current state), and runs `tools/gating.py`'s decision
  logic against each weight version's `calibration_cycles` history.
- A `PROMOTE` decision creates a `pending` row in `promotion_requests` and posts a Telegram
  summary — decision, reasoning, and every gated metric's prior/latest confidence interval — to
  `ADMIN_CHAT_ID` with inline **✅ Approve** / **❌ Reject** buttons. `app/bot_promotions.py`
  handles the tap: idempotent (a second tap after the request is already decided just says so),
  edits the original message in place with the verdict and who made it, and on approval inserts
  the weight version into `approved_weight_versions`.
- A `ROLLBACK` decision (a genuine contradiction between cycles) executes immediately —
  `auto_executed` in `promotion_requests`, no buttons — and only ever *notifies*, per the rule
  that a contradiction is never silently reconciled.
- `HOLD` / `INSUFFICIENT_DATA` decisions are logged but don't message anyone — a cycle with
  nothing actionable shouldn't page you.

`approved_weight_versions` is an **approval log**, not a live config registry — approving a
weight version here doesn't push anything to a running EA on its own. What DOES read it:
`GET /config/{symbol}`, polled by each EA instance's `ConfigSync.mqh` (opt-in via
`InpConfigSyncEndpoint`) on a timer. It's observation-only by design — it detects and logs
drift ("bridge says X is approved, this instance is compiled with Y") but never auto-applies
anything, because there is still no numeric-parameter-proposal engine that would say WHAT
values a candidate weight_version actually corresponds to (`ConfigResponse.params` is always
null today). Dormant until both a real promotion happens and an EA instance is polling; the
same code activates automatically the moment both are true, no redeploy needed for that part.

## Walk-forward validation (step 3)

`tools/walk_forward.py` splits an already-elapsed reference window (default 4 weeks) into an
older TRAIN portion and the most-recent HOLDOUT portion (default the last 1 week), and compares
win-rate confidence intervals between them for a given `weight_version`. This satisfies "reuse
the actual EA's closed-bar signal logic, not a reimplementation" by construction — it only ever
reads `signal_outcomes`, which `OutcomeTracker.mqh` populates by running the EA's own production
decision code live, bar by bar. There is no separate Python backtester to keep in sync with the
real signal logic, because there isn't a separate one at all.

What this deliberately does NOT do: validate against a deeper historical window than the EA has
actually been live for (e.g. two years of XAUUSD history compressed into one run). That would
need to drive MT5's Strategy Tester, which has no environment to test against here — writing
that automation blind, unlike everything else in this system, would mean shipping unverified
code. `tools/walk_forward.py:ingest_tester_csv()` is left as an explicit stub for that path,
to be written against a real Tester CSV export's actual column layout rather than a guess.

## Scheduling the recalibration cycle

`POST /admin/run-cycle` (same `X-API-Key` auth as `/signal` and `/trade`) triggers one cycle.
It is **not** run by an in-process scheduler: this service is on Render's free web tier, which
spins down after 15 minutes idle (see `/render.yaml`), so nothing running inside the process
could reliably wake itself up on a biweekly schedule.

Instead, `.github/workflows/biweekly-recalibration.yml` runs on GitHub's infrastructure every
Saturday at 06:00 UTC (safely inside the weekend market-closed window), parity-checks the date
so it only actually fires every *other* Saturday, and `curl`s the endpoint — which conveniently
also wakes the sleeping service, since the wake-up call and the trigger are the same request.
A manual "Run workflow" dispatch always runs regardless of parity, for an on-demand cycle.

Requires two repository secrets (GitHub → Settings → Secrets and variables → Actions):

| Secret            | Value                                                        |
|--------------------|--------------------------------------------------------------|
| `BRIDGE_BASE_URL`  | e.g. `https://medis-touch-telegram.onrender.com`             |
| `BRIDGE_API_KEY`   | Same value as this service's `SECRET_KEY` env var            |

No new bridge-side environment variables are needed — `/admin/run-cycle` reuses `SECRET_KEY`
and `ADMIN_CHAT_ID`, both already required above.

Because `app/calibration.py` imports `tools/gating.py` and `tools/metrics_engine.py` directly
(one source of truth for the stats/decision logic, shared with the scripts you can also run by
hand against production data), `telegram-bridge/Dockerfile` copies `tools/` into the image
alongside `app/` — if you ever restructure the Dockerfile, keep that `COPY tools/ ./tools/`
line, or `/admin/run-cycle` will 500 on every call in production while working fine locally.

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
  "timeframe": "H1",
  "regime": "Normal",
  "session": "London",
  "sweep_grade": "B",
  "htf_ob_aligned": true,
  "weight_version": "v2.11-baseline"
}
```

Valid timeframes: `M1 M5 M15 M30 H1 H4 D1 W1 MN`

The five fields after `timeframe` are all optional (a pre-v2.11 EA build's payload validates
exactly as before, just without them) — see [Trade tagging & recalibration](#trade-tagging--recalibration)
for what reads them.

## Outcome Payload

`POST /outcome` — what `OutcomeTracker.mqh` posts once a setup resolves (win/loss/scratch) or
is abandoned unfilled (no-fill). `signal_id` should match the signal this outcome belongs to,
but doesn't have to — an outcome with no matching `signals` row still records fine, since
`signal_outcomes` carries its own full copy of the tags rather than requiring a join.

```json
{
  "signal_id": "MT#1234567890",
  "symbol": "XAUUSD",
  "direction": "BUY",
  "outcome": "win",
  "realized_r": 1.85,
  "mfe_r": 2.10,
  "mae_r": 0.30,
  "bars_held": 14,
  "bars_to_fill": 2,
  "filled": true,
  "regime": "High",
  "session": "London",
  "sweep_grade": "A",
  "htf_ob_aligned": true,
  "weight_version": "v2.11-baseline",
  "confidence_at_signal": 82.0,
  "confidence_decayed": 79.5,
  "decay_bars": 2
}
```

`outcome` is one of `win / loss / scratch / no_fill / ambiguous`. For `no_fill` and `ambiguous`,
`realized_r`/`mfe_r`/`mae_r` should be sent as `null`, not `0.0` — a real 0.0R scratch and "not
applicable" are different things and the expectancy metrics need to tell them apart.

