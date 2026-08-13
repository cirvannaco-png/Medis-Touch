//+------------------------------------------------------------------+
//|                                                   Core/Config.mqh |
//|                                            Medis Touch Indicator  |
//+------------------------------------------------------------------+
#property copyright "Medis Touch"
#property version   "2.00"

#ifndef CONFIG_MQH
#define CONFIG_MQH

// --- Enums ---
enum ENUM_TREND_STATE
  {
   TREND_BULL_STRONG,
   TREND_BULL,
   TREND_NEUTRAL,
   TREND_BEAR,
   TREND_BEAR_STRONG
  };

enum ENUM_FVG_DIR
  {
   FVG_BULL,
   FVG_BEAR
  };

enum ENUM_FVG_STATE
  {
   FVG_FRESH,
   FVG_TESTED,
   FVG_MITIGATED,
   FVG_INVALIDATED
  };

enum ENUM_LIQ_TYPE
  {
   LIQ_BUY_SIDE,
   LIQ_SELL_SIDE
  };

enum ENUM_BIAS
  {
   BIAS_BULLISH,
   BIAS_BEARISH,
   BIAS_NEUTRAL
  };

enum ENUM_SR_TYPE
  {
   SR_MAJOR_RESISTANCE,
   SR_MINOR_RESISTANCE,
   SR_MAJOR_SUPPORT,
   SR_MINOR_SUPPORT
  };

// --- v2.1 additions ---

// How OutcomeTracker resolves a bar that touches BOTH SL and a TP in the
// same bar (can't know from OHLC alone which was hit first without
// lower-timeframe data).
enum ENUM_FILL_POLICY
  {
   FILL_CONSERVATIVE,    // assume SL hit first (undercounts win rate, never overcounts it)
   FILL_OPTIMISTIC,      // assume TP hit first (overcounts win rate — for comparison only)
   FILL_NEAREST,         // whichever level is closer to the bar's open is assumed to hit first
   FILL_INTRABAR_REPLAY, // load M1 (or InpReplayTF) and step through it to find the real order; falls back to Ambiguous if the lower-TF data isn't available
   FILL_AMBIGUOUS        // don't guess — log/count it separately, excluded from win-rate
  };

enum ENUM_MARKET_PHASE
  {
   PHASE_UNDEFINED,     // not enough data / no clean range found
   PHASE_ACCUMULATION,  // compressed range, no directional resolution yet
   PHASE_MANIPULATION,  // liquidity sweep of the range just occurred
   PHASE_DISTRIBUTION   // displacement following the sweep — the only phase setups are allowed to fire in (when the phase gate is enabled)
  };

// v2.6 addition — CFibonacciEngine's classification of price relative to
// the active swing leg (see SmartMoney/FibonacciEngine.mqh). Discount =
// price has pulled back deep into the leg (favorable); Premium = still
// shallow / close to the impulse extreme (expensive).
enum ENUM_FIB_ZONE
  {
   FIB_ZONE_UNDEFINED,
   FIB_ZONE_DISCOUNT,
   FIB_ZONE_NEUTRAL,
   FIB_ZONE_PREMIUM
  };

// v2.6 addition — CValueAreaEngine's classification of price relative to
// the recent volume-profile Value Area (see SmartMoney/ValueAreaEngine.mqh).
enum ENUM_VALUE_AREA_ZONE
  {
   VA_ZONE_UNDEFINED,
   VA_ZONE_BELOW,     // discount — below the Value Area
   VA_ZONE_INSIDE,
   VA_ZONE_ABOVE      // premium — above the Value Area
  };

// v2.8 addition — HTF Order Block state (SmartMoney/OrderBlock.mqh).
enum ENUM_OB_STATE
  {
   OB_FRESH,        // never touched since formation
   OB_TESTED,       // price has returned into the zone at least once, held
   OB_MITIGATED     // price closed through the far edge — zone invalidated
  };

