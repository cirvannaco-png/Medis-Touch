from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum


class Broker(StrEnum):
    EXNESS = "exness"
    PEPPERSTONE = "pepperstone"
    HFM = "hfm"
    IC_MARKETS = "ic_markets"
    XM = "xm"


@dataclass(frozen=True)
class BrokerProfile:
    broker: Broker
    mt5_supported: bool = True
    copy_trading_supported: bool = True


BROKER_PROFILES: dict[Broker, BrokerProfile] = {
    broker: BrokerProfile(broker=broker)
    for broker in Broker
}


def normalize_broker(value: str) -> Broker:
    normalized = value.strip().lower().replace("-", "_").replace(" ", "_")
    aliases = {
        "exness": Broker.EXNESS,
        "pepperstone": Broker.PEPPERSTONE,
        "pepperdine": Broker.PEPPERSTONE,
        "hfm": Broker.HFM,
        "hotforex": Broker.HFM,
        "icmarkets": Broker.IC_MARKETS,
        "ic_markets": Broker.IC_MARKETS,
        "xm": Broker.XM,
    }
    try:
        return aliases[normalized]
    except KeyError as exc:
        raise ValueError(f"Unsupported broker: {value}") from exc


def supported_brokers() -> tuple[str, ...]:
    return tuple(profile.broker.value for profile in BROKER_PROFILES.values())
