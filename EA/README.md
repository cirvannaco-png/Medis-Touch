# EA — MedisTouch v2.8 (MQL5)

MetaTrader 5 source for the Medis Touch engine. The backend that receives
its signals lives in [`../telegram-bridge`](../telegram-bridge).

## Layout

```text
EA/
├── MedisTouch_v2.8.mq5              # Expert Advisor (trading + signal publishing)
├── MedisTouch_Indicator_v2.8.mq5    # chart indicator (visuals/dashboard, no trading calls)
└── includes/
    ├── InducementEngine.mqh         # v2.8 facade -> SmartMoney/Inducement + MarketPhase + PremiumDiscount
    ├── HTF_OrderBlock.mqh           # v2.8 facade -> SmartMoney/OrderBlock (run on an HTF context)
    ├── VolatilityRegime.mqh         # v2.8 facade -> Analysis/VolatilityRegime (ATR percentile regime)
    ├── Core/                        # Config, CandleData, ObjectManager, SessionFilter, SignalLogger
    ├── Analysis/                    # TFContext, Scoring, TrendEngine, VolatilityRegime
    ├── Structure/                   # SwingDetector, BOS, CHOCH
    ├── SmartMoney/                  # FVG, Liquidity, OrderBlock, Inducement, PremiumDiscount, ValueArea, Volume, Fibonacci, SupportResistance, MarketPhase
    ├── Trading/                     # TradeZone, RiskEngine, Targets, OutcomeTracker
    ├── Decision/                    # TradeDecision (records), DecisionEngine (policy router), DecisionStore (CSV persistence)
    ├── Execution/                   # BrokerAdapter, OrderManager, PositionManager, TradeStateMachine
    ├── Recovery/                    # RecoveryEngine (reconciles broker state after a restart)
    ├── Portfolio/                   # PortfolioManager (cross-symbol risk caps)
    ├── Signals/                     # SignalPublisher (HTTP -> telegram-bridge), SubscriberPlatform
    ├── Monitoring/                  # ProductionMonitor (heartbeat, drawdown alerts, reject counters)
    └── UI/                          # Dashboard, Visuals (indicator only)
```

The three facade headers are the stable include paths for the v2.8
additions. They only `#include` the real implementation next to the
concepts it depends on, so the internal folder layout can move without
breaking call sites. Every underlying header has an include guard, so
including a facade and the concrete header together is safe.

## Why two `.mq5` files

MQL5 forbids trading calls (`OrderSend`, `CTrade`) from an indicator
context. `MedisTouch_Indicator_v2.8.mq5` is the visualisation-only chart
indicator; `MedisTouch_v2.8.mq5` is the robot that runs under `OnTick()`
where trading is legal. They share the same analysis engine and can run
on the same chart together.

## Install / compile

1. Copy `MedisTouch_v2.8.mq5` and the whole `includes/` folder into
   `MQL5/Experts/MedisTouch/` in your terminal's data folder
   (File → Open Data Folder in MT5), keeping the relative layout —
   the EA includes with paths like `includes/Core/Config.mqh`.
2. Copy `MedisTouch_Indicator_v2.8.mq5` (plus the same `includes/`) into
   `MQL5/Indicators/MedisTouch/` if you want the chart visuals.
3. Open each `.mq5` in MetaEditor and press F7. Expect 0 errors.
4. In MT5: Tools → Options → Expert Advisors → allow WebRequest for the
   backend URL, otherwise `SignalPublisher` cannot post signals.

Compiled `.ex5` output is git-ignored on purpose — build it locally.

## Signal publishing

`Signals/SignalPublisher.mqh` posts each routed decision to the FastAPI
service in `telegram-bridge`. The service broadcasts to `CHAT_ID` and
accepts bot commands only from `ADMIN_CHAT_ID`.

## Decision persistence

`Decision/DecisionStore.mqh` appends every routed decision and every
submitted execution to CSV files in the terminal's `MQL5/Files` folder
(`MedisTouch_Decisions_<SYMBOL>.csv`, `MedisTouch_Executions_<SYMBOL>.csv`).
`Recovery/RecoveryEngine.mqh` reads them at startup and matches broker
tickets back to the setup that created them via the `MT#<decision_id>`
order comment. Deleting those files means a restarted terminal can no
longer manage trades opened by a previous session.

## CI

`.github/workflows/ea-validate.yml` runs `tools/validate_mql5.py` on every
change under `EA/`: it resolves every `#include` in the tree, fails on a
missing or case-mismatched header, on unbalanced include guards, and on
any compiled binary (`*.ex5`/`*.ex4`) that slipped into the repository.
MetaEditor is Windows-only and not available on GitHub runners, so this is
a static structural check, not a compile.
