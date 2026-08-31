//+------------------------------------------------------------------+
//|                                                   Core/Config.mqh |
//|                                            Medis Touch Indicator  |
//+------------------------------------------------------------------+
#property copyright "Medis Touch"
#property version   "2.00"

#ifndef CONFIG_MQH
#define CONFIG_MQH

#include "NewsFilter.mqh" // for ENUM_NEWS_RISK, used by SetupReasons (v2.9)

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

// v2.12 addition — Regime/RegimeDetector.mqh. Combines the trend read
// (Analysis/TrendEngine.mqh), the volatility-percentile read
// (Analysis/VolatilityRegime.mqh) and the range-compression read
// (SmartMoney/MarketPhase.mqh) into one classification. DIAGNOSTIC ONLY —
// see Strategies/MomentumBreakout.mqh's header comment for why nothing
// downstream of this consumes it yet.
enum ENUM_MARKET_REGIME
  {
   REGIME_UNDEFINED,    // any of trend/volatility/phase is itself undefined — fail closed, same convention as VOL_REGIME_UNDEFINED
   REGIME_TRENDING,     // confirmed directional structure (BOS-backed higher-high/higher-low or the bearish mirror) in normal-or-expanding volatility
   REGIME_RANGING,      // compressed range (CMarketPhase ACCUMULATION) with no confirmed directional structure
   REGIME_TRANSITION    // neither of the above cleanly applies — a recent sweep/displacement (MANIPULATION/DISTRIBUTION) or a weak, BOS-unconfirmed trend read
  };

// v2.12 addition — Strategies/MomentumBreakout.mqh's classification of
// the most recent BOS event. See that file's header comment for the
// definitions; this only names them for SetupReasons/CSV use.
enum ENUM_BREAKOUT_CLASS
  {
   BREAKOUT_NONE,        // no BOS within the configured recency window
   BREAKOUT_EXPANSION,   // strong displacement + volume, still within its expected follow-through window
   BREAKOUT_LIQUIDITY,   // the BOS coincides with a liquidity sweep (see SmartMoney/Liquidity.mqh) — overlaps the SMC engine by design, see file header
   BREAKOUT_FAILED,      // price has since closed back on the wrong side of the broken level
   BREAKOUT_EXHAUSTION   // displacement occurred, but only after price was already extended far beyond the break — chase risk, not continuation
  };

// v2.13 addition — Strategies/MeanReversion.mqh's classification of a
// fade setup. See that file's header comment for the full definitions.
enum ENUM_REVERSION_CLASS
  {
   REVERSION_NONE,             // neither a value-area stretch nor an SR-zone touch qualified
   REVERSION_VALUE_FADE,       // price stretched beyond the value area edge, with rejection/sweep confirmation — the stronger of the two paths
   REVERSION_LEVEL_REJECTION,  // rejected at a plain SR zone without value-area stretch — the weaker path
   REVERSION_TREND_CONFLICT    // a fade setup exists, but a recent strong opposing BOS says the move it's fading is still structurally confirmed — the doc's explicit "do not fight a strong trend" case
  };

// v2.14 addition — Strategies/KeyLevelReaction.mqh's identification of
// which kind of level price reacted to. See that file's header comment
// for the reuse rationale behind each source.
enum ENUM_KEYLEVEL_SOURCE
  {
   LEVEL_NONE,            // no level within the configured search range
   LEVEL_SR,              // CSupportResistance zone
   LEVEL_ORDER_BLOCK,     // COrderBlock demand/supply zone
   LEVEL_VALUE_AREA,      // CValueAreaEngine VAH/VAL
   LEVEL_LIQUIDITY_POOL   // CLiquidity external (D1 high/low) sweep — the doc's "previous day high/low"
  };

// v2.14 addition — Strategies/KeyLevelReaction.mqh's classification of
// what price did at that level. See that file's header comment for the
// full definitions and the honest note on why reaction_score is a fixed
// per-classification weight rather than a computed composite.
enum ENUM_KEYLEVEL_REACTION
  {
   REACTION_NONE,          // a level was found, but no pattern below fit cleanly
   REACTION_REJECTION,     // touched the level, closed back on the hold side with a rejection wick
   REACTION_BREAK,         // most recent close only is on the far side — fresh, unconfirmed
   REACTION_RETEST,        // broke earlier in the window, has come back to the level without re-crossing
   REACTION_FAILED_BREAK,  // broke earlier in the window, then closed back on the hold side
   REACTION_ACCEPTANCE,    // two or more recent closes on the far side — the level has flipped role
   REACTION_ABSORPTION     // repeated touches, no break, no strong rejection — testing without resolving
  };

