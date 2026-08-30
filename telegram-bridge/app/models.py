import enum
from datetime import datetime, timezone

import sqlalchemy as sa
from sqlalchemy import JSON, Column, DateTime, Float, Index, Integer, String, Text
from sqlalchemy.dialects.postgresql import ENUM as PG_ENUM

from app.database import Base


class SignalStatus(str, enum.Enum):
    PENDING = "pending"                  # signal_id reserved, Telegram call not yet resolved
    ACTIVE = "active"
    FAILED = "failed"                    # transient failure, eligible for /retry-failed
    PERMANENTLY_FAILED = "permanently_failed"  # NonRetryableError - do not keep retrying
    DUPLICATE = "duplicate"


# v2.9 addition. Distinct from SignalStatus above: SignalStatus tracks
# DELIVERY (did the Telegram call succeed), lifecycle_status tracks
# MARKET VALIDITY (does this setup still describe current price action).
# A signal can be status=ACTIVE (delivered fine) and lifecycle_status=
# STALE (price ran away from it) at the same time — these are
# orthogonal, not a single combined state machine.
class SignalLifecycleStatus(str, enum.Enum):
    VALID = "valid"              # default — setup still describes current conditions
    STALE = "stale"              # price moved meaningfully past the intended entry zone
    EXPIRED = "expired"          # unfilled for too long; EA gave up waiting
    INVALIDATED = "invalidated"  # an opposing BOS or other structural break contradicts the original setup


class TradeEventStatus(str, enum.Enum):
    PENDING = "pending"                  # event_id reserved, Telegram call not yet resolved
    ACTIVE = "active"
    FAILED = "failed"                    # transient failure, eligible for retry
    PERMANENTLY_FAILED = "permanently_failed"


class TradeEventType(str, enum.Enum):
    OPENED = "opened"
    MODIFIED = "modified"
    PARTIAL_CLOSE = "partial_close"
    CLOSED_TP1 = "closed_tp1"
    CLOSED_TP2 = "closed_tp2"
    CLOSED_SL = "closed_sl"
    CLOSED_MANUAL = "closed_manual"


# FIX: Use PG_ENUM (sqlalchemy.dialects.postgresql.ENUM) instead of the
# generic SAEnum (sa.Enum / from sqlalchemy import Enum as SAEnum).
#
# The generic class silently discards create_type=False — the keyword is
# accepted into **kwargs and thrown away, and the Postgres dialect adapter
# then builds a brand-new ENUM object with its own default of create_type=True,
# completely independent of what was passed to the generic class. The result
# is that op.create_table() fires an unguarded CREATE TYPE, which collides
# with the type the DO $$ block just created and raises:
#   sqlalchemy.exc.ProgrammingError: asyncpg.exceptions.DuplicateObjectError
#
# PG_ENUM stores and respects create_type=False directly. Verified against
# sqlalchemy[asyncio]==2.0.25, the exact version pinned in requirements.txt.
# SQLite is unaffected (enums map to VARCHAR there).
_signal_status_type = PG_ENUM(
    SignalStatus,
    name="signalstatus",
    create_type=False,
)
# v2.9. Same PG_ENUM + create_type=False pattern as _signal_status_type
# above, for the exact DuplicateObjectError reason documented there.
_signal_lifecycle_status_type = PG_ENUM(
    SignalLifecycleStatus,
    name="signallifecyclestatus",
    create_type=False,
)
_trade_event_status_type = PG_ENUM(
    TradeEventStatus,
    name="tradeeventstatus",
    create_type=False,
)
_trade_event_type_type = PG_ENUM(
    TradeEventType,
    name="tradeeventtype",
    create_type=False,
)


class BotSetting(Base):
    """
    Generic key/value store for operator-facing bridge controls that must
    survive restarts (Render redeploys, dyno cycling) - the kind of thing
    that otherwise accumulates as one dedicated column + migration per
    flag. Two keys currently in use:

      "muted_symbols"    -> JSON list[str], e.g. ["XAUUSD", "GBPJPY"]
      "broadcast_paused" -> JSON bool

    See app/settings_store.py for the read/write helpers; nothing should
    query this table directly outside that module.
    """
    __tablename__ = "bot_settings"

    key = Column(String, primary_key=True)
    value = Column(JSON, nullable=False)
    updated_at = Column(
        DateTime(timezone=True),
        default=lambda: datetime.now(timezone.utc),
        onupdate=lambda: datetime.now(timezone.utc),
    )


