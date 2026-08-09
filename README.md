# Medis Touch

Medis Touch is an MT5 Expert Advisor (EA) suite with a production-ready Telegram signal bridge. The EA generates trade signals on your MT5 terminal; the bridge receives them via HTTP and forwards them to a private Telegram group.

## Subprojects

| Directory | What it is |
|-----------|------------|
| [`EA/`](EA/) | MQL5 source for MedisTouch v2.8 — Expert Advisor, indicator, and the `includes/` engine tree |
| [`mql5/`](mql5/) | Legacy placeholder tree mirroring the MT5 terminal layout (Experts / Include / Scripts) |
| [`telegram-bridge/`](telegram-bridge/) | FastAPI service: receives signals from the EA and posts them to Telegram |
| [`docs/`](docs/) | Changelog and MALI audit history |


## How the pieces talk to each other

```
MT5 Terminal
  └─ EA (MQL5 Expert)
       └─ WebRequest POST /signal  ──►  telegram-bridge (FastAPI)
                                              └─ sendMessage  ──►  Telegram Bot API
                                              └─ PostgreSQL (signal log + retry state)
```

1. The EA calls the bridge's `/signal` endpoint with an `X-API-Key` header and a JSON body describing the trade signal.
2. The bridge validates, deduplicates, persists, and forwards the signal to the configured Telegram chat.
3. Transient Telegram failures are stored with `status=failed` and can be replayed via `/retry-failed`.

## Quick start (telegram-bridge)

```bash
cd telegram-bridge
cp .env.example .env          # fill in BOT_TOKEN, CHAT_ID, ADMIN_CHAT_ID, SECRET_KEY, DATABASE_URL
pip install -r requirements.txt
uvicorn app.main:app --reload
```

See [`telegram-bridge/README.md`](telegram-bridge/README.md) for full environment variable reference and Render deployment instructions.

## Status

- **telegram-bridge**: implemented, tested, deployable (see below).
- **EA/**: MedisTouch **v2.8** source is committed here — the EA
  (`MedisTouch_v2.8.mq5`), the visuals-only indicator
  (`MedisTouch_Indicator_v2.8.mq5`) and the full `includes/` engine tree.
  Compiled `.ex5` output is git-ignored; build it in MetaEditor. CI runs a
  structural check on every push (see `EA/README.md`).
- **mql5/**: legacy placeholder tree kept for the terminal-style folder
  layout (`Experts/`, `Include/`, `Scripts/`). Nothing new should be added
  there — `EA/` is the source of truth.

## Repository layout

```
medis-touch/
├── EA/                        # MQL5 source (v2.8) — the source of truth
│   ├── MedisTouch_v2.8.mq5           # Expert Advisor: decision routing + execution + publishing
│   ├── MedisTouch_Indicator_v2.8.mq5 # chart indicator: visuals/dashboard only
│   └── includes/              # engine tree (Core, Analysis, Structure, SmartMoney,
│                              # Trading, Decision, Execution, Recovery, Portfolio,
│                              # Signals, Monitoring, UI) + v2.8 facade headers
├── tools/
│   └── validate_mql5.py       # CI: resolves every #include, rejects empty headers/binaries
├── mql5/                      # legacy placeholder tree, see Status above
│   ├── Experts/
│   │   └── MedisTouch/
│   ├── Include/
│   └── Scripts/

├── telegram-bridge/
│   ├── app/
│   │   ├── main.py            # FastAPI app factory + ASGI middlewares
│   │   ├── routes.py          # Endpoints: /, /health/db, /signal, /retry-failed
│   │   ├── config.py          # Pydantic Settings (env-driven)
│   │   ├── database.py        # SQLAlchemy async engine + session factory
│   │   ├── models.py          # Signal ORM model + SignalStatus enum
│   │   ├── telegram.py        # httpx client + tenacity retry logic
│   │   ├── validator.py       # Business-rule validation (SL/TP side-of-entry)
│   │   ├── formatter.py       # Telegram message formatter
│   │   ├── ratelimit.py       # In-memory fixed-window rate limiter
│   │   ├── logger.py          # Loguru setup with structured extras
│   │   └── utils.py           # Latency helper
│   ├── Dockerfile
│   ├── render.yaml
│   ├── requirements.txt
│   └── README.md
├── docs/
│   ├── CHANGELOG.md
│   └── mali-audit-reports/    # Versioned MALI audit snapshots
└── README.md                  # ← you are here
```