// v2.8 addition — ATR-percentile volatility regime (Analysis/VolatilityRegime.mqh).
// Distinct from CMarketPhase's binary range-compression check: this
// classifies the CURRENT bar's ATR against its own rolling distribution,
// independent of whether price is ranging or trending.
enum ENUM_VOL_REGIME
  {
   VOL_REGIME_UNDEFINED,
   VOL_REGIME_LOW,      // ATR sits in the bottom band of its recent range — thin, choppy, spread-risk-heavy
   VOL_REGIME_NORMAL,
   VOL_REGIME_HIGH       // ATR sits in the top band — news/expansion conditions, wider stops needed
  };

// v2.8 addition — Core/SessionFilter.mqh. Named windows, not just labels:
// used as an actual entry gate, not only a CSV column like the v2.1
// SignalLogger session tag.
enum ENUM_TRADING_SESSION
  {
   SESSION_DEAD,           // outside all configured windows (thin Sydney/Tokyo-only hours)
   SESSION_TOKYO,
   SESSION_LONDON,
   SESSION_NEWYORK,
   SESSION_LONDON_NY_OVERLAP
  };

struct ImpulseLeg
  {
   bool              valid;
   datetime          start_time;
   datetime          end_time;
   int               start_bar;    // older bar (larger series index)
   int               end_bar;      // newer bar (smaller series index)
   double            start_price;
   double            end_price;
   bool              bullish;
   double            strength;     // 0-1, ATR-distance + body-dominance blend
  };

// Result of validating one candidate setup against the inducement
// sequence: Impulse -> Internal pullback structure -> Internal liquidity
// sweep -> minor BOS -> (only then) a real entry. Scored per-component so
// Scoring.mqh and the dashboard can show WHY a setup did or didn't pass,
// not just a pass/fail bit.
struct InducementResult
  {
   bool              valid;              // true only if the sweep AND the confirming BOS both happened
   bool              impulseFound;
   bool              internalStructureFound;
   bool              sweepFound;
   bool              bosConfirmed;
   double            impulseScore;       // 0-15
   double            structureScore;     // 0-10
   double            sweepScore;         // 0-25
   double            bosScore;           // 0-20
   double            totalScore;         // sum of the above, 0-70 (FVG+HTF add the remaining 30 in Scoring.mqh)
   ImpulseLeg        leg;                // the impulse this result was built from (only meaningful if impulseFound)
   string            reason;             // plain-language explanation, mainly for the dashboard/log
  };

// One resolved outcome bucketed for honest win-rate reporting. Kept
// separate from PendingSetup (which is per-trade, transient) — this is
// the running aggregate COutcomeTracker exposes to the dashboard.
//
// v2.7: win/loss/scratch are now decided by NET REALIZED $ P&L (after
// commission, spread, and slippage), not by "which price level got
// touched." A trade that partial-closed for a profit and then had its
// runner stopped at breakeven is a net winner even though its final
// price-level event was "BreakEven_Hit" — the old SL/TP-label-based
// counting would have missed that entirely. Unsized trades (lots<=0,
// e.g. risk% didn't reach the broker's minimum lot) still resolve for
// price-level/CSV purposes but are excluded from every field below.
struct OutcomeStats
  {
   int               wins;         // net PnL > 0
   int               losses;       // net PnL < 0
   int               scratches;    // net PnL == 0 (e.g. stopped at breakeven, costs the only loss)
   int               ambiguous;    // FILL_AMBIGUOUS resolutions — excluded from $ stats entirely, not just win/loss
   double            netPnL;
   double            grossProfit;      // sum of positive-slice PnL only
   double            grossLoss;        // sum of |negative-slice PnL| (stored positive)
   double            totalCommission;
   double            totalSpreadCost;  // informational — already embedded in fill prices, not subtracted again
   double            totalSlippageCost;// informational — same caveat
   double            sumRMultiple;     // running sum of each resolved trade's net R (realizedPnL / (riskDist-in-$ for 1 lot)) — see COutcomeTracker for the exact formula
   int               resolvedCount;    // wins+losses+scratches — the sized, resolved population every ratio below divides by

   int               ExcludingAmbiguousTotal() const { return wins + losses; }
   double            WinRateExcludingAmbiguous() const
     {
      int t = wins + losses;
      return (t > 0) ? (100.0 * wins / t) : 0.0;
     }
   double            WinRateAmbiguousAsLoss() const
     {
      int t = wins + losses + ambiguous;
      return (t > 0) ? (100.0 * wins / t) : 0.0;
     }
   double            WinRateAmbiguousAsWin() const
     {
      int t = wins + losses + ambiguous;
      return (t > 0) ? (100.0 * (wins + ambiguous) / t) : 0.0;
     }
   // -1.0 is a sentinel for "infinite" (grossLoss == 0 but grossProfit > 0)
   // — callers display it as such rather than a real ratio.
   double            ProfitFactor() const
     {
      if(grossLoss > 0) return grossProfit / grossLoss;
      return (grossProfit > 0) ? -1.0 : 0.0;
     }
   double            ExpectancyPerTrade() const
     {
      return (resolvedCount > 0) ? netPnL / resolvedCount : 0.0;
     }
   double            AverageRMultiple() const
     {
      return (resolvedCount > 0) ? sumRMultiple / resolvedCount : 0.0;
     }
  };