class TradeEvent(Base):
    """
    A single lifecycle event for a live trade the EA has actually placed
    with the broker (open/modify/partial-close/close). Distinct from
    Signal, which is a pre-trade alert - a Signal is "here's a setup",
    a TradeEvent is "the EA's OrderManager/PositionManager did something
    with a real order ticket". One signal_id can have zero, one, or many
    TradeEvents (opened, then later closed_tp1, closed_manual, etc.).
    """
    __tablename__ = "trade_events"
    __table_args__ = (
        Index("ix_trade_events_status", "status"),
        Index("ix_trade_events_trade_id", "trade_id"),
    )

    id = Column(Integer, primary_key=True, autoincrement=True)
    # Caller-supplied idempotency key, one per physical event (NOT per trade -
    # the same trade_id legitimately recurs across opened -> closed_tp1 etc).
    # Recommended convention: f"{trade_id}:{event}" or ticket+timestamp.
    event_id = Column(String, unique=True, nullable=False, index=True)
    trade_id = Column(String, nullable=False)          # broker ticket / position id
    signal_id = Column(String, nullable=True, index=True)  # links back to originating Signal, if any
    symbol = Column(String, nullable=False)
    direction = Column(String, nullable=False)
    event = Column(_trade_event_type_type, nullable=False)
    volume = Column(Float, nullable=False)
    price = Column(Float, nullable=False)
    sl = Column(Float, nullable=True)
    tp1 = Column(Float, nullable=True)
    tp2 = Column(Float, nullable=True)
    profit = Column(Float, nullable=True)               # realized P/L, set on close events
    balance = Column(Float, nullable=True)
    equity = Column(Float, nullable=True)
    comment = Column(String, nullable=True)
    received_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    telegram_message_id = Column(Integer, nullable=True)
    status = Column(_trade_event_status_type, nullable=False, default=TradeEventStatus.PENDING)
    error_message = Column(Text, nullable=True)
    latency_ms = Column(Integer, nullable=True)


class Signal(Base):
    __tablename__ = "signals"
    __table_args__ = (
        Index("ix_signals_status", "status"),
    )

    id = Column(Integer, primary_key=True, autoincrement=True)
    signal_id = Column(String, unique=True, nullable=False, index=True)
    symbol = Column(String, nullable=False)
    direction = Column(String, nullable=False)
    entry = Column(Float, nullable=False)
    sl = Column(Float, nullable=False)
    tp1 = Column(Float, nullable=False)
    tp2 = Column(Float, nullable=False)
    confidence = Column(Integer, nullable=False)
    reasons = Column(JSON, nullable=False)
    timeframe = Column(String, nullable=False)
    received_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    telegram_message_id = Column(Integer, nullable=True)
    # Default to PENDING: the route inserts a PENDING row first to reserve
    # the signal_id, then resolves it to ACTIVE/FAILED after the Telegram call.
    # This Python-level default matches that intent; the migration's
    # server_default is aligned to "pending" for the same reason.
    status = Column(_signal_status_type, nullable=False, default=SignalStatus.PENDING)
    error_message = Column(Text, nullable=True)
    latency_ms = Column(Integer, nullable=True)
    # --- v2.9 additions -----------------------------------------------
    lifecycle_status = Column(_signal_lifecycle_status_type, nullable=False, default=SignalLifecycleStatus.VALID)
    lifecycle_reason = Column(String, nullable=True)          # human-readable, mirrors NewsFilter/chase-filter style reasons
    lifecycle_updated_at = Column(DateTime(timezone=True), nullable=True)
    expires_at = Column(DateTime(timezone=True), nullable=True)  # EA-computed hard expiry; NULL = no expiry set
    # Freeform diagnostics that don't warrant their own column yet: sweep
    # grade, BOS strength, decay %, chase distance, news risk tier,
    # calibrated probability + sample size, pip distances. Kept as JSON
    # (not `reasons`, which is a fixed list[str] the validator/formatter
    # already depend on) so the schema can absorb new EA-side fields
    # without a migration each time. NULL for signals from an EA build
    # older than v2.9 — formatter.py must degrade gracefully, not assume
    # this is always populated.
    extra = Column(JSON, nullable=True)
    # --- v2.11 additions: promoted out of `extra` into first-class,
    # indexed columns because these are exactly what the two-track
    # metrics engine (tools/metrics_engine.py) groups and filters by.
    # Anything left buried in a JSON blob can't be queried without a
    # per-key JSON extraction on every report run — regime/session/sweep
    # grade/HTF alignment/weight version are the tag set the whole
    # tagging system exists to make queryable, so they get real columns.
    # All nullable: a pre-v2.11 EA build still posts a valid Signal, it
    # just won't be tag-breakdown-able until it's rebuilt against the new
    # SignalPublisher payload.
    regime = Column(String, nullable=True, index=True)          # ENUM_VOL_REGIME as string: Low/Normal/High/Undefined
    session = Column(String, nullable=True, index=True)         # ENUM_TRADING_SESSION as string
    sweep_grade = Column(String, nullable=True, index=True)     # ENUM_SWEEP_GRADE as string: None/C/B/A
    htf_ob_aligned = Column(sa.Boolean, nullable=True)           # SetupReasons.htf_ob_confluence at signal time
    weight_version = Column(String, nullable=True, index=True)  # InpWeightSetVersion — which scoring weight set produced this signal


