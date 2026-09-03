# Medis Touch Numeric Parameter-Proposal Engine

Purpose: produce bounded, auditable numeric EA configuration proposals.
The engine proposes numeric EA parameters; it never mutates the live
configuration directly. Every proposal is immutable, bounded, versioned,
reproducible, statistically evaluated, robustness-tested, and held for
approval before deployment.

Lifecycle: outcomes → candidate generation → evaluation → statistical
gates → robustness gates → regime/session/symbol gates → holdout →
proposal → human approval → immutable configuration → demo deployment →
monitoring → promote/hold/rollback.

Safety requirements:
- Never mutate the live EA directly.
- Use immutable configuration versions.
- Enforce hard parameter bounds and movement limits.
- Do not optimize risk percentage, leverage or capital exposure.
- Use the exact Medis Touch decision semantics in the evaluator.
- Use temporal walk-forward validation with purge/embargo where required.
- Require independent holdout validation.
- Check regime/session/symbol stability.
- Check parameter-neighborhood robustness.
- Record code commit, policy version, dataset hash, broker, symbol,
  timeframe, costs, candidate count and search space.
- Require human approval before activation.
- EA must validate configuration independently before applying it.
- Support deterministic rollback.

Required evaluator interface:
    evaluate(parameter_set) -> Evaluation
    evaluate_neighbors(parameter_set) -> iterable[Evaluation]

## Production release gates
- Implement the evaluator against real Medis Touch outcome data and exact
  EA decision semantics.
- Add purged walk-forward train/validation/holdout evaluation; never
  randomly shuffle temporal trades.
- Add multiple-testing/search provenance and immutable dataset/code/policy
  hashes.
- Persist parameter proposals, versions, evaluations, deployments and
  rollback events in PostgreSQL.
- Implement an explicit configuration state machine: GENERATED →
  VALIDATED → TESTED → PENDING_APPROVAL → APPROVED → SCHEDULED → ACTIVE →
  RETIRED/ROLLED_BACK.
- Revalidate all values in the bridge and again inside the EA before
  activation.
- Keep risk percentage, leverage, exposure and daily-loss controls outside
  the optimizer.
- Add unit, property, integration, replay, security and failure-injection
  tests.
- Compile with MetaEditor, run MT5 Strategy Tester validation, then
  conduct the controlled demo-forward test before any live promotion.

## Important engineering qualification
The included code is a production-oriented implementation foundation, not
evidence of completed MetaEditor compilation, MT5 Strategy Tester
validation, Exness execution validation, or live profitability. Those
must be verified independently with actual toolchain and
trading-environment evidence.