// v2.15 addition — Strategies/StrategySelector.mqh's read of which
// strategy's diagnostic reading was strongest for the current regime.
// See that file's header comment for the selection rule. THIS IS STILL
// DIAGNOSTIC ONLY — see the file header for why this enum existing does
// not mean strategy selection is live.
enum ENUM_SELECTED_STRATEGY
  {
   STRATEGY_NONE,               // regime undefined, or no candidate cleared the minimum score — no selection made
   STRATEGY_SMC,                // the baseline SMC engine's own confidence was the best (or only) candidate — this is what's actually live
   STRATEGY_MOMENTUM_BREAKOUT,  // TRENDING regime, momentum/breakout score beat SMC confidence
   STRATEGY_MEAN_REVERSION,     // RANGING regime, reversion score beat SMC confidence (and wasn't vetoed by REVERSION_TREND_CONFLICT)
   STRATEGY_KEY_LEVEL           // TRANSITION regime, key-level reaction score beat SMC confidence
  };

// v2.9 addition — Inducement.mqh's sweep-quality classification. A
// boolean sweepFound treats a 1-tick liquidity poke and a violent
// displacement-sweep-rejection identically; this doesn't. See
// CInducement::GradeSweep() for the scoring components.
enum ENUM_SWEEP_GRADE
  {
   SWEEP_GRADE_NONE,   // no sweep (Validate() already returns early in this case)
   SWEEP_GRADE_C,      // technically valid, weak: shallow/deep penetration, poor reclaim, no follow-through
   SWEEP_GRADE_B,      // valid sweep, decent rejection, missing one of the A-grade components
   SWEEP_GRADE_A       // strong reclaim + sensible penetration depth + immediate displacement follow-through
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

   // --- v2.9 additions ---------------------------------------------
   // sweepScore/bosScore above are now WEIGHTED by these rather than
   // being flat 25/20-or-0 — see CInducement::Validate(). Kept as
   // separate fields (rather than silently folded into totalScore only)
   // so the dashboard/CSV can show WHY a setup scored what it did.
   ENUM_SWEEP_GRADE  sweepGrade;         // A/B/C — see ENUM_SWEEP_GRADE
   double            sweepGradeScore;    // 0-1 continuous form GradeSweep() actually computed
   double            bosStrength;        // 0-1: break-distance(ATR) + body-ratio blend, replaces the old binary bosConfirmed-only read
   int               barsSinceSweep;     // series-index (bars ago) of the sweep bar, i.e. "how stale is this setup"
   int               barsSinceBOS;       // series-index of the confirming BOS close
   double            timeDecay;          // 0-1 multiplier from barsSinceBOS — see CInducement::TimeDecay()
   double            bosClosePrice;      // close price of the bar that confirmed BOS — used by Scoring.mqh's chase filter
   int               bosBarIndex;        // == barsSinceBOS, kept as an explicit index for clarity at call sites; -1 if no BOS yet
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
   // --- v2.9 diagnostics — always populated, same "informational unless
   // the gate is enabled" convention as the v2.6/v2.8 blocks above.
   ENUM_SWEEP_GRADE  sweep_grade;
   double            bos_strength;
   double            time_decay;
   double            chase_dist_atr;     // (price - BOS close) / ATR in the trade direction; negative/zero = not chasing
   bool              chase_ok;           // chase_dist_atr <= the configured max (always computed; only blocks if enabled)
   // v2.9 — news-aware soft scoring diagnostics (distinct from the EA-level
   // hard IsLocked() block, which still fully prevents entries near an
   // event; this is the WIDER warning-tier read Scoring.mqh applies as a
   // soft confidence discount). See CScoringEngine::ConfigureNewsAwareness().
   ENUM_NEWS_RISK    news_risk;
   string            news_label;
   int               news_minutes_to_event;
   // --- v2.10 confidence diagnostics - contradiction / environment /
   // execution. DIAGNOSTIC ONLY. Always populated, never consulted:
   // nothing here feeds CalculateConfidence()'s return value and nothing
   // here gates a trade, exactly like the v2.6/v2.8/v2.9 blocks above on
   // the day they landed. They exist so the offline retraining pipeline
   // (tools/medistouch_retrain.py) accumulates real (signal, outcome)
   // pairs for the multiplicative model BEFORE any of it is allowed to
   // touch live confidence. Promote only after an out-of-sample
   // comparison says it beats the additive model.
   double            contradiction_penalty;  // 0-1: degree of active HTF/LTF/regime/location conflict (0 = nothing contradicts)
   double            env_score;              // 0-1: market-suitability component (regime, session, news)
   double            exec_score;             // 0-1: entry-quality component (sweep grade, BOS strength, freshness, chase)
   double            env_exec_confidence;    // diagnostic alt score: confidence * env_score * exec_score * (1 - contradiction_penalty)
   // --- v2.12 strategy diagnostics - regime classification + the
   // Momentum/Breakout engine's read. DIAGNOSTIC ONLY, same convention as
   // the v2.10 block above: always populated, never consulted. Nothing
   // here feeds CalculateConfidence(), CDecisionEngine, or order sizing.
   // This is step one of the multi-strategy architecture (see
   // Regime/RegimeDetector.mqh and Strategies/MomentumBreakout.mqh) —
   // Mean Reversion and the Key-Level Price Action engine are the next
   // two modules, not yet built; see docs/CHANGELOG.md v2.12 entry.
   ENUM_MARKET_REGIME   regime;              // regime read at setup creation
   double               momentum_score;      // 0-100: directional persistence + BOS strength composite, see MomentumBreakout.mqh
   double               breakout_score;      // 0-100: quality of the most recent BOS as a breakout, independent of momentum_score
   ENUM_BREAKOUT_CLASS  breakout_class;      // classification of that same BOS event
   // --- v2.13 strategy diagnostics - Mean Reversion. Same DIAGNOSTIC
   // ONLY convention as the block above. See Strategies/MeanReversion.mqh.
   double               reversion_score;     // 0-100: value-area-stretch/SR-rejection/sweep/volatility composite, see MeanReversion.mqh
   ENUM_REVERSION_CLASS reversion_class;     // classification of that read, including the trend-conflict override
   // --- v2.14 strategy diagnostics - Key-Level Reaction. Same
   // DIAGNOSTIC ONLY convention. See Strategies/KeyLevelReaction.mqh.
   ENUM_KEYLEVEL_SOURCE   keylevel_source;   // which kind of level was nearest
   ENUM_KEYLEVEL_REACTION keylevel_reaction; // what price did there
   double                 keylevel_score;    // fixed per-classification conviction weight, NOT a computed composite — see file header
   // --- v2.15 strategy diagnostics - Strategy Selection. STILL
   // DIAGNOSTIC ONLY: this field records what the selector WOULD have
   // picked. It is never read by CalculateConfidence(), CDecisionEngine,
   // order sizing, or setup.confidence itself. See
   // Strategies/StrategySelector.mqh for the full rationale, including
   // why this class exists specifically to avoid the "total=115, BUY"
   // failure mode of blending every score into one number.
   ENUM_SELECTED_STRATEGY selected_strategy;       // which strategy's read was strongest for this regime
   double                 selected_strategy_score;  // that strategy's own score, on its own scale (0-100 for all five candidates)
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
   // v2.9: populated by the EA right after g_tracker.GetCalibratedProbability()
   // is called on the chosen setup (see MedisTouch_v2.8.mq5) — NOT set by
   // the scoring engine itself, since calibration data lives in
   // COutcomeTracker, not Scoring.mqh. calibration_sample==0 means "no
   // calibration data for this bucket yet"; always check
   // calibration_has_enough_data before treating calibrated_probability
   // as meaningful (see CalibrationEngine.mqh).
   double            calibrated_probability;   // 0-100, empirical win rate for this confidence bucket
   int               calibration_sample;
   bool              calibration_has_enough_data;
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
   // --- v2.10 confidence decay (DIAGNOSTIC ONLY) ---
   // A setup's confidence was true of the bar that produced it. The longer
   // it sits unfilled, the less of that evidence still holds.
   // confidenceDecayed records what the score would be under an
   // exponential half-life decay applied per unfilled bar; decayBars
   // records how many bars of decay were applied. Nothing reads these to
   // cancel, re-rank, or re-size a setup - they are logged so the
   // retraining pipeline can measure whether staleness actually predicts
   // worse outcomes before it is allowed to act on one.
   double            confidenceAtSignal; // snapshot of setup.confidence at AddSetup() time
   double            confidenceDecayed;  // confidenceAtSignal * decay(decayBars); frozen once filled
   int               decayBars;          // unfilled bars the decay was applied over
   // --- v2.11 ---
   // The TradeDecisionRecord.decision_id this setup was ultimately routed
   // through — same value CSignalPublisher::SignalIdFor() turns into
   // "MT#<id>", which is the signal_id a Signal row (if any) was created
   // under. AddSetup() is called for every non-ignored setup regardless of
   // what the router later decides (see MedisTouch_v2.8.mq5), but a
   // decision_id only exists once CDecisionRouter::Decide() has run — so
   // this defaults to -1 ("no decision minted yet / not linkable") and is
   // set explicitly by the caller right after Decide() returns, BEFORE
   // AddSetup() is called. -1 at resolution time means: track this setup's
   // simulated outcome as always (local CSV, m_stats), but do NOT publish
   // it to POST /outcome — there is no valid signal_id to attach it to,
   // and posting a fabricated one would create a phantom join target in
   // signal_outcomes that can never actually match a signals row.
   long              decisionId;
  };

#endif
//+------------------------------------------------------------------+