# One row per RESOLVED setup from the EA's simulated OutcomeTracker (see
# EA/includes/Trading/OutcomeTracker.mqh) — win/loss/scratch/no_fill,
# realized R, and the full tag context at signal time, denormalized onto
# this row rather than requiring a join back to Signal. This is the
# table the two-track metrics engine (tools/metrics_engine.py) actually
# queries: coverage metrics group by tag regardless of outcome
# (including no_fill rows), expectancy metrics filter to resolved rows
# and break down realized R by every tag. Before this table existed,
# this data only ever reached a local CSV on the MT5 terminal
# (SignalLogger::LogOutcome) and never touched Postgres — "why did we
# lose" was a CSV grep, not a query.
class SignalOutcome(Base):
    __tablename__ = "signal_outcomes"
    __table_args__ = (
        Index("ix_signal_outcomes_regime_session", "regime", "session"),
    )

    id = Column(Integer, primary_key=True, autoincrement=True)
    # Same convention as Signal.signal_id (f"{symbol}_{dir}_{epoch}") —
    # one outcome per signal, enforced unique so a duplicate POST (retry
    # after a dropped ack) upserts instead of double-counting.
    signal_id = Column(String, unique=True, nullable=False, index=True)
    symbol = Column(String, nullable=False)
    direction = Column(String, nullable=False)
    # "win" | "loss" | "scratch" | "no_fill" | "ambiguous" — no_fill and
    # ambiguous are NOT dropped: a signal that never got a chance to
    # prove itself is exactly what the coverage-metrics half of step 2
    # needs (missed-long rate, directional bias) even though it
    # contributes nothing to the expectancy half.
    outcome = Column(String, nullable=False, index=True)
    realized_r = Column(Float, nullable=True)     # NULL for no_fill/ambiguous
    mfe_r = Column(Float, nullable=True)
    mae_r = Column(Float, nullable=True)
    bars_held = Column(Integer, nullable=True)
    bars_to_fill = Column(Integer, nullable=True)
    filled = Column(sa.Boolean, nullable=False, default=False)
    # --- tag context, snapshotted at signal time (copied from Signal,
    # not joined, so a report never depends on Signal retention policy) ---
    regime = Column(String, nullable=True, index=True)
    session = Column(String, nullable=True, index=True)
    sweep_grade = Column(String, nullable=True, index=True)
    htf_ob_aligned = Column(sa.Boolean, nullable=True)
    weight_version = Column(String, nullable=True, index=True)
    confidence_at_signal = Column(Float, nullable=True)
    confidence_decayed = Column(Float, nullable=True)
    decay_bars = Column(Integer, nullable=True)
    received_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))


# v2.11 step 6. One row per scheduled recalibration cycle's metrics_engine
# report — the Postgres replacement for tools/cycle_store.py's JSON files.
# report_json is the EXACT dict tools/metrics_engine.py's compute_report()
# produces; gating.py's decide() doesn't care whether a cycle came from a
# file or this table (see gating.py:load_cycles_from_db), which is what
# keeps the synthetic-rehearsal tooling and the real scheduled pipeline
# running the same decision logic.
class CalibrationCycle(Base):
    __tablename__ = "calibration_cycles"

    id = Column(Integer, primary_key=True, autoincrement=True)
    cycle_id = Column(String, unique=True, nullable=False, index=True)
    # "live" (produced by the scheduled POST /admin/run-cycle) or
    # "synthetic" (never written here — synthetic cycles stay local
    # JSON-file-only via tools/generate_synthetic_cycles.py, precisely so
    # a rehearsal cycle can never end up in the table a real promotion
    # decision reads from).
    source = Column(String, nullable=False, index=True, default="live")
    generated_at = Column(DateTime(timezone=True), nullable=False)
    report_json = Column(JSON, nullable=False)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))


# v2.11 step 5/6. One row per gating.py decision that was either a
# promotion candidate (requires the human tap) or an auto-rollback
# (executes immediately, logged here for the audit trail — never
# silently reconciled, per the spec).
class PromotionRequest(Base):
    __tablename__ = "promotion_requests"

    id = Column(Integer, primary_key=True, autoincrement=True)
    weight_version = Column(String, nullable=False, index=True)
    action = Column(String, nullable=False)  # "PROMOTE" | "ROLLBACK"
    decision_json = Column(JSON, nullable=False)  # gating.Decision.to_dict()
    # "pending" (awaiting a tap) | "approved" | "rejected" | "auto_executed"
    # (ROLLBACK only — never waits for a tap, per the spec)
    status = Column(String, nullable=False, default="pending", index=True)
    telegram_message_id = Column(Integer, nullable=True)  # lets the callback edit the original card
    requested_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    decided_at = Column(DateTime(timezone=True), nullable=True)
    decided_by = Column(String, nullable=True)  # Telegram user id of whoever tapped


# v2.11 step 5. An approval log, not a live "which weights are running"
# registry — this table does NOT assign a weight_version to a symbol or
# push anything to the EA. A weight_version landing here means a human
# tapped Approve on it; whatever eventually reads this to decide what
# the EA should run next (the config-sync endpoint discussed but not yet
# built) is separate work. See PromotionRequest for the request/response
# trail this is derived from.
class ApprovedWeightVersion(Base):
    __tablename__ = "approved_weight_versions"

    id = Column(Integer, primary_key=True, autoincrement=True)
    weight_version = Column(String, unique=True, nullable=False, index=True)
    approved_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    approved_by = Column(String, nullable=True)
    promotion_request_id = Column(Integer, nullable=True)
