# Medis Touch

Medis Touch is an MT5 Expert Advisor (EA) suite with a production-ready Telegram signal bridge. The EA generates trade signals on your MT5 terminal; the bridge receives them via HTTP and forwards them to a private Telegram group.

## Subprojects

| Directory | What it is |
|-----------|------------|
| [`EA/`](EA/) | MQL5 source for MedisTouch (v2.10 engine) — Expert Advisor, indicator, and the `includes/` engine tree |
| [`tools/`](tools/) | CI include-tree validator, offline confidence-model comparison script, and the trade-tagging recalibration suite (`metrics_engine.py`, `calibration_matrix.py`, `gating.py`, `stats.py`) — copied into the bridge's Docker image and driven in production by `telegram-bridge/app/calibration.py`; also runnable standalone against the production DB for ad-hoc reports |
| [`mql5/`](mql5/) | Legacy placeholder tree mirroring the MT5 terminal layout (Experts / Include / Scripts) |
| [`telegram-bridge/`](telegram-bridge/) | FastAPI service: receives signals from the EA and posts them to Telegram |
| [`docs/`](docs/) | Changelog and MALI audit history |


## How the pieces talk to each other

```
MT5 Terminal
  └─ EA (MQL5 Expert)
       ├─ WebRequest POST /signal   ──►  telegram-bridge (FastAPI)
       └─ WebRequest POST /outcome  ──►       │
                                              ├─ sendMessage  ──►  Telegram Bot API
                                              └─ PostgreSQL (signals, signal_outcomes,
                                                 calibration_cycles, promotion_requests)

GitHub Actions (biweekly cron)
  └─ POST /admin/run-cycle  ──►  telegram-bridge
                                   ├─ tools/metrics_engine.py + tools/gating.py
                                   └─ PROMOTE  ──► Telegram tap-to-approve card
                                      ROLLBACK ──► auto-executed + Telegram notice
```

1. The EA calls the bridge's `/signal` endpoint with an `X-API-Key` header and a JSON body describing the trade signal.
2. The bridge validates, deduplicates, persists, and forwards the signal to the configured Telegram chat.
3. Transient Telegram failures are stored with `status=failed` and can be replayed via `/retry-failed`.

## Quick start (telegram-bridge)

```bash
cd telegram-bridge
cp .env.example .env          # fill in BOT_TOKEN, CHAT_ID, ADMIN_CHAT_ID, SECRET_KEY, WEBHOOK_SECRET_TOKEN, DATABASE_URL
pip install -r requirements.txt
uvicorn app.main:app --reload
```

See [`telegram-bridge/README.md`](telegram-bridge/README.md) for full environment variable reference and Render deployment instructions.

## Status

- **telegram-bridge**: implemented, tested, deployable (see below).
- **EA/**: the EA (`MedisTouch_v2.8.mq5`), the visuals-only indicator
  (`MedisTouch_Indicator_v2.8.mq5`) and the full `includes/` engine tree.
  Filenames still say v2.8; the engine inside is **v2.10**. Compiled `.ex5`
  output is git-ignored; build it in MetaEditor. CI runs a structural check
  on every push (see `EA/README.md`).
- **Confidence engine**: **v2.10 is diagnostic-only.** The contradiction /
  environment / execution model and the confidence decay are computed and
  logged, but nothing in them can change a confidence value, a filter
  verdict, a lot size, or an order. See below.
- **mql5/**: legacy placeholder tree kept for the terminal-style folder
  layout (`Experts/`, `Include/`, `Scripts/`). Nothing new should be added
  there — `EA/` is the source of truth.

## Confidence diagnostics (v2.10)

v2.10 addresses two known weaknesses of the additive confidence score
**without changing a single trading decision**.

1. **Absence is not contradiction.** In the additive model a setup with no
   HTF read and a setup fighting the HTF trend score the same, because both
   simply fail to earn the points. `ContradictionPenalty` counts only the
   conditions actively pointing the other way (trend against, premium/
   discount wrong, chased entry, low-volatility regime, out of session,
   news risk, a spent HTF order block).
2. **Points cannot express "the market is unsuitable".** `EnvScore`
   (regime, session, news) and `ExecScore` (sweep grade, BOS strength,
   freshness, chase) are combined *multiplicatively*, so a perfect entry in
   a bad environment no longer scores like a perfect entry in a good one:

   ```text
   EnvExecConfidence = Confidence x EnvScore x ExecScore x (1 - ContradictionPenalty)
   ```

3. **Confidence has a shelf life.** A score was true of the bar that
   produced it. `ConfidenceDecayed` applies an exponential half-life
   (`InpDiagDecayHalfLifeBars`, default 12) per **unfilled** bar and freezes
   once the zone is filled — after a fill the setup was right or wrong on
   its own terms, and staleness stops being the question.

### These numbers are measured, not obeyed

`EnvExecConfidence` and `ConfidenceDecayed` are written to the signal and
outcome CSVs beside the live `Confidence` the EA actually acted on, and are
read by nothing else. No filter, no confidence return value, no lot size,
and no order consults them. That is the point: an alternative score that has
not beaten the live one on your own resolved trades has not earned the right
to size a position.

To compare the two models on your own logs:

```bash
python tools/medistouch_retrain.py MedisTouch_Outcomes_XAUUSD.csv
```

It reports AUC (ranking quality) for the additive, multiplicative and
decayed scores, correlates each component against realized R, and refuses to
draw a conclusion below `--min-sample` resolved trades. It never writes to
the EA. Promoting the multiplicative model to live is a deliberate edit to
`EA/includes/Analysis/Scoring.mqh`, reviewed as a change in trading
behaviour — and only worth doing if the edge survives on a held-out period.

Tuning knobs live in the **"Confidence Diagnostics (v2.10)"** input group:
`InpDiagContradictionWeight`, `InpDiagEnvWeight`, `InpDiagExecWeight`,
`InpDiagDecayHalfLifeBars`. All four affect CSV columns only.

### New CSV columns

| File | Columns added |
|------|---------------|
| `MedisTouch_Signals_<SYMBOL>.csv` | `ContradictionPenalty`, `EnvScore`, `ExecScore`, `EnvExecConfidence` |
| `MedisTouch_Outcomes_<SYMBOL>.csv` | `ConfidenceAtSignal`, `ConfidenceDecayed`, `DecayBars`, plus the four above |

Columns are **appended**, so existing position-based parsers keep working.

## Repository layout

```
medis-touch/
├── EA/                        # MQL5 source (v2.10 engine) — the source of truth
│   ├── MedisTouch_v2.8.mq5           # Expert Advisor: decision routing + execution + publishing
│   ├── MedisTouch_Indicator_v2.8.mq5 # chart indicator: visuals/dashboard only
│   └── includes/              # engine tree (Core, Analysis, Structure, SmartMoney,
│                              # Trading, Decision, Execution, Recovery, Portfolio,
│                              # Signals, Monitoring, UI) + v2.8 facade headers
├── tools/
│   ├── validate_mql5.py       # CI: resolves every #include, rejects empty headers/binaries
│   └── medistouch_retrain.py  # offline: does the v2.10 model beat the live score? (read-only)
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