// --- Data Structures ---
struct CandleData
  {
   datetime          time;
   double            open;
   double            high;
   double            low;
   double            close;
   long              tick_volume;
   double            atr;
  };

struct SwingPoint
  {
   datetime          time;
   double            price;
   bool              is_high;      // true = swing high, false = swing low
   int               bar_index;
   double            strength;     // 0-1
  };

struct BOSEvent
  {
   datetime          time;
   double            price;
   bool              is_bullish;
   double            strength;     // 0-1, derived from breakout distance + volume
   int               bar_index;
   string            label;
  };

// NOTE: previously nested privately inside CCHOCH — that made the type
// invisible to Visuals.mqh (compile error). Now a shared, top-level type.
struct CHOCHPoint
  {
   datetime          time;
   double            price;
   bool              bullish;      // true = bullish CHoCH (break above last LH)
   int               bar_index;
  };

struct FVGZone
  {
   datetime          time;
   double            top;
   double            bottom;
   ENUM_FVG_DIR      dir;
   ENUM_FVG_STATE    state;
   double            width;        // relative to ATR
   int               bar_index;
  };

// v2.8 addition — one HTF Order Block (SmartMoney/OrderBlock.mqh).
struct OrderBlockZone
  {
   datetime          time;
   double            top;
   double            bottom;
   ENUM_FVG_DIR      dir;          // reuse FVG_BULL/FVG_BEAR — same directional meaning
   ENUM_OB_STATE     state;
   double            displacement_atr;   // size of the displacement leg that created it, in ATR
   int               bar_index;
  };

struct LiquidityPool
  {
   double            price_top;
   double            price_bottom;
   ENUM_LIQ_TYPE     type;
   int               touches;
   bool              external;     // true = D1 high/low, false = internal equal highs/lows
   int               confirmed_at_shift; // audit #11 fix: the shift at which BOTH member swings were
                                          // actually confirmed — a sweep candle older than this (i.e.
                                          // shift > confirmed_at_shift) predates the pool and cannot
                                          // validly be tested against it. 0 for external pools, which
                                          // are handled with per-day dynamic lookups instead (see Liquidity.mqh).
  };

struct LiquidityEvent
  {
   datetime          time;
   double            price;
   ENUM_LIQ_TYPE     type;
   double            strength;     // 0-1, derived from wick penetration depth / ATR
   bool              swept;
   int               bar_index;
   bool              external;     // true = D1 high/low sweep, false = internal equal-highs/lows sweep (added for Inducement engine)
  };

struct SRZone
  {
   double            top;
   double            bottom;
   ENUM_SR_TYPE      type;
   int               touches;
   datetime          startTime;
  };

