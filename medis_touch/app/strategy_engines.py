"""
Strategy setup engine interfaces.

Handbook section 2 ("Responsibility Boundary"):
    Setup engines answer only:
      1. Where is entry?
      2. Where is invalidation?
      3. Where is SL?
      4. Where are TP1/TP2/final TP?
      5. What invalidates the setup?
    Common infrastructure handles: Risk -> Portfolio -> Execution ->
    Recovery -> Outcome -> Calibration.
    The Risk Engine must not manufacture strategy-specific trade theses.

This module defines the CONTRACT every setup engine must satisfy
(section 4: "Three Independent Setup Engines" + section 5: "SMC Setup
Generation") so that every engine — however different its internal
market-reading logic — emits the same normalized `TradeSetup`.

WHAT'S DELIBERATELY NOT HERE: breakout detection, mean-reversion
extension/rejection detection, key-level identification, and SMC
structure analysis. Those require your actual market data feed, bar
history, and the specific indicators your EA already computes — I
don't have visibility into your existing MQL5/Python detection code,
and faking that logic would be worse than not having it: a wrong
breakout detector that "looks right" is more dangerous than an honest
NotImplementedError. Fill in `_detect(...)` in each subclass against
your real indicators.
"""

from __future__ import annotations

import abc
from datetime import datetime

from .models import TradeSetup


class MarketContext(abc.ABC):
    """Whatever bar/tick/indicator snapshot your engines actually need.

    Left abstract on purpose — define the concrete shape (OHLCV window,
    ATR, structure levels, session info, etc.) to match what your
    detectors already consume.
    """


class SetupEngine(abc.ABC):
    """Base contract for all four setup engines."""

    name: str

    @abc.abstractmethod
    def detect(self, ctx: MarketContext) -> bool:
        """Step 1 of the pipeline: is there a candidate setup at all?"""

    @abc.abstractmethod
    def build_setup(self, ctx: MarketContext, now: datetime) -> TradeSetup | None:
        """Steps: create entry -> define invalidation -> calc SL ->
        calc TP1/TP2/final -> return complete TradeSetup, or None if
        confirmation fails after detect() returned True.

        MUST set `setup.invalidation` and `setup.stop_loss` as distinct
        values per the section 3 invariant. Do not derive one from the
        other implicitly.
        """

    def generate(self, ctx: MarketContext, now: datetime) -> TradeSetup | None:
        """Template method — engines should not need to override this."""
        if not self.detect(ctx):
            return None
        return self.build_setup(ctx, now)


class MomentumBreakoutEngine(SetupEngine):
    """Detect breakout -> confirm continuation/retest -> entry.

    Invalidate on: failed breakout, opposing structure, lost momentum,
    stale setup, or regime contradiction (per handbook section 4).
    """

    name = "momentum_breakout"

    def detect(self, ctx: MarketContext) -> bool:
        raise NotImplementedError(
            "Wire this to your real breakout detector (structure break "
            "+ continuation/retest confirmation)."
        )

    def build_setup(self, ctx: MarketContext, now: datetime) -> TradeSetup | None:
        raise NotImplementedError


class MeanReversionEngine(SetupEngine):
    """Detect extension -> confirm rejection -> entry.

    Invalidate on: acceptance outside value, strong opposing trend,
    excessive volatility, failed rejection, or staleness.
    """

    name = "mean_reversion"

    def detect(self, ctx: MarketContext) -> bool:
        raise NotImplementedError(
            "Wire this to your real extension/rejection detector "
            "(e.g. distance from value area + rejection candle/volume)."
        )

    def build_setup(self, ctx: MarketContext, now: datetime) -> TradeSetup | None:
        raise NotImplementedError


class KeyLevelReactionEngine(SetupEngine):
    """Identify significant level -> confirm reaction/rejection/retest.

    Invalidate on: level failure/acceptance, absent reaction, structural
    contradiction, or staleness.
    """

    name = "key_level_reaction"

    def detect(self, ctx: MarketContext) -> bool:
        raise NotImplementedError(
            "Wire this to your real key-level identification "
            "(S/R, swing highs/lows, prior day/week levels, etc.)."
        )

    def build_setup(self, ctx: MarketContext, now: datetime) -> TradeSetup | None:
        raise NotImplementedError


class SMCEngine(SetupEngine):
    """Smart Money Concepts setup generation (handbook section 5).

    Critical rule, quoted directly: structural thesis invalidation must
    remain distinct from ATR/execution buffers used for the protective
    stop:

        setup.invalidation = structural_invalidation
        setup.stop_loss = protective_stop_with_execution_buffer

    This is the single most common bug in SMC implementations — collapsing
    the order block/liquidity-sweep invalidation level into the same
    number as the stop. Keep them separate all the way through.
    """

    name = "smc"

    def detect(self, ctx: MarketContext) -> bool:
        raise NotImplementedError(
            "Wire this to your real SMC structure engine (order blocks, "
            "liquidity sweeps, BOS/CHoCH, FVGs — whatever your existing "
            "implementation already computes)."
        )

    def build_setup(self, ctx: MarketContext, now: datetime) -> TradeSetup | None:
        raise NotImplementedError


ALL_ENGINES: tuple[type[SetupEngine], ...] = (
    MomentumBreakoutEngine,
    MeanReversionEngine,
    KeyLevelReactionEngine,
    SMCEngine,
)
