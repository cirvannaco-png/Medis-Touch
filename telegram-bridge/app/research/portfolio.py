"""Phase-3 portfolio coordinator: correlation, factors, normalized heat and atomic admission."""
from __future__ import annotations
from dataclasses import dataclass
from math import sqrt

@dataclass(frozen=True)
class PositionRisk:
    symbol: str
    direction: str
    risk_r: float
    volatility: float
    factor_exposure: dict[str, float]

@dataclass(frozen=True)
class PortfolioLimits:
    max_heat_r: float = 3.0
    max_directional_r: float = 2.0
    max_correlated_cluster_r: float = 2.0

class PortfolioCoordinator:
    def __init__(self, limits: PortfolioLimits = PortfolioLimits()):
        self.limits = limits
        self._reserved: dict[str, PositionRisk] = {}

    def normalized_heat(self) -> float:
        return sum(abs(p.risk_r) for p in self._reserved.values())

    def directional_exposure(self, direction: str) -> float:
        sign = 1 if direction.lower() in {"buy", "long"} else -1
        return sum(sign * (1 if p.direction.lower() in {"buy", "long"} else -1) * abs(p.risk_r) for p in self._reserved.values())

    def factor_exposure(self) -> dict[str, float]:
        out: dict[str, float] = {}
        for p in self._reserved.values():
            for k, v in p.factor_exposure.items():
                out[k] = out.get(k, 0.0) + v * abs(p.risk_r)
        return out

    def admit(self, request_id: str, position: PositionRisk, correlated_risk: float = 0.0) -> tuple[bool, str]:
        if request_id in self._reserved:
            return False, "duplicate reservation request"
        if self.normalized_heat() + abs(position.risk_r) > self.limits.max_heat_r:
            return False, "portfolio heat limit"
        if abs(self.directional_exposure(position.direction) + (abs(position.risk_r) if position.direction.lower() in {"buy", "long"} else -abs(position.risk_r))) > self.limits.max_directional_r:
            return False, "directional exposure limit"
        if correlated_risk + abs(position.risk_r) > self.limits.max_correlated_cluster_r:
            return False, "correlated cluster limit"
        self._reserved[request_id] = position
        return True, "reserved"

    def release(self, request_id: str) -> None:
        self._reserved.pop(request_id, None)

    def snapshot(self) -> dict:
        return {"heat_r": self.normalized_heat(), "factor_exposure": self.factor_exposure(), "reservations": len(self._reserved)}