struct SetupReasons
  {
   bool              trend_aligned;      // HTF (or chart-TF if HTF disabled) trend supports direction
   bool              bos_confirmed;      // recent BOS/CHoCH in setup direction
   bool              liquidity_swept;    // recent opposing-side liquidity sweep supports direction
   bool              fresh_fvg;          // fresh/tested FVG in setup direction near price
   bool              sr_confluence;      // price sitting in a discount/premium zone (support/resistance confluence)
   bool              inducement_valid;   // impulse -> internal pullback -> internal sweep -> minor BOS sequence confirmed
   bool              premium_discount_ok;// buy below equilibrium / sell above equilibrium of the impulse range
   ENUM_MARKET_PHASE phase;              // market phase at setup creation (informational unless the phase gate is enabled)
   string            risk_warning;       // "" if none, else a plain-language nearby-opposition warning
   // --- v2.6: Volume + Fibonacci diagnostics (see SmartMoney/VolumeEngine.mqh,
   // SmartMoney/FibonacciEngine.mqh) — always populated for the dashboard/CSV,
   // but only GATE a setup to zero confidence if the corresponding
   // ConfigureVolumeFibonacci() flag is enabled (both default OFF; see the
   // discipline note in Analysis/Scoring.mqh).
   double            rvol;               // relative volume of the current BOS-TF bar
   bool              volume_confirmed;   // rvol >= the configured RVOL threshold
   ENUM_FIB_ZONE     fib_zone;           // Discount/Neutral/Premium relative to the active swing leg
   bool              fib_in_zone;        // price sits inside the configured pullback zone (default 50-61.8%)
   double            fib_nearest_level;  // price of the nearest of {38.2, 50, 61.8, 78.6}
   // --- v2.6: Value Area diagnostics (see SmartMoney/ValueAreaEngine.mqh) —
   // same "always populated, only gates if enabled" convention as above.
   bool              value_area_ok;      // LocationOK() for this setup's direction
   ENUM_VALUE_AREA_ZONE va_zone;         // Below/Inside/Above the recent Value Area
   double            va_poc;             // Point of Control
   double            va_high;            // Value Area High
   double            va_low;             // Value Area Low
   // --- v2.8: HTF Order Block, volatility regime, session diagnostics —
   // same "always populated, only gates if enabled" convention.
   bool              htf_ob_confluence;  // price sits inside a fresh/tested HTF OB in setup direction
   ENUM_OB_STATE     htf_ob_state;
   ENUM_VOL_REGIME   vol_regime;         // ATR-percentile regime at setup creation
   ENUM_TRADING_SESSION session;         // named session window at setup creation
   bool              session_ok;         // session gate result (always computed; only blocks if enabled)
  };

struct TradeSetup
  {
   ENUM_ORDER_TYPE   type;         // ORDER_TYPE_BUY or ORDER_TYPE_SELL
   double            entry_top;
   double            entry_bottom;
   double            stop_loss;
   double            tp1;
   double            tp2;
   double            final_tp;
   double            confidence;
   datetime          creation_time;
   bool              active;
   SetupReasons      reasons;
  };

// Single source of truth for "what price does this setup actually fill
// at". entry_top/entry_bottom describe a zone, not a price — every
// caller that needs one number (risk validation, lot sizing, order
// placement) must resolve it the same way, or the gate that approves a
// trade and the trade that gets placed can silently disagree. Resolves
// to the near/worse edge of the zone: entry_top for a buy, entry_bottom
// for a sell — matching OrderManager::Submit()'s fill price.
double ResolveExecutionEntry(const TradeSetup &setup)
  {
   return (setup.type == ORDER_TYPE_BUY) ? setup.entry_top : setup.entry_bottom;
  }

