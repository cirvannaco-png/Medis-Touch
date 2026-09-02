"""
Full latency chain telemetry.

Handbook section 13. T0-T7 as specified, plus the derived latencies.
Persist decision_id/signal_id, symbol, strategy, T0-T7, derived
latencies, outcome and failure reason — the handbook is explicit that
"optimizing only broker acknowledgement latency is insufficient", so
this captures every stage, not just BrokerLatency.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime


@dataclass
class LatencyTrace:
    decision_id: str
    signal_id: str | None
    symbol: str
    strategy: str

    t0_market_condition_valid: datetime | None = None
    t1_detector_recognized: datetime | None = None
    t2_confidence_calculated: datetime | None = None
    t3_decision_generated: datetime | None = None
    t4_risk_calculated: datetime | None = None
    t5_order_submitted: datetime | None = None
    t6_broker_acknowledged: datetime | None = None
    t7_actual_fill: datetime | None = None

    outcome: str | None = None
    failure_reason: str | None = None

    _timestamps: dict[str, datetime] = field(default_factory=dict, repr=False)

    def mark(self, stage: str, at: datetime) -> None:
        """stage in {'t0'..'t7'} — sets the corresponding field and
        records it for delta calculation, so callers can just do
        `trace.mark('t3', utcnow())` from wherever that stage happens in
        the pipeline without needing to know the attribute name.
        """
        attr = {
            "t0": "t0_market_condition_valid",
            "t1": "t1_detector_recognized",
            "t2": "t2_confidence_calculated",
            "t3": "t3_decision_generated",
            "t4": "t4_risk_calculated",
            "t5": "t5_order_submitted",
            "t6": "t6_broker_acknowledged",
            "t7": "t7_actual_fill",
        }[stage]
        setattr(self, attr, at)
        self._timestamps[stage] = at

    def _delta_ms(self, a: str, b: str) -> float | None:
        ta, tb = self._timestamps.get(a), self._timestamps.get(b)
        if ta is None or tb is None:
            return None
        return (tb - ta).total_seconds() * 1000.0

    @property
    def detection_latency_ms(self) -> float | None:
        return self._delta_ms("t0", "t1")

    @property
    def decision_latency_ms(self) -> float | None:
        return self._delta_ms("t1", "t3")

    @property
    def risk_latency_ms(self) -> float | None:
        return self._delta_ms("t3", "t4")

    @property
    def submission_latency_ms(self) -> float | None:
        return self._delta_ms("t4", "t5")

    @property
    def broker_latency_ms(self) -> float | None:
        return self._delta_ms("t5", "t6")

    @property
    def fill_latency_ms(self) -> float | None:
        return self._delta_ms("t5", "t7")

    @property
    def total_signal_to_fill_ms(self) -> float | None:
        return self._delta_ms("t0", "t7")

    def as_record(self) -> dict:
        """Flat dict ready for a telemetry sink / DB row."""
        return {
            "decision_id": self.decision_id,
            "signal_id": self.signal_id,
            "symbol": self.symbol,
            "strategy": self.strategy,
            "t0": self.t0_market_condition_valid,
            "t1": self.t1_detector_recognized,
            "t2": self.t2_confidence_calculated,
            "t3": self.t3_decision_generated,
            "t4": self.t4_risk_calculated,
            "t5": self.t5_order_submitted,
            "t6": self.t6_broker_acknowledged,
            "t7": self.t7_actual_fill,
            "detection_latency_ms": self.detection_latency_ms,
            "decision_latency_ms": self.decision_latency_ms,
            "risk_latency_ms": self.risk_latency_ms,
            "submission_latency_ms": self.submission_latency_ms,
            "broker_latency_ms": self.broker_latency_ms,
            "fill_latency_ms": self.fill_latency_ms,
            "total_signal_to_fill_ms": self.total_signal_to_fill_ms,
            "outcome": self.outcome,
            "failure_reason": self.failure_reason,
        }
