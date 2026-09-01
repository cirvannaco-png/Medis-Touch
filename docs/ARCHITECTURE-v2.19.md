# Medis Touch v2.19 Architecture Changes

## 1. Production decision pipeline

The target execution topology is now explicitly:

```text
REGIME ENGINE
      ↓
STRATEGY SELECTOR
      ↓
SELECTED STRATEGY
      ↓
STRATEGY-SPECIFIC SETUP
      ↓
COMMON RISK ENGINE
      ↓
PORTFOLIO ENGINE
      ↓
EXECUTION
```

The repository now contains `Strategies/StrategySetupRouter.mqh` as the
fail-closed seam between selection and setup construction.

**Important:** the router does not pretend the diagnostic Momentum/Breakout,
Mean Reversion, or Key-Level modules are executable strategies. Until each
has its own entry/invalidation/target adapter, selecting one is rejected
rather than silently reusing the SMC/FVG setup. This protects trade tagging,
calibration validity, and risk accounting.

The existing SMC/FVG setup remains the only production setup adapter in this
change set.

## 2. End-to-end latency telemetry

`Monitoring/LatencyTelemetry.mqh` records the complete local pipeline:

```text
T0 = first locally observable market-candidate evaluation
T1 = detection stage complete
T2 = confidence/calibration stage complete
T3 = decision generated
T4 = risk/portfolio sizing complete
T5 = order submission begins
T6 = broker acknowledgement observed
T7 = fill observed
```

Derived metrics:

```text
DetectionLatency   = T1 - T0
DecisionLatency    = T3 - T1
RiskLatency        = T4 - T3
SubmissionLatency  = T5 - T4
BrokerLatency      = T6 - T5
FillLatency        = T7 - T6
TotalSignalToFill  = T7 - T0
```

For a synchronous market order, T6 and T7 may be nearly identical because
`CTrade` returns after the trade result/fill is available locally. For a
resting limit order, T6 is the order acknowledgement and T7 is recorded later
from the `OnTradeTransaction` fill path.

The telemetry is written to:

```text
MQL5/Files/MedisTouch_Latency_<SYMBOL>.csv
```

`GetMicrosecondCount()` is used for intervals. It is a program-relative
monotonic counter, so it must not be interpreted as an absolute wall-clock
timestamp.

## 3. Broker safety: fail closed

`ValidateStopDistance()` now refuses execution when required symbol metadata
is unavailable or invalid. In particular:

```text
SYMBOL_POINT <= 0
invalid STOPS_LEVEL
invalid FREEZE_LEVEL
invalid reference price
        ↓
REFUSE TRADE
```

The operative minimum stop distance remains:

```text
max(STOPS_LEVEL, FREEZE_LEVEL) × SYMBOL_POINT
```

This is deliberately conservative. Unknown broker constraints are treated as
unsafe rather than silently allowing a request that cannot be validated.

## 4. Calibration policy

The two-week window remains the **observation cadence**, not the complete
promotion criterion.

A candidate promotion now requires:

1. minimum resolved observations in the latest cycle;
2. confidence-interval evidence and the existing persistence rule;
3. a minimum practical effect size;
4. explicit comparison with `CALIBRATION_BASELINE_WEIGHT_VERSION`;
5. a passing chronological temporal holdout;
6. multi-cycle confirmation.

The strict gate refuses to guess the baseline and refuses to promote when an
OOS block is missing.

The temporal holdout is intentionally described as a **sanity validation**,
not proof that parameter selection was independent of the holdout. Full
walk-forward parameter generation remains a separate research requirement.