// --- Gate fail-open/fail-closed convention (v2.6 filters) -----------
// Two kinds of gate live in SmartMoney/, and "no data yet" means
// something different for each:
//   LOCATION filters (CPremiumDiscount::OK, CValueAreaEngine::LocationOK)
//   ask "is price on the wrong side of a range?" With no range, there's
//   no wrong side — FAIL-OPEN is the only coherent answer.
//   CONFIRMATION filters (CVolumeEngine::ConfirmsBreakout,
//   CFibonacciEngine::FindLeg) ask "does this bar/leg actually confirm
//   the setup?" With no swings/no ATR there's nothing to confirm, so the
//   claim is unverifiable — FAIL-CLOSED is the only coherent answer.
// New gates should be classified against this rule before deciding how
// they behave on missing data — not decided ad hoc per filter.
// ----------------------------------------------------------------------

// Tracks one generated setup across ticks until it resolves (SL, Final
// TP, or timeout). Lives here (not in OutcomeTracker.mqh) so it's a
// complete type wherever it's referenced — including inside
// SignalLogger::LogOutcome(), which is compiled before OutcomeTracker.mqh
// is ever included.
struct PendingSetup
  {
   TradeSetup        setup;
   double            entryRef;
   double            riskDist;      // |entryRef - SL|, used for R-multiples
   double            mfePrice;      // best price reached in the setup's favor (post-fill only)
   double            maePrice;      // worst price reached against the setup (post-fill only)
   bool              tp1Hit;
   bool              tp2Hit;
   int               barsElapsed;
   datetime          lastBarTime;
   // --- Fill confirmation ---
   // A setup is "generated" the instant the zone appears, but nothing is
   // actually tradeable until price returns to entryRef. filled/fillTime/
   // barsToFill record when (if ever) that happened, so MFE/MAE and win-
   // rate are measured against a real fill instead of a hoped-for one.
   bool              filled;
   datetime          fillTime;
   int               barsToFill;
   // --- Fill-policy bookkeeping (same-bar SL+TP resolution) ---
   // true only when a bar's range touched BOTH the stop and the final TP
   // on the same bar, i.e. the true fill order isn't knowable from OHLC
   // alone. Set by COutcomeTracker.Update() right before it resolves the
   // setup, so SignalLogger can log which policy decided the outcome.
   bool              sameBarCollision;
   // --- v2.7: Trade Simulator additions ---
   // Position sizing and fill economics. sizingEntryPrice deliberately
   // matches the live EA's CalculateLotSize() convention (entry_top for
   // buy, entry_bottom for sell — the FAR edge of the zone, i.e. the
   // conservative price the live code actually sizes risk against) —
   // NOT entryRef above (the NEAR edge, used only for fill confirmation).
   // Keeping these separate preserves the existing fill-confirmation
   // behavior unchanged while making position sizing match live exactly.
   double            sizingEntryPrice;
   double            mgmtRiskDist;    // |sizingEntryPrice - original stop_loss| — the R-multiple basis for breakeven/partial triggers, matching CPositionManager::RMultiple()
   double            lots;            // 0 if risk% didn't clear the broker minimum (even with override) or sizing was otherwise impossible — trade still resolves for price-level/CSV purposes, just excluded from every $ stat
   double            entryFillPrice;  // sizingEntryPrice adjusted for simulated spread+slippage
   double            currentSL;       // the OPERATIVE stop this bar — starts at setup.stop_loss, moves to breakeven then trails, exactly mirroring CPositionManager
   bool              beDone;          // breakeven has been applied
   bool              partialDone;     // the single partial-close (mirrors live CPositionManager — ONE partial at partialAtR, not a partial per TP level) has fired
   double            remainingLots;   // lots still open; == lots until the partial fires, then lots*(1-partialFraction)
   double            realizedPnL;     // running net $ (after commission, spread, slippage) from every closed slice so far
   double            totalCommission;
   double            totalSpreadCost;   // informational breakdown — cost is already embedded in fill prices, this is for reporting only
   double            totalSlippageCost; // informational breakdown — same caveat
  };

#endif
//+------------------------------------------------------------------+
