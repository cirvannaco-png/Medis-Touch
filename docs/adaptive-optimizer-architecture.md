# Adaptive Optimizer Architecture

## Runtime boundary

The optimizer is strictly outside the market decision path.

```text
LIVE EXECUTION PLANE
TICK -> LOCAL STATE -> REGIME -> STRATEGIES -> FUSION -> RISK -> ORDER
                         ^
                         | local validated config only

LEARNING PLANE
OUTCOMES -> PURGED WALK-FORWARD -> SEARCH -> ROBUSTNESS -> HOLDOUT -> CHALLENGER

CONFIGURATION PLANE
PROPOSAL -> CANONICAL JSON/SHA-256 -> POSTGRES REGISTRY -> APPROVAL -> SCHEDULE -> EA ACK -> ACTIVE
```

No optimizer calculation, PostgreSQL query, HTTP request, statistical test, or
walk-forward replay is permitted between a market tick and an order.

## Validation funnel

The default search budget is deliberately asymmetric:

1. at most 250 bounded candidates;
2. at most 40 statistical survivors;
3. at most 15 walk-forward survivors;
4. at most 5 robustness finalists;
5. at most 2 independent holdout finalists.

This reduces compute while making the search budget explicit and auditable.

## Configuration identity

Deployable parameters are serialized with deterministic key ordering and hashed
with SHA-256. The hash is the immutable configuration identity. Any change in
parameters therefore creates a new configuration record instead of mutating an
existing one.

## EA safety contract

`ConfigSync.mqh` validates the received parameter schema and bounds, then ACKs
`VALIDATED` or `REJECTED`. It does not dynamically mutate compiled trading
parameters. This is intentional: configuration receipt must never become an
implicit code-execution or strategy-mutation mechanism.

A future EA build may support runtime parameter application, but that feature
must add an explicit compatibility contract and an `APPLIED` ACK before the
backend treats a deployment as active.

## Migration

Apply Alembic revision `0007` after `0006`. The new tables are:

- `parameter_configurations`: immutable configuration/provenance registry;
- `parameter_deployments`: per-symbol deployment lifecycle;
- `parameter_deployment_acks`: EA validation/application audit trail.

The existing `approved_weight_versions` table remains an approval log. It is
not the runtime configuration registry.
