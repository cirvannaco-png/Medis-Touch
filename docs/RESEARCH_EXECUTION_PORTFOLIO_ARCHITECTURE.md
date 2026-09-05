# Medis Touch — Four-Phase Research / Execution / Portfolio Architecture

## Phase 1 — Research foundation

**Live Engine** remains the production decision authority. **Research Engine** consumes immutable experiment observations and can construct three deterministic books from the same opportunities:

1. `candidate` — actual ensemble decision/outcome.
2. `smc_baseline` — SMC-only hypothetical outcome on the same opportunity set.
3. `strategy_diagnostics` — SMC, Momentum, MeanRev and KeyLevel hypothetical outcomes, including strategies that did not win selection.

Every observation is fingerprinted and tied to `experiment_id`, code SHA, config hash and data snapshot. This prevents a report from silently mixing code/config/data generations.

## Phase 2 — Validation and promotion

Validation is chronological and leakage-resistant: train → purge/embargo → OOS → walk-forward → locked holdout → promotion gate. A challenger cannot promote merely because its win rate is higher. The gate evaluates sample size, expectancy, drawdown, win rate, paired practical improvement and holdout status.

Champion/challenger comparison is paired on the same opportunity sequence whenever possible. The holdout is locked before it can be used as a tuning target.

## Phase 3 — Execution integrity

The MT5 execution path now has a dedicated asynchronous execution contract with:

- `OrderCheck()` before submission;
- unique request IDs and idempotent request ledger;
- reservation-before-send semantics;
- `OrderSendAsync()`;
- explicit FSM states including `REQUOTED`, `RECOVERING` and `RECONCILED`;
- `OnTradeTransaction()` reconciliation hook;
- reservation/request leases for crash recovery;
- broker order/deal/position identifiers;
- microsecond timestamps for latency measurement.

The existing synchronous `COrderManager` remains the compatibility path until the asynchronous engine has been compiled and exercised in MT5 Strategy Tester/demo conditions. This is intentional: enabling an unverified execution path on a live account would be an engineering regression, not an improvement.

## Phase 4 — Portfolio coordination

Cross-symbol admission is reservation-based rather than post-hoc. The coordinator tracks:

- gross volatility-normalized heat;
- directional exposure;
- correlated-cluster risk;
- market/USD factor exposure;
- duplicate reservation requests.

The Python control plane persists reservations and execution state in PostgreSQL. The MT5 coordinator provides the corresponding terminal-side admission primitive for simultaneous cross-symbol decisions.

## Promotion invariants

A configuration/weight version must carry:

- code commit SHA;
- canonical config hash;
- data snapshot identifier;
- experiment ID;
- weight version;
- validation run IDs;
- holdout decision;
- promotion audit record.

No component may infer profitability from `confidence`, win rate alone, or an in-sample optimization result.
