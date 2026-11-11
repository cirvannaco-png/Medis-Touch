//+------------------------------------------------------------------+
//| Medis Touch — single-file Expert Advisor                        |
//| Amalgamated from EA/MedisTouch_v2.8.mq5 and internal .mqh files. |
//| Internal project includes are inlined; MT5 standard libraries   |
//| remain external (MetaTrader 5 installation required).           |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//|                                                MedisTouch_EA.mq5  |
//|                                   Medis Touch — Trading/Signal EA |
//+------------------------------------------------------------------+
// WHY THIS IS A SEPARATE FILE FROM MedisTouch.mq5:
// MQL5 does not allow trading calls (OrderSend, CTrade, etc.) from an
// indicator context (#property indicator_chart_window) — only from an
// Expert Advisor or Script. MedisTouch.mq5 stays exactly as it was: a
// chart indicator for visualization/dashboard use with zero execution
// risk. This file is the actual robot: same analysis engine, attached as
// an EA, running under OnTick() where trading is legal. Run them
// together on the same chart (indicator for the visuals you're used to,
// EA for the parts that touch money) or run this alone headless.
#property copyright "Medis Touch"
#property version   "2.80"
#property strict

// ---- BEGIN EA/includes/Core/Config.mqh ----
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
   LEVEL_LIQUIDITY_POOL,  // CLiquidity external (D1 high/low) sweep — the doc's "previous day high/low"
   // v2.17 addition — the three sources v2.14's header explicitly left
   // unwired ("None of the three exist anywhere in the codebase yet").
   // See SmartMoney/ExtendedKeyLevels.mqh for CExtendedKeyLevels.
   LEVEL_PREV_WEEK,       // previous week's high or low (most recently CLOSED W1 bar)
   LEVEL_SESSION,         // current session's high or low so far (CSessionFilter-bounded)
   LEVEL_PSYCHOLOGICAL    // nearest round-number level at InpKeyLevelRoundStep spacing
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


// ---- END EA/includes/Core/Config.mqh ----

// ---- BEGIN EA/includes/Core/CandleData.mqh ----
//+------------------------------------------------------------------+
//|                                                Core/CandleData.mqh |
//+------------------------------------------------------------------+
#ifndef CANDLEDATA_MQH
#define CANDLEDATA_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----

class CCandleData
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_timeframe;
   int               m_maxBars;
   CandleData        m_data[];
   int               m_size;
   int               m_atrHandle;
   double            m_atrBuffer[];

   // FIX: was named CopyRates(), same name as the built-in MQL5 function
   // it calls internally — legal but a real footgun (shadowing/ambiguity).
   void              FetchRates();
   void              UpdateATR();

public:
                     CCandleData();
                    ~CCandleData();

   bool              Init(string symbol, ENUM_TIMEFRAMES tf, int maxBars = 500);
   int               Total() const { return m_size; }
   string            Symbol() const { return m_symbol; }
   ENUM_TIMEFRAMES   Timeframe() const { return m_timeframe; }
   CandleData        GetCandle(int shift) const;  // shift 0=current
   double            GetATR(int shift) const;
   bool              IsReady() const { return m_size > 0 && m_atrHandle != INVALID_HANDLE; }
   void              Refresh();                    // call each OnCalculate to keep in sync
  };
//+------------------------------------------------------------------+
CCandleData::CCandleData()
  {
   m_size = 0;
   m_maxBars = 500;
   m_atrHandle = INVALID_HANDLE;
  }
CCandleData::~CCandleData()
  {
   if(m_atrHandle != INVALID_HANDLE)
      IndicatorRelease(m_atrHandle);
  }
//+------------------------------------------------------------------+
bool CCandleData::Init(string symbol, ENUM_TIMEFRAMES tf, int maxBars)
  {
   m_symbol = symbol;
   m_timeframe = tf;
   m_maxBars = MathMax(50, maxBars);
   m_atrHandle = iATR(symbol, tf, 14);
   if(m_atrHandle == INVALID_HANDLE)
      return false;
   ArraySetAsSeries(m_data, true);
   FetchRates();
   return m_size > 0;
  }
//+------------------------------------------------------------------+
void CCandleData::FetchRates()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(m_symbol, m_timeframe, 0, m_maxBars, rates);
   if(copied <= 0)
      return;
   m_size = copied;
   ArrayResize(m_data, m_size);
   for(int i = 0; i < m_size; i++)
     {
      m_data[i].time = rates[i].time;
      m_data[i].open = rates[i].open;
      m_data[i].high = rates[i].high;
      m_data[i].low  = rates[i].low;
      m_data[i].close = rates[i].close;
      m_data[i].tick_volume = rates[i].tick_volume;
      m_data[i].atr = 0.0;
     }
   UpdateATR();
  }
//+------------------------------------------------------------------+
void CCandleData::UpdateATR()
  {
   if(m_atrHandle == INVALID_HANDLE || m_size <= 0) return;
   ArraySetAsSeries(m_atrBuffer, true);
   int copied = CopyBuffer(m_atrHandle, 0, 0, m_size, m_atrBuffer);
   if(copied <= 0) return;
   for(int i = 0; i < m_size && i < ArraySize(m_atrBuffer); i++)
      m_data[i].atr = m_atrBuffer[i];
  }
//+------------------------------------------------------------------+
CandleData CCandleData::GetCandle(int shift) const
  {
   CandleData empty;
   ZeroMemory(empty);
   if(shift < 0 || shift >= m_size) return empty;
   return m_data[shift];
  }
//+------------------------------------------------------------------+
double CCandleData::GetATR(int shift) const
  {
   if(shift < 0 || shift >= m_size) return 0.0;
   return m_data[shift].atr;
  }
//+------------------------------------------------------------------+
void CCandleData::Refresh()
  {
   // Full refresh each tick — correct for the bar counts this indicator
   // targets (default 500). If you push maxBars into the thousands,
   // switch this to an incremental append-only update.
   FetchRates();
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Core/CandleData.mqh ----

// ---- BEGIN EA/includes/Core/SignalLogger.mqh ----
//+------------------------------------------------------------------+
//|                                          Core/SignalLogger.mqh    |
//+------------------------------------------------------------------+
#ifndef SIGNALLOGGER_MQH
#define SIGNALLOGGER_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----

// Session labeling: v4 bucketed by raw server-clock hour, which drifts
// wrong by however many hours the broker's server sits from GMT (and
// worse across DST changes). This version computes the live server-to-GMT
// offset via TimeTradeServer()/TimeGMT() and buckets by real GMT session
// windows (Sydney/Tokyo/London/New York + overlaps) instead.
class CSignalLogger
  {
private:
   string            m_filename;
   string            m_outcomeFilename;
   bool              m_headerWritten;
   bool              m_outcomeHeaderWritten;
   int               m_gmtOffsetOverrideHours; // 999 = auto-detect

   string            SessionForGMTHour(int h);
   int               ServerToGMTOffsetHours();
   string            SessionLabel(datetime serverTime);
   string            ReasonString(SetupReasons &r);
   string            FillPolicyLabel(ENUM_FILL_POLICY fp);
   string            FibZoneLabel(ENUM_FIB_ZONE z);
   string            VAZoneLabel(ENUM_VALUE_AREA_ZONE z);
   string            VolRegimeLabel(ENUM_VOL_REGIME v);
   string            OBStateLabel(ENUM_OB_STATE s);
   string            RegimeLabel(ENUM_MARKET_REGIME r);       // v2.12
   string            BreakoutClassLabel(ENUM_BREAKOUT_CLASS c); // v2.12
   string            ReversionClassLabel(ENUM_REVERSION_CLASS c); // v2.13
   string            KeyLevelSourceLabel(ENUM_KEYLEVEL_SOURCE s);     // v2.14
   string            KeyLevelReactionLabel(ENUM_KEYLEVEL_REACTION r); // v2.14
   string            SelectedStrategyLabel(ENUM_SELECTED_STRATEGY s); // v2.15

public:
                     CSignalLogger();
   void              Init(string symbol, int gmtOffsetOverrideHours = 999);
   bool              LogSetup(TradeSetup &setup, string symbol, ENUM_TIMEFRAMES entryTF, string trendLabel);
   bool              LogOutcome(PendingSetup &p, string symbol, ENUM_TIMEFRAMES entryTF, string outcome,
                                double exitPrice, ENUM_FILL_POLICY fillPolicy = FILL_CONSERVATIVE);
  };
//+------------------------------------------------------------------+
CSignalLogger::CSignalLogger() : m_headerWritten(false), m_outcomeHeaderWritten(false), m_gmtOffsetOverrideHours(999) {}
//+------------------------------------------------------------------+
void CSignalLogger::Init(string symbol, int gmtOffsetOverrideHours)
  {
   m_filename = "MedisTouch_Signals_" + symbol + ".csv";
   m_outcomeFilename = "MedisTouch_Outcomes_" + symbol + ".csv";
   m_headerWritten = FileIsExist(m_filename);
   m_outcomeHeaderWritten = FileIsExist(m_outcomeFilename);
   m_gmtOffsetOverrideHours = gmtOffsetOverrideHours;
  }
//+------------------------------------------------------------------+
// FIX: v4 used the raw server hour as a proxy for session, which is only
// correct if the broker's server clock happens to run on GMT — most
// don't (common offsets are GMT+2/+3, sometimes with their own DST
// schedule that doesn't match any real session's DST). This computes the
// actual live offset each call via TimeTradeServer() - TimeGMT(), so it
// self-corrects across DST transitions instead of drifting for months.
//
// CAVEAT: TimeGMT() depends on the terminal's Windows GMT/timezone
// database being current, and can behave inconsistently inside the
// Strategy Tester on some builds. InpSessionGMTOffsetOverride exists
// specifically so you can pin a known-correct offset if you ever see the
// auto-detected value look wrong for your broker.
int CSignalLogger::ServerToGMTOffsetHours()
  {
   if(m_gmtOffsetOverrideHours != 999)
      return m_gmtOffsetOverrideHours;
   datetime srv = TimeTradeServer();
   datetime gmt = TimeGMT();
   double hours = (double)(srv - gmt) / 3600.0;
   return (int)MathRound(hours);
  }
//+------------------------------------------------------------------+
string CSignalLogger::SessionForGMTHour(int h)
  {
   h = ((h % 24) + 24) % 24; // normalize
   bool sydney = (h >= 21 || h < 6);
   bool tokyo  = (h >= 0  && h < 9);
   bool london = (h >= 7  && h < 16);
   bool ny     = (h >= 12 && h < 21);

   if(london && ny)    return "London/NY Overlap";
   if(tokyo && london) return "Tokyo/London Overlap";
   if(sydney && tokyo) return "Sydney/Tokyo Overlap";
   if(london) return "London";
   if(ny)     return "New York";
   if(tokyo)  return "Tokyo";
   if(sydney) return "Sydney";
   return "Off-hours";
  }
//+------------------------------------------------------------------+
string CSignalLogger::SessionLabel(datetime serverTime)
  {
   int offset = ServerToGMTOffsetHours();
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   int gmtHour = dt.hour - offset;
   return SessionForGMTHour(gmtHour);
  }
//+------------------------------------------------------------------+
string CSignalLogger::ReasonString(SetupReasons &r)
  {
   string s = "";
   if(r.trend_aligned)   s += "Trend|";
   if(r.bos_confirmed)   s += "BOS|";
   if(r.liquidity_swept) s += "Liquidity|";
   if(r.fresh_fvg)       s += "FVG|";
   if(r.sr_confluence)   s += "SR|";
   if(r.inducement_valid) s += "Inducement|";
   if(r.premium_discount_ok) s += "PremDisc|";
   if(r.volume_confirmed) s += "Volume|";
   if(r.fib_in_zone) s += "FibZone|";
   if(r.value_area_ok) s += "ValueArea|";
   if(r.htf_ob_confluence) s += "HtfOB|";
   if(!r.session_ok) s += "OffSession|";
   if(StringLen(s) == 0) return "None";
   return s;
  }
//+------------------------------------------------------------------+
string CSignalLogger::VolRegimeLabel(ENUM_VOL_REGIME v)
  {
   switch(v)
     {
      case VOL_REGIME_LOW:    return "Low";
      case VOL_REGIME_NORMAL: return "Normal";
      case VOL_REGIME_HIGH:   return "High";
      default:                return "Undefined";
     }
  }
//+------------------------------------------------------------------+
string CSignalLogger::OBStateLabel(ENUM_OB_STATE s)
  {
   switch(s)
     {
      case OB_FRESH:     return "Fresh";
      case OB_TESTED:     return "Tested";
      case OB_MITIGATED:  return "Mitigated";
      default:            return "None";
     }
  }
//+------------------------------------------------------------------+
// v2.12
string CSignalLogger::RegimeLabel(ENUM_MARKET_REGIME r)
  {
   switch(r)
     {
      case REGIME_TRENDING:    return "Trending";
      case REGIME_RANGING:     return "Ranging";
      case REGIME_TRANSITION:  return "Transition";
      default:                 return "Undefined";
     }
  }
//+------------------------------------------------------------------+
// v2.12
string CSignalLogger::BreakoutClassLabel(ENUM_BREAKOUT_CLASS c)
  {
   switch(c)
     {
      case BREAKOUT_EXPANSION:  return "Expansion";
      case BREAKOUT_LIQUIDITY:  return "Liquidity";
      case BREAKOUT_FAILED:     return "Failed";
      case BREAKOUT_EXHAUSTION: return "Exhaustion";
      default:                  return "None";
     }
  }
//+------------------------------------------------------------------+
// v2.13
string CSignalLogger::ReversionClassLabel(ENUM_REVERSION_CLASS c)
  {
   switch(c)
     {
      case REVERSION_VALUE_FADE:      return "ValueFade";
      case REVERSION_LEVEL_REJECTION: return "LevelRejection";
      case REVERSION_TREND_CONFLICT:  return "TrendConflict";
      default:                        return "None";
     }
  }
//+------------------------------------------------------------------+
// v2.14. v2.17: added the three sources that pass added — see
// Core/Config.mqh's ENUM_KEYLEVEL_SOURCE and SmartMoney/ExtendedKeyLevels.mqh.
// Without these three cases here, LEVEL_PREV_WEEK/LEVEL_SESSION/
// LEVEL_PSYCHOLOGICAL would silently fall through to "None" in the CSV —
// a level WAS found and acted on, but the log would say otherwise.
string CSignalLogger::KeyLevelSourceLabel(ENUM_KEYLEVEL_SOURCE s)
  {
   switch(s)
     {
      case LEVEL_SR:              return "SR";
      case LEVEL_ORDER_BLOCK:      return "OrderBlock";
      case LEVEL_VALUE_AREA:       return "ValueArea";
      case LEVEL_LIQUIDITY_POOL:   return "LiquidityPool";
      case LEVEL_PREV_WEEK:        return "PrevWeek";
      case LEVEL_SESSION:          return "Session";
      case LEVEL_PSYCHOLOGICAL:    return "Psychological";
      default:                     return "None";
     }
  }
//+------------------------------------------------------------------+
// v2.14
string CSignalLogger::KeyLevelReactionLabel(ENUM_KEYLEVEL_REACTION r)
  {
   switch(r)
     {
      case REACTION_REJECTION:     return "Rejection";
      case REACTION_BREAK:         return "Break";
      case REACTION_RETEST:        return "Retest";
      case REACTION_FAILED_BREAK:  return "FailedBreak";
      case REACTION_ACCEPTANCE:    return "Acceptance";
      case REACTION_ABSORPTION:    return "Absorption";
      default:                     return "None";
     }
  }
//+------------------------------------------------------------------+
// v2.15
string CSignalLogger::SelectedStrategyLabel(ENUM_SELECTED_STRATEGY s)
  {
   switch(s)
     {
      case STRATEGY_SMC:                return "SMC";
      case STRATEGY_MOMENTUM_BREAKOUT:   return "MomentumBreakout";
      case STRATEGY_MEAN_REVERSION:      return "MeanReversion";
      case STRATEGY_KEY_LEVEL:           return "KeyLevel";
      default:                           return "None";
     }
  }
//+------------------------------------------------------------------+
string CSignalLogger::VAZoneLabel(ENUM_VALUE_AREA_ZONE z)
  {
   switch(z)
     {
      case VA_ZONE_BELOW:  return "Below";
      case VA_ZONE_INSIDE: return "Inside";
      case VA_ZONE_ABOVE:  return "Above";
      default:             return "Undefined";
     }
  }
//+------------------------------------------------------------------+
string CSignalLogger::FibZoneLabel(ENUM_FIB_ZONE z)
  {
   switch(z)
     {
      case FIB_ZONE_DISCOUNT: return "Discount";
      case FIB_ZONE_NEUTRAL:  return "Neutral";
      case FIB_ZONE_PREMIUM:  return "Premium";
      default:                return "Undefined";
     }
  }
//+------------------------------------------------------------------+
string CSignalLogger::FillPolicyLabel(ENUM_FILL_POLICY fp)
  {
   string s = EnumToString(fp);
   StringReplace(s, "FILL_", "");
   return s;
  }
//+------------------------------------------------------------------+
bool CSignalLogger::LogSetup(TradeSetup &setup, string symbol, ENUM_TIMEFRAMES entryTF, string trendLabel)
  {
   if(!setup.active) return false;

   int flags = FILE_CSV | FILE_READ | FILE_WRITE | FILE_SHARE_READ | FILE_ANSI;
   int handle = FileOpen(m_filename, flags, ',');
   if(handle == INVALID_HANDLE)
     {
      Print("MedisTouch SignalLogger: failed to open ", m_filename, " err=", GetLastError());
      return false;
     }

   if(!m_headerWritten)
     {
      FileWrite(handle, "SignalID", "Symbol", "EntryTF", "DateTime", "Session", "Trend", "Direction",
               "Confidence", "EntryTop", "EntryBottom", "StopLoss", "TP1", "TP2", "FinalTP",
               "Reasons", "RiskWarning", "RVOL", "VolumeConfirmed", "FibZone", "FibInZone", "FibNearestLevel",
               "VAZone", "ValueAreaOK", "POC", "VAH", "VAL",
               "HtfOBConfluence", "HtfOBState", "VolRegime", "SessionOK",
               // v2.10 diagnostics. Appended, never inserted: parsers keyed
               // on column position keep working.
               "ContradictionPenalty", "EnvScore", "ExecScore", "EnvExecConfidence",
               // v2.12 diagnostics — same append-only discipline.
               "Regime", "MomentumScore", "BreakoutScore", "BreakoutClass",
               // v2.13 diagnostics — same append-only discipline.
               "ReversionScore", "ReversionClass",
               // v2.14 diagnostics — same append-only discipline.
               "KeyLevelSource", "KeyLevelReaction", "KeyLevelScore",
               // v2.15 diagnostics — same append-only discipline.
               "SelectedStrategy", "SelectedStrategyScore");
      m_headerWritten = true;
     }

   FileSeek(handle, 0, SEEK_END);
   string session = SessionLabel(setup.creation_time);
   string dir = (setup.type == ORDER_TYPE_BUY) ? "BUY" : "SELL";
   string risk = (StringLen(setup.reasons.risk_warning) > 0) ? setup.reasons.risk_warning : "None";
   // SignalID joins this row to its eventual outcome row in the Outcomes
   // CSV — just the creation timestamp + direction, unique enough for a
   // single-symbol, single-instance signal stream.
   string signalId = StringFormat("%s_%s_%d", symbol, dir, (long)setup.creation_time);

   FileWrite(handle, signalId, symbol, EnumToString(entryTF), TimeToString(setup.creation_time, TIME_DATE | TIME_MINUTES),
            session, trendLabel, dir, DoubleToString(setup.confidence, 1),
            DoubleToString(setup.entry_top, _Digits), DoubleToString(setup.entry_bottom, _Digits),
            DoubleToString(setup.stop_loss, _Digits), DoubleToString(setup.tp1, _Digits),
            DoubleToString(setup.tp2, _Digits), DoubleToString(setup.final_tp, _Digits),
            ReasonString(setup.reasons), risk,
            DoubleToString(setup.reasons.rvol, 2), setup.reasons.volume_confirmed ? "Yes" : "No",
            FibZoneLabel(setup.reasons.fib_zone), setup.reasons.fib_in_zone ? "Yes" : "No",
            DoubleToString(setup.reasons.fib_nearest_level, _Digits),
            VAZoneLabel(setup.reasons.va_zone), setup.reasons.value_area_ok ? "Yes" : "No",
            DoubleToString(setup.reasons.va_poc, _Digits), DoubleToString(setup.reasons.va_high, _Digits),
            DoubleToString(setup.reasons.va_low, _Digits),
            setup.reasons.htf_ob_confluence ? "Yes" : "No", OBStateLabel(setup.reasons.htf_ob_state),
            VolRegimeLabel(setup.reasons.vol_regime), setup.reasons.session_ok ? "Yes" : "No",
            DoubleToString(setup.reasons.contradiction_penalty, 3),
            DoubleToString(setup.reasons.env_score, 3),
            DoubleToString(setup.reasons.exec_score, 3),
            DoubleToString(setup.reasons.env_exec_confidence, 1),
            RegimeLabel(setup.reasons.regime),
            DoubleToString(setup.reasons.momentum_score, 1),
            DoubleToString(setup.reasons.breakout_score, 1),
            BreakoutClassLabel(setup.reasons.breakout_class),
            DoubleToString(setup.reasons.reversion_score, 1),
            ReversionClassLabel(setup.reasons.reversion_class),
            KeyLevelSourceLabel(setup.reasons.keylevel_source),
            KeyLevelReactionLabel(setup.reasons.keylevel_reaction),
            DoubleToString(setup.reasons.keylevel_score, 1),
            SelectedStrategyLabel(setup.reasons.selected_strategy),
            DoubleToString(setup.reasons.selected_strategy_score, 1));

   FileClose(handle);
   return true;
  }
//+------------------------------------------------------------------+
bool CSignalLogger::LogOutcome(PendingSetup &p, string symbol, ENUM_TIMEFRAMES entryTF, string outcome,
                               double exitPrice, ENUM_FILL_POLICY fillPolicy)
  {
   int flags = FILE_CSV | FILE_READ | FILE_WRITE | FILE_SHARE_READ | FILE_ANSI;
   int handle = FileOpen(m_outcomeFilename, flags, ',');
   if(handle == INVALID_HANDLE)
     {
      Print("MedisTouch SignalLogger: failed to open ", m_outcomeFilename, " err=", GetLastError());
      return false;
     }

   if(!m_outcomeHeaderWritten)
     {
      FileWrite(handle, "SignalID", "Symbol", "EntryTF", "Direction", "Outcome", "ExitPrice",
               "EntryRef", "RiskDistance", "Filled", "FillTime", "BarsToFill", "MFE_Price", "MAE_Price",
               "MFE_R", "MAE_R", "TP1_Hit", "TP2_Hit", "BarsHeld", "SameBarSLTPCollision", "FillPolicy",
               "Lots", "EntryFillPrice", "BreakEvenDone", "PartialDone", "RealizedNetPnL", "RealizedR",
               "Commission", "SpreadCost", "SlippageCost",
               // v2.10 - the decay diagnostic, paired with the resolved
               // outcome so the retraining pipeline can test whether
               // staleness actually predicts a worse result.
               "ConfidenceAtSignal", "ConfidenceDecayed", "DecayBars",
               // Repeated from the signal row so an outcomes file is
               // self-sufficient for fitting the multiplicative model.
               "ContradictionPenalty", "EnvScore", "ExecScore", "EnvExecConfidence",
               // v2.12 — same "repeated from the signal row" rationale.
               "Regime", "MomentumScore", "BreakoutScore", "BreakoutClass",
               // v2.13 — same rationale.
               "ReversionScore", "ReversionClass",
               // v2.14 — same rationale.
               "KeyLevelSource", "KeyLevelReaction", "KeyLevelScore",
               // v2.15 — same rationale.
               "SelectedStrategy", "SelectedStrategyScore");
      m_outcomeHeaderWritten = true;
     }

   FileSeek(handle, 0, SEEK_END);
   string dir = (p.setup.type == ORDER_TYPE_BUY) ? "BUY" : "SELL";
   string signalId = StringFormat("%s_%s_%d", symbol, dir, (long)p.setup.creation_time);

   double mfeR = 0.0, maeR = 0.0;
   if(p.filled && p.riskDist > 0)
     {
      double mfeDist = (p.setup.type == ORDER_TYPE_BUY) ? (p.mfePrice - p.entryRef) : (p.entryRef - p.mfePrice);
      double maeDist = (p.setup.type == ORDER_TYPE_BUY) ? (p.entryRef - p.maePrice) : (p.maePrice - p.entryRef);
      mfeR = mfeDist / p.riskDist;
      maeR = maeDist / p.riskDist;
     }

   // Realized R uses mgmtRiskDist (the same basis the simulator's
   // breakeven/partial triggers are computed against) converted to a
   // dollar risk-per-1R for this trade's actual lot size — 0 if the
   // trade was never sized (lots<=0, e.g. risk% below broker minimum).
   double realizedR = 0.0;
   if(p.lots > 0 && p.mgmtRiskDist > 0)
     {
      double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize > 0 && tickValue > 0)
        {
         double oneRDollar = p.mgmtRiskDist * (tickValue / tickSize) * p.lots;
         if(oneRDollar > 0) realizedR = p.realizedPnL / oneRDollar;
        }
     }

   FileWrite(handle, signalId, symbol, EnumToString(entryTF), dir, outcome,
            DoubleToString(exitPrice, _Digits), DoubleToString(p.entryRef, _Digits),
            DoubleToString(p.riskDist, _Digits), p.filled ? "Yes" : "No",
            p.filled ? TimeToString(p.fillTime, TIME_DATE | TIME_MINUTES) : "",
            p.filled ? p.barsToFill : 0,
            DoubleToString(p.mfePrice, _Digits), DoubleToString(p.maePrice, _Digits),
            DoubleToString(mfeR, 2), DoubleToString(maeR, 2),
            p.tp1Hit ? "Yes" : "No", p.tp2Hit ? "Yes" : "No", p.barsElapsed,
            p.sameBarCollision ? "Yes" : "No", FillPolicyLabel(fillPolicy),
            DoubleToString(p.lots, 2), DoubleToString(p.entryFillPrice, _Digits),
            p.beDone ? "Yes" : "No", p.partialDone ? "Yes" : "No",
            DoubleToString(p.realizedPnL, 2), DoubleToString(realizedR, 2),
            DoubleToString(p.totalCommission, 2), DoubleToString(p.totalSpreadCost, 2),
            DoubleToString(p.totalSlippageCost, 2),
            DoubleToString(p.confidenceAtSignal, 1), DoubleToString(p.confidenceDecayed, 1),
            p.decayBars,
            DoubleToString(p.setup.reasons.contradiction_penalty, 3),
            DoubleToString(p.setup.reasons.env_score, 3),
            DoubleToString(p.setup.reasons.exec_score, 3),
            DoubleToString(p.setup.reasons.env_exec_confidence, 1),
            RegimeLabel(p.setup.reasons.regime),
            DoubleToString(p.setup.reasons.momentum_score, 1),
            DoubleToString(p.setup.reasons.breakout_score, 1),
            BreakoutClassLabel(p.setup.reasons.breakout_class),
            DoubleToString(p.setup.reasons.reversion_score, 1),
            ReversionClassLabel(p.setup.reasons.reversion_class),
            KeyLevelSourceLabel(p.setup.reasons.keylevel_source),
            KeyLevelReactionLabel(p.setup.reasons.keylevel_reaction),
            DoubleToString(p.setup.reasons.keylevel_score, 1),
            SelectedStrategyLabel(p.setup.reasons.selected_strategy),
            DoubleToString(p.setup.reasons.selected_strategy_score, 1));

   FileClose(handle);
   return true;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Core/SignalLogger.mqh ----

// ---- BEGIN EA/includes/Analysis/TFContext.mqh ----
//+------------------------------------------------------------------+
//|                                            Analysis/TFContext.mqh |
//+------------------------------------------------------------------+
#ifndef TFCONTEXT_MQH
#define TFCONTEXT_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----


// ---- BEGIN EA/includes/Structure/SwingDetector.mqh ----
//+------------------------------------------------------------------+
//|                                        Structure/SwingDetector.mqh |
//+------------------------------------------------------------------+
#ifndef SWINGDETECTOR_MQH
#define SWINGDETECTOR_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----

class CSwingDetector
  {
private:
   CCandleData*      m_candles;
   int               m_strength;       // N left/right bars
   SwingPoint        m_swingHighs[];
   SwingPoint        m_swingLows[];
   int               m_highCount;
   int               m_lowCount;

   bool              IsSwingHigh(int idx);
   bool              IsSwingLow(int idx);
   double            CalcStrength(int idx);

public:
                     CSwingDetector();
   void              SetParameters(CCandleData* candleData, int strength = 3);
   void              Detect();

   int               HighCount() const { return m_highCount; }
   int               LowCount() const { return m_lowCount; }
   int               Strength() const { return m_strength; } // needed by BOS/Liquidity to know a swing's confirmation lag (audit #7/#11 fix)
   SwingPoint        GetHigh(int i) const;  // 0 = most recent
   SwingPoint        GetLow(int i) const;   // 0 = most recent
  };
//+------------------------------------------------------------------+
CSwingDetector::CSwingDetector()
  {
   m_candles = NULL;
   m_strength = 3;
   m_highCount = 0;
   m_lowCount = 0;
  }
//+------------------------------------------------------------------+
void CSwingDetector::SetParameters(CCandleData* candleData, int strength)
  {
   m_candles = candleData;
   m_strength = MathMax(1, strength);
  }
//+------------------------------------------------------------------+
// NOTE: series array convention — index 0 is the newest bar, increasing
// index moves further into the past. So "idx - i" (smaller index) is
// MORE recent than idx, and "idx + i" (larger index) is OLDER than idx.
bool CSwingDetector::IsSwingHigh(int idx)
  {
   if(m_candles == NULL) return false;
   int total = m_candles.Total();
   if(idx < m_strength || idx >= total - m_strength) return false;
   double high = m_candles.GetCandle(idx).high;
   for(int i = 1; i <= m_strength; i++)
     {
      if(m_candles.GetCandle(idx - i).high >= high) return false; // more recent side
      if(m_candles.GetCandle(idx + i).high >= high) return false; // older side
     }
   return true;
  }
//+------------------------------------------------------------------+
bool CSwingDetector::IsSwingLow(int idx)
  {
   if(m_candles == NULL) return false;
   int total = m_candles.Total();
   if(idx < m_strength || idx >= total - m_strength) return false;
   double low = m_candles.GetCandle(idx).low;
   for(int i = 1; i <= m_strength; i++)
     {
      if(m_candles.GetCandle(idx - i).low <= low) return false;
      if(m_candles.GetCandle(idx + i).low <= low) return false;
     }
   return true;
  }
//+------------------------------------------------------------------+
double CSwingDetector::CalcStrength(int idx)
  {
   CandleData cd = m_candles.GetCandle(idx);
   double range = (cd.high - cd.low);
   double atr = cd.atr;
   if(atr <= 0) return 0.5;
   double ratio = range / atr;
   return MathMin(ratio, 1.0);
  }
//+------------------------------------------------------------------+
void CSwingDetector::Detect()
  {
   m_highCount = 0;
   m_lowCount = 0;
   if(m_candles == NULL) return;
   int total = m_candles.Total();
   if(total < 2 * m_strength + 1) return;
   ArrayResize(m_swingHighs, total);
   ArrayResize(m_swingLows, total);

   // Scan from oldest scannable bar to newest so results start in
   // chronological order (oldest first).
   for(int i = total - m_strength - 1; i >= m_strength; i--)
     {
      if(IsSwingHigh(i))
        {
         SwingPoint sp;
         sp.time = m_candles.GetCandle(i).time;
         sp.price = m_candles.GetCandle(i).high;
         sp.is_high = true;
         sp.bar_index = i;
         sp.strength = CalcStrength(i);
         m_swingHighs[m_highCount++] = sp;
        }
      if(IsSwingLow(i))
        {
         SwingPoint sp;
         sp.time = m_candles.GetCandle(i).time;
         sp.price = m_candles.GetCandle(i).low;
         sp.is_high = false;
         sp.bar_index = i;
         sp.strength = CalcStrength(i);
         m_swingLows[m_lowCount++] = sp;
        }
     }
   ArrayResize(m_swingHighs, m_highCount);
   ArrayResize(m_swingLows, m_lowCount);
   // Arrays are now newest-first already, since we scanned high bar_index
   // (older) down to low bar_index (newer) and appended in that order —
   // wait: we appended oldest-scanned-first meaning m_swingHighs[0] is the
   // OLDEST swing found. Reverse so index 0 = most recent, matching the
   // documented GetHigh()/GetLow() contract used by every other module.
   for(int j = 0; j < m_highCount / 2; j++)
     {
      SwingPoint t = m_swingHighs[j];
      m_swingHighs[j] = m_swingHighs[m_highCount - 1 - j];
      m_swingHighs[m_highCount - 1 - j] = t;
     }
   for(int j = 0; j < m_lowCount / 2; j++)
     {
      SwingPoint t = m_swingLows[j];
      m_swingLows[j] = m_swingLows[m_lowCount - 1 - j];
      m_swingLows[m_lowCount - 1 - j] = t;
     }
  }
//+------------------------------------------------------------------+
SwingPoint CSwingDetector::GetHigh(int i) const
  {
   SwingPoint empty;
   ZeroMemory(empty);
   if(i < 0 || i >= m_highCount) return empty;
   return m_swingHighs[i];
  }
//+------------------------------------------------------------------+
SwingPoint CSwingDetector::GetLow(int i) const
  {
   SwingPoint empty;
   ZeroMemory(empty);
   if(i < 0 || i >= m_lowCount) return empty;
   return m_swingLows[i];
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Structure/SwingDetector.mqh ----


// ---- BEGIN EA/includes/Structure/BOS.mqh ----
//+------------------------------------------------------------------+
//|                                                   Structure/BOS.mqh |
//+------------------------------------------------------------------+
#ifndef BOS_MQH
#define BOS_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----


// ---- BEGIN EA/includes/Structure/SwingDetector.mqh ----

// ---- END EA/includes/Structure/SwingDetector.mqh ----

class CBOS
  {
private:
   CSwingDetector*   m_swings;
   CCandleData*      m_candles;
   BOSEvent          m_bosList[];
   int               m_bosCount;

   double            BreakoutStrength(int shift, double atr, const CandleData &cd, double brokenLevel) const;

public:
                     CBOS();
   void              Init(CSwingDetector* swingDetector, CCandleData* candleData);
   void              Detect();
   int               Count() const { return m_bosCount; }
   BOSEvent          GetBOS(int i) const;  // 0 = most recent
  };
//+------------------------------------------------------------------+
CBOS::CBOS() : m_swings(NULL), m_candles(NULL), m_bosCount(0) {}
void CBOS::Init(CSwingDetector* swingDetector, CCandleData* candleData)
  {
   m_swings = swingDetector;
   m_candles = candleData;
  }
//+------------------------------------------------------------------+
// (a) how far price closed beyond the broken level, relative to ATR, and
// (b) whether the breakout candle traded on above-average volume vs the
// prior 10 bars.
double CBOS::BreakoutStrength(int shift, double atr, const CandleData &cd, double brokenLevel) const
  {
   double breakoutDistATR = MathAbs(cd.close - brokenLevel) / atr;
   double avgVol = 0.0;
   int n = 0;
   for(int b = shift + 1; b <= shift + 10 && b < m_candles.Total(); b++)
     {
      avgVol += (double)m_candles.GetCandle(b).tick_volume;
      n++;
     }
   double volRatio = (n > 0 && avgVol > 0) ? ((double)cd.tick_volume / (avgVol / n)) : 1.0;
   double s = 0.6 * MathMin(breakoutDistATR / 1.0, 1.0) + 0.4 * MathMin(volRatio / 2.0, 1.0);
   return MathMax(0.0, MathMin(s, 1.0));
  }
//+------------------------------------------------------------------+
// FIX (audit #7 — lookahead bias): the previous implementation picked
// ONE swing — "the most recent lower high in TODAY's fully up-to-date
// swing list" — and then scanned every historical bar (i = 1..total-1)
// checking whether ITS close broke THAT SAME swing. Two bars from
// entirely different points in history were being judged against a
// single "lower high" that may not have existed, or even been
// CONFIRMED yet (a swing needs `strength` bars of later data before
// it's a swing at all), at the time those older bars actually printed.
// That's lookahead: a historical BOS could be "confirmed" using
// structure the market didn't have yet.
//
// This rewrite is a single chronological forward pass (oldest bar to
// newest). It tracks the currently active, not-yet-broken "lower high" /
// "higher low" candidate, but only ever promotes a swing into that role
// once the swing itself is CONFIRMED as of the current bar (bar_index -
// strength >= current shift — i.e. `strength` bars have already printed
// after it). A BOS event is only recorded on the bar that closes beyond
// an ALREADY-CONFIRMED candidate, in time order. This is chronologically
// sound: every BOS event only ever depends on data that existed on or
// before its own bar.
void CBOS::Detect()
  {
   m_bosCount = 0;
   if(m_swings == NULL || m_candles == NULL) return;
   int total = m_candles.Total();
   if(total < 2) return;
   int strength = m_swings.Strength();

   int nHighs = m_swings.HighCount();
   int nLows  = m_swings.LowCount();

   // GetHigh(0)/GetLow(0) = newest, larger index = older. Reverse into
   // oldest-first order so we can walk them alongside the chronological
   // (oldest -> newest) candle scan below.
   SwingPoint highsChrono[];
   ArrayResize(highsChrono, nHighs);
   for(int i = 0; i < nHighs; i++) highsChrono[i] = m_swings.GetHigh(nHighs - 1 - i);
   SwingPoint lowsChrono[];
   ArrayResize(lowsChrono, nLows);
   for(int i = 0; i < nLows; i++) lowsChrono[i] = m_swings.GetLow(nLows - 1 - i);

   int highPtr = 0, lowPtr = 0;
   bool havePrevHigh = false, havePrevLow = false;
   SwingPoint prevHigh, prevLow;
   bool haveActiveLowerHigh = false, haveActiveHigherLow = false;
   SwingPoint activeLowerHigh, activeHigherLow;

   BOSEvent chrono[]; // built oldest -> newest, reversed into m_bosList at the end
   ArrayResize(chrono, total);
   int chronoCount = 0;

   for(int shift = total - 1; shift >= 1; shift--) // oldest -> newest
     {
      // Confirm any swings whose confirmation point has now arrived
      // (chronologically: a swing at bar_index needs `strength` later
      // bars to exist before it counts as confirmed structure).
      while(highPtr < nHighs && (highsChrono[highPtr].bar_index - strength) >= shift)
        {
         SwingPoint h = highsChrono[highPtr];
         if(havePrevHigh && h.price < prevHigh.price) // freshly-confirmed lower high
           {
            activeLowerHigh = h;
            haveActiveLowerHigh = true;
           }
         prevHigh = h;
         havePrevHigh = true;
         highPtr++;
        }
      while(lowPtr < nLows && (lowsChrono[lowPtr].bar_index - strength) >= shift)
        {
         SwingPoint l = lowsChrono[lowPtr];
         if(havePrevLow && l.price > prevLow.price) // freshly-confirmed higher low
           {
            activeHigherLow = l;
            haveActiveHigherLow = true;
           }
         prevLow = l;
         havePrevLow = true;
         lowPtr++;
        }

      double atr = m_candles.GetATR(shift);
      if(atr <= 0) continue;
      CandleData cd = m_candles.GetCandle(shift);

      if(haveActiveLowerHigh)
        {
         double threshold = activeLowerHigh.price + 0.1 * atr;
         if(cd.close > threshold)
           {
            BOSEvent ev;
            ev.time = cd.time;
            ev.price = cd.close;
            ev.is_bullish = true;
            ev.strength = BreakoutStrength(shift, atr, cd, activeLowerHigh.price);
            ev.bar_index = shift;
            ev.label = "BOS \u2191";
            chrono[chronoCount++] = ev;
            haveActiveLowerHigh = false; // consumed — next lower high (if any) becomes the new candidate
           }
        }
      if(haveActiveHigherLow)
        {
         double threshold = activeHigherLow.price - 0.1 * atr;
         if(cd.close < threshold)
           {
            BOSEvent ev;
            ev.time = cd.time;
            ev.price = cd.close;
            ev.is_bullish = false;
            ev.strength = BreakoutStrength(shift, atr, cd, activeHigherLow.price);
            ev.bar_index = shift;
            ev.label = "BOS \u2193";
            chrono[chronoCount++] = ev;
            haveActiveHigherLow = false;
           }
        }
     }

   // chrono[] is oldest -> newest; GetBOS(0) must return the newest, so reverse on the way out.
   ArrayResize(m_bosList, chronoCount);
   for(int i = 0; i < chronoCount; i++)
      m_bosList[i] = chrono[chronoCount - 1 - i];
   m_bosCount = chronoCount;
  }
//+------------------------------------------------------------------+
BOSEvent CBOS::GetBOS(int i) const
  {
   BOSEvent empty;
   ZeroMemory(empty);
   if(i < 0 || i >= m_bosCount) return empty;
   return m_bosList[i];
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Structure/BOS.mqh ----


// ---- BEGIN EA/includes/Structure/CHOCH.mqh ----
//+------------------------------------------------------------------+
//|                                                 Structure/CHOCH.mqh |
//+------------------------------------------------------------------+
#ifndef CHOCH_MQH
#define CHOCH_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----


// ---- BEGIN EA/includes/Structure/SwingDetector.mqh ----

// ---- END EA/includes/Structure/SwingDetector.mqh ----

// NOTE: by design this engine tracks only the single most recent bullish
// CHoCH and the single most recent bearish CHoCH (mirrors how CHoCH is
// actually used — as a live structure-shift flag, not a historical log).
// Count() will be 0, 1, or 2.
class CCHOCH
  {
private:
   CSwingDetector*   m_swings;
   CCandleData*      m_candles;
   CHOCHPoint        m_choch[];
   int               m_count;

public:
                     CCHOCH();
   void              Init(CSwingDetector* swings, CCandleData* candles);
   void              Detect();
   int               Count() const { return m_count; }
   CHOCHPoint        Get(int i) const; // 0 = most recent
  };
//+------------------------------------------------------------------+
CCHOCH::CCHOCH() : m_swings(NULL), m_candles(NULL), m_count(0) {}
void CCHOCH::Init(CSwingDetector* swings, CCandleData* candles)
  {
   m_swings = swings;
   m_candles = candles;
  }
//+------------------------------------------------------------------+
void CCHOCH::Detect()
  {
   m_count = 0;
   if(m_swings == NULL || m_candles == NULL) return;
   ArrayResize(m_choch, 2);

   CHOCHPoint bull, bear;
   ZeroMemory(bull);
   ZeroMemory(bear);
   bool haveBull = false, haveBear = false;

   // Bearish -> Bullish CHoCH: last lower high broken upwards
   int highCount = m_swings.HighCount();
   if(highCount >= 2)
     {
      for(int i = 0; i < highCount - 1; i++)
        {
         SwingPoint curr = m_swings.GetHigh(i);
         SwingPoint prev = m_swings.GetHigh(i + 1);
         if(curr.price < prev.price) // lower high
           {
            for(int bar = curr.bar_index - 1; bar >= 0; bar--)
              {
               if(m_candles.GetCandle(bar).close > curr.price)
                 {
                  bull.time = m_candles.GetCandle(bar).time;
                  bull.price = curr.price;
                  bull.bullish = true;
                  bull.bar_index = bar;
                  haveBull = true;
                  break;
                 }
              }
            break;
           }
        }
     }

   // Bullish -> Bearish CHoCH: last higher low broken downwards
   int lowCount = m_swings.LowCount();
   if(lowCount >= 2)
     {
      for(int i = 0; i < lowCount - 1; i++)
        {
         SwingPoint curr = m_swings.GetLow(i);
         SwingPoint prev = m_swings.GetLow(i + 1);
         if(curr.price > prev.price) // higher low
           {
            for(int bar = curr.bar_index - 1; bar >= 0; bar--)
              {
               if(m_candles.GetCandle(bar).close < curr.price)
                 {
                  bear.time = m_candles.GetCandle(bar).time;
                  bear.price = curr.price;
                  bear.bullish = false;
                  bear.bar_index = bar;
                  haveBear = true;
                  break;
                 }
              }
            break;
           }
        }
     }

   // Order by actual recency (smaller bar_index = more recent) rather
   // than a fixed bullish-then-bearish assumption.
   if(haveBull && haveBear)
     {
      if(bull.bar_index <= bear.bar_index)
        {
         m_choch[0] = bull;
         m_choch[1] = bear;
        }
      else
        {
         m_choch[0] = bear;
         m_choch[1] = bull;
        }
      m_count = 2;
     }
   else if(haveBull)
     {
      m_choch[0] = bull;
      m_count = 1;
     }
   else if(haveBear)
     {
      m_choch[0] = bear;
      m_count = 1;
     }
   ArrayResize(m_choch, m_count);
  }
//+------------------------------------------------------------------+
CHOCHPoint CCHOCH::Get(int i) const
  {
   CHOCHPoint empty;
   ZeroMemory(empty);
   if(i < 0 || i >= m_count) return empty;
   return m_choch[i];
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Structure/CHOCH.mqh ----


// ---- BEGIN EA/includes/SmartMoney/FVG.mqh ----
//+------------------------------------------------------------------+
//|                                                SmartMoney/FVG.mqh |
//+------------------------------------------------------------------+
#ifndef FVG_MQH
#define FVG_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----

class CFVG
  {
private:
   CCandleData*      m_candles;
   FVGZone           m_zones[];
   int               m_zoneCount;

   double            m_minSizeATR;   // minimum gap size as fraction of ATR

   void              UpdateState(FVGZone &zone);

public:
                     CFVG();
   void              Init(CCandleData* candleData, double minSizeATR = 0.1);
   void              Detect();
   int               Count() const { return m_zoneCount; }
   FVGZone           GetZone(int i) const; // 0 = most recent
   void              UpdateAllStates();
  };
//+------------------------------------------------------------------+
CFVG::CFVG() : m_candles(NULL), m_zoneCount(0), m_minSizeATR(0.1) {}
void CFVG::Init(CCandleData* candleData, double minSizeATR)
  {
   m_candles = candleData;
   m_minSizeATR = minSizeATR;
  }
//+------------------------------------------------------------------+
void CFVG::Detect()
  {
   m_zoneCount = 0;
   if(m_candles == NULL) return;
   ArrayFree(m_zones);
   int total = m_candles.Total();
   if(total < 3) return;

   // Series-indexed: shift 0 = now. As i runs 2 -> total-1, the 3-bar
   // window {i, i-1, i-2} slides from the most recent triplet toward the
   // oldest. Within a triplet: cd2 = GetCandle(i) is the OLDEST of the
   // three (largest shift); cd0 = GetCandle(i-2) is the NEWEST of the
   // three (smallest shift). (The original comments had this backwards —
   // labels only, the gap-direction math itself was already correct.)
   for(int i = 2; i < total; i++)
     {
      CandleData cd0 = m_candles.GetCandle(i - 2); // newest of the triplet
      CandleData cd1 = m_candles.GetCandle(i - 1); // middle
      CandleData cd2 = m_candles.GetCandle(i);     // oldest of the triplet
      double atr = cd1.atr;
      if(atr <= 0) continue;

      // Bullish FVG: low of the newest candle > high of the oldest candle
      if(cd0.low > cd2.high)
        {
         double gap = cd0.low - cd2.high;
         if(gap >= m_minSizeATR * atr)
           {
            FVGZone zone;
            zone.time = cd1.time;
            zone.top = cd0.low;
            zone.bottom = cd2.high;
            zone.dir = FVG_BULL;
            zone.state = FVG_FRESH;
            zone.width = gap / atr;
            zone.bar_index = i - 1;
            int n = m_zoneCount++;
            ArrayResize(m_zones, m_zoneCount);
            m_zones[n] = zone;
           }
        }
      // Bearish FVG: high of the newest candle < low of the oldest candle
      else if(cd0.high < cd2.low)
        {
         double gap = cd2.low - cd0.high;
         if(gap >= m_minSizeATR * atr)
           {
            FVGZone zone;
            zone.time = cd1.time;
            zone.top = cd2.low;
            zone.bottom = cd0.high;
            zone.dir = FVG_BEAR;
            zone.state = FVG_FRESH;
            zone.width = gap / atr;
            zone.bar_index = i - 1;
            int n = m_zoneCount++;
            ArrayResize(m_zones, m_zoneCount);
            m_zones[n] = zone;
           }
        }
     }
   // NOTE: no reversal needed — the loop runs from the most recent
   // triplet to the oldest, so m_zones[0] is already the most recent
   // zone. (Original code reversed unconditionally here too, which
   // inverted GetZone(0) to the oldest FVG in the whole history window —
   // the same ordering bug as CBOS::Detect().)
  }
//+------------------------------------------------------------------+
void CFVG::UpdateAllStates()
  {
   for(int i = 0; i < m_zoneCount; i++)
      UpdateState(m_zones[i]);
  }
//+------------------------------------------------------------------+
void CFVG::UpdateState(FVGZone &zone)
  {
   if(zone.state == FVG_MITIGATED || zone.state == FVG_INVALIDATED)
      return; // terminal states — nothing to update
   int total = m_candles.Total();
   // Series-indexed newest-first: scan from now (0) backward. Once we
   // reach a bar older than the zone's creation time we can stop —
   // everything beyond that is even older (was "continue" in the
   // original, forcing a full unnecessary scan of the whole history
   // buffer on every OnCalculate call, for every zone).
   for(int bar = 0; bar < total; bar++)
     {
      CandleData cd = m_candles.GetCandle(bar);
      if(cd.time < zone.time)
         break;
      if(zone.dir == FVG_BULL)
        {
         if(cd.low <= zone.top && cd.high >= zone.bottom)
           {
            if(cd.close >= zone.top)
               zone.state = FVG_MITIGATED;
            else if(zone.state == FVG_FRESH)
               zone.state = FVG_TESTED;
           }
        }
      else
        {
         if(cd.high >= zone.bottom && cd.low <= zone.top)
           {
            if(cd.close <= zone.bottom)
               zone.state = FVG_MITIGATED;
            else if(zone.state == FVG_FRESH)
               zone.state = FVG_TESTED;
           }
        }
     }
  }
//+------------------------------------------------------------------+
FVGZone CFVG::GetZone(int i) const
  {
   FVGZone empty;
   ZeroMemory(empty);
   if(i < 0 || i >= m_zoneCount) return empty;
   return m_zones[i];
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/SmartMoney/FVG.mqh ----


// ---- BEGIN EA/includes/SmartMoney/Liquidity.mqh ----
//+------------------------------------------------------------------+
//|                                            SmartMoney/Liquidity.mqh |
//+------------------------------------------------------------------+
#ifndef LIQUIDITY_MQH
#define LIQUIDITY_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----


// ---- BEGIN EA/includes/Structure/SwingDetector.mqh ----

// ---- END EA/includes/Structure/SwingDetector.mqh ----

class CLiquidity
  {
private:
   CCandleData*      m_candles;
   CSwingDetector*   m_swings;
   double            m_internalThresholdATR;

   LiquidityPool     m_pools[];   // FINAL/current-state pools (all data known) — for display/GetPool() only
   int               m_poolCount;
   LiquidityEvent    m_events[];
   int               m_eventCount;

   void              BuildInternalPools();  // final-state pools, for GetPool()/dashboard display
   void              BuildExternalPools();  // final-state "yesterday" pool, for GetPool()/dashboard display
   void              DetectSweeps();

public:
                     CLiquidity();
   void              Init(CCandleData* candles, CSwingDetector* swings, double internalThresholdATR = 0.2);
   void              Detect();
   int               PoolCount() const { return m_poolCount; }
   LiquidityPool     GetPool(int i) const;
   int               EventCount() const { return m_eventCount; }
   LiquidityEvent    GetEvent(int i) const; // 0 = most recent
   // Convenience wrappers for the Inducement/Scoring engines — "was the
   // most recent sweep of this kind within N bars?" without every caller
   // re-deriving it from raw events.
   bool              HasInternalSweep(int recencyBars, ENUM_LIQ_TYPE &outType, double &outStrength, int &outBarIndex);
   bool              HasExternalSweep(int recencyBars, ENUM_LIQ_TYPE &outType, double &outStrength, int &outBarIndex);
  };
//+------------------------------------------------------------------+
CLiquidity::CLiquidity() : m_candles(NULL), m_swings(NULL), m_internalThresholdATR(0.2), m_poolCount(0), m_eventCount(0) {}
void CLiquidity::Init(CCandleData* candles, CSwingDetector* swings, double internalThresholdATR)
  {
   m_candles = candles;
   m_swings = swings;
   m_internalThresholdATR = internalThresholdATR;
  }
//+------------------------------------------------------------------+
// FINAL-STATE pool list, built from the complete, current swing data —
// this is intentionally "everything we know today" and is only used for
// GetPool()/PoolCount() (dashboard, current-analysis display). It is NOT
// used for historical sweep detection — see DetectSweeps() below, which
// rebuilds pools chronologically bar-by-bar to avoid lookahead.
void CLiquidity::BuildInternalPools()
  {
   int hc = m_swings.HighCount();
   for(int i = 0; i < hc - 1; i++)
     {
      SwingPoint a = m_swings.GetHigh(i);
      double atr = m_candles.GetATR(a.bar_index);
      double band = m_internalThresholdATR * atr;
      for(int j = i + 1; j < hc; j++)
        {
         SwingPoint b = m_swings.GetHigh(j);
         if(MathAbs(a.price - b.price) <= band)
           {
            LiquidityPool pool;
            pool.price_top = MathMax(a.price, b.price);
            pool.price_bottom = MathMin(a.price, b.price);
            pool.type = LIQ_BUY_SIDE;
            pool.touches = 2;
            pool.external = false;
            pool.confirmed_at_shift = 0;
            bool exists = false;
            for(int k = 0; k < m_poolCount; k++)
              {
               if(!m_pools[k].external && m_pools[k].type == pool.type &&
                  MathAbs(m_pools[k].price_top - pool.price_top) < band)
                 {
                  m_pools[k].touches++;
                  exists = true;
                  break;
                 }
              }
            if(!exists)
              {
               int n = m_poolCount++;
               ArrayResize(m_pools, m_poolCount);
               m_pools[n] = pool;
              }
           }
        }
     }
   int lc = m_swings.LowCount();
   for(int i = 0; i < lc - 1; i++)
     {
      SwingPoint a = m_swings.GetLow(i);
      double atr = m_candles.GetATR(a.bar_index);
      double band = m_internalThresholdATR * atr;
      for(int j = i + 1; j < lc; j++)
        {
         SwingPoint b = m_swings.GetLow(j);
         if(MathAbs(a.price - b.price) <= band)
           {
            LiquidityPool pool;
            pool.price_top = MathMax(a.price, b.price);
            pool.price_bottom = MathMin(a.price, b.price);
            pool.type = LIQ_SELL_SIDE;
            pool.touches = 2;
            pool.external = false;
            pool.confirmed_at_shift = 0;
            bool exists = false;
            for(int k = 0; k < m_poolCount; k++)
              {
               if(!m_pools[k].external && m_pools[k].type == pool.type &&
                  MathAbs(m_pools[k].price_bottom - pool.price_bottom) < band)
                 {
                  m_pools[k].touches++;
                  exists = true;
                  break;
                 }
              }
            if(!exists)
              {
               int n = m_poolCount++;
               ArrayResize(m_pools, m_poolCount);
               m_pools[n] = pool;
              }
           }
        }
     }
  }
//+------------------------------------------------------------------+
void CLiquidity::BuildExternalPools()
  {
   if(m_candles == NULL) return;
   string sym = m_candles.Symbol();
   double dayHigh = iHigh(sym, PERIOD_D1, 1);
   double dayLow  = iLow(sym, PERIOD_D1, 1);
   if(dayHigh > 0)
     {
      LiquidityPool pool;
      pool.price_top = dayHigh;
      pool.price_bottom = dayHigh;
      pool.type = LIQ_BUY_SIDE;
      pool.touches = 1;
      pool.external = true;
      pool.confirmed_at_shift = 0;
      int n = m_poolCount++;
      ArrayResize(m_pools, m_poolCount);
      m_pools[n] = pool;
     }
   if(dayLow > 0)
     {
      LiquidityPool pool;
      pool.price_top = dayLow;
      pool.price_bottom = dayLow;
      pool.type = LIQ_SELL_SIDE;
      pool.touches = 1;
      pool.external = true;
      pool.confirmed_at_shift = 0;
      int n = m_poolCount++;
      ArrayResize(m_pools, m_poolCount);
      m_pools[n] = pool;
     }
  }
//+------------------------------------------------------------------+
// FIX (audit #11 — lookahead bias): the previous version built pools
// from the CURRENT, fully up-to-date swing list — "swing A + swing B
// exist" using every swing ever detected, including ones that formed
// AFTER a given historical bar — and then scanned ALL of history for
// sweeps of those pools. A candle from months ago could get flagged as
// "sweeping" a pool that, at the time, didn't exist yet (its second
// component swing hadn't happened). Correct chronology is: swing A +
// swing B both confirmed -> pool exists -> THEN a later bar can sweep
// it. This function enforces exactly that using LiquidityPool's new
// confirmed_at_shift field: a candidate sweep at `bar` is only tested
// against an internal pool if `bar <= pool.confirmed_at_shift` (the pool
// must already have existed as of that bar).
//
// External (daily high/low) pools have the SAME problem in a different
// form: a single static "yesterday's high/low" computed from TODAY's
// perspective was being used to test sweep candles from arbitrary points
// in history — but "yesterday" is a different level every day. Fixed by
// computing each candle's own actual prior trading day's D1 high/low at
// scan time instead of using one fixed pair of levels for all of history.
void CLiquidity::DetectSweeps()
  {
   m_eventCount = 0;
   if(m_candles == NULL || m_swings == NULL) return;
   ArrayFree(m_events);
   int total = m_candles.Total();
   int strength = m_swings.Strength();
   string sym = m_candles.Symbol();

   // --- Internal pools: rebuild WITH confirmation-shift tagging ---
   LiquidityPool internalPools[];
   int internalCount = 0;
   int hc = m_swings.HighCount();
   for(int i = 0; i < hc - 1; i++)
     {
      SwingPoint a = m_swings.GetHigh(i);
      double atrA = m_candles.GetATR(a.bar_index);
      double band = m_internalThresholdATR * atrA;
      for(int j = i + 1; j < hc; j++)
        {
         SwingPoint b = m_swings.GetHigh(j);
         if(MathAbs(a.price - b.price) <= band)
           {
            LiquidityPool pool;
            pool.price_top = MathMax(a.price, b.price);
            pool.price_bottom = MathMin(a.price, b.price);
            pool.type = LIQ_BUY_SIDE;
            pool.touches = 2;
            pool.external = false;
            // Pool only valid once BOTH swings are confirmed — that's the
            // LATER of the two confirmations, i.e. the smaller (more
            // recent) confirm_shift value.
            pool.confirmed_at_shift = MathMin(a.bar_index - strength, b.bar_index - strength);
            int n = internalCount++;
            ArrayResize(internalPools, internalCount);
            internalPools[n] = pool;
           }
        }
     }
   int lc = m_swings.LowCount();
   for(int i = 0; i < lc - 1; i++)
     {
      SwingPoint a = m_swings.GetLow(i);
      double atrA = m_candles.GetATR(a.bar_index);
      double band = m_internalThresholdATR * atrA;
      for(int j = i + 1; j < lc; j++)
        {
         SwingPoint b = m_swings.GetLow(j);
         if(MathAbs(a.price - b.price) <= band)
           {
            LiquidityPool pool;
            pool.price_top = MathMax(a.price, b.price);
            pool.price_bottom = MathMin(a.price, b.price);
            pool.type = LIQ_SELL_SIDE;
            pool.touches = 2;
            pool.external = false;
            pool.confirmed_at_shift = MathMin(a.bar_index - strength, b.bar_index - strength);
            int n = internalCount++;
            ArrayResize(internalPools, internalCount);
            internalPools[n] = pool;
           }
        }
     }

   for(int i = 0; i < internalCount; i++)
     {
      for(int bar = 1; bar < total - 2; bar++)
        {
         if(bar > internalPools[i].confirmed_at_shift) continue; // FIX #11: pool didn't exist yet at this bar
         CandleData cd = m_candles.GetCandle(bar);
         double atr = m_candles.GetATR(bar);
         if(atr <= 0) continue;

         if(internalPools[i].type == LIQ_BUY_SIDE)
           {
            if(cd.high > internalPools[i].price_top && cd.close < internalPools[i].price_bottom)
              {
               double penetration = (cd.high - internalPools[i].price_top) / atr;
               LiquidityEvent ev;
               ev.time = cd.time;
               ev.price = internalPools[i].price_top;
               ev.type = LIQ_BUY_SIDE;
               ev.strength = MathMax(0.0, MathMin(penetration / 0.5, 1.0));
               ev.swept = true;
               ev.bar_index = bar;
               ev.external = false;
               int n = m_eventCount++;
               ArrayResize(m_events, m_eventCount);
               m_events[n] = ev;
               break;
              }
           }
         else
           {
            if(cd.low < internalPools[i].price_bottom && cd.close > internalPools[i].price_top)
              {
               double penetration = (internalPools[i].price_bottom - cd.low) / atr;
               LiquidityEvent ev;
               ev.time = cd.time;
               ev.price = internalPools[i].price_bottom;
               ev.type = LIQ_SELL_SIDE;
               ev.strength = MathMax(0.0, MathMin(penetration / 0.5, 1.0));
               ev.swept = true;
               ev.bar_index = bar;
               ev.external = false;
               int n = m_eventCount++;
               ArrayResize(m_events, m_eventCount);
               m_events[n] = ev;
               break;
              }
           }
        }
     }

   // --- External pools: each candle tested against ITS OWN prior trading
   // day's D1 high/low, not today's, via iBarShift — chronologically
   // correct by construction, no static level reused across all of history.
   int lastD1Shift = -1;
   double d1High = 0.0, d1Low = 0.0;
   for(int bar = 1; bar < total - 2; bar++)
     {
      CandleData cd = m_candles.GetCandle(bar);
      double atr = m_candles.GetATR(bar);
      if(atr <= 0) continue;

      int d1Shift = iBarShift(sym, PERIOD_D1, cd.time);
      if(d1Shift < 0) continue; // no daily data this far back
      if(d1Shift != lastD1Shift) // only refetch when we cross a day boundary — cheap
        {
         d1High = iHigh(sym, PERIOD_D1, d1Shift + 1); // the PRIOR day relative to this bar's own day
         d1Low  = iLow(sym, PERIOD_D1, d1Shift + 1);
         lastD1Shift = d1Shift;
        }

      if(d1High > 0 && cd.high > d1High && cd.close < d1High)
        {
         double penetration = (cd.high - d1High) / atr;
         LiquidityEvent ev;
         ev.time = cd.time;
         ev.price = d1High;
         ev.type = LIQ_BUY_SIDE;
         ev.strength = MathMax(0.0, MathMin(penetration / 0.5, 1.0));
         ev.swept = true;
         ev.bar_index = bar;
         ev.external = true;
         int n = m_eventCount++;
         ArrayResize(m_events, m_eventCount);
         m_events[n] = ev;
        }
      if(d1Low > 0 && cd.low < d1Low && cd.close > d1Low)
        {
         double penetration = (d1Low - cd.low) / atr;
         LiquidityEvent ev;
         ev.time = cd.time;
         ev.price = d1Low;
         ev.type = LIQ_SELL_SIDE;
         ev.strength = MathMax(0.0, MathMin(penetration / 0.5, 1.0));
         ev.swept = true;
         ev.bar_index = bar;
         ev.external = true;
         int n = m_eventCount++;
         ArrayResize(m_events, m_eventCount);
         m_events[n] = ev;
        }
     }

   // Order events most-recent-first for downstream consumers (Scoring
   // wants "did a sweep just happen", not "did one ever happen").
   for(int a = 0; a < m_eventCount - 1; a++)
      for(int b = a + 1; b < m_eventCount; b++)
         if(m_events[b].bar_index < m_events[a].bar_index)
           {
            LiquidityEvent t = m_events[a];
            m_events[a] = m_events[b];
            m_events[b] = t;
           }
  }
//+------------------------------------------------------------------+
void CLiquidity::Detect()
  {
   m_poolCount = 0;
   if(m_candles == NULL || m_swings == NULL) return;
   ArrayFree(m_pools);
   BuildInternalPools();   // final-state, for display only
   BuildExternalPools();   // final-state, for display only
   DetectSweeps();         // chronologically rebuilt internally — see above
  }
LiquidityPool CLiquidity::GetPool(int i) const { if(i<0||i>=m_poolCount) { LiquidityPool e; ZeroMemory(e); return e; } return m_pools[i]; }
LiquidityEvent CLiquidity::GetEvent(int i) const { if(i<0||i>=m_eventCount) { LiquidityEvent e; ZeroMemory(e); return e; } return m_events[i]; }
//+------------------------------------------------------------------+
bool CLiquidity::HasInternalSweep(int recencyBars, ENUM_LIQ_TYPE &outType, double &outStrength, int &outBarIndex)
  {
   for(int i = 0; i < m_eventCount; i++)
     {
      if(m_events[i].external) continue;
      if(m_events[i].bar_index > recencyBars) continue;
      outType = m_events[i].type;
      outStrength = m_events[i].strength;
      outBarIndex = m_events[i].bar_index;
      return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
bool CLiquidity::HasExternalSweep(int recencyBars, ENUM_LIQ_TYPE &outType, double &outStrength, int &outBarIndex)
  {
   for(int i = 0; i < m_eventCount; i++)
     {
      if(!m_events[i].external) continue;
      if(m_events[i].bar_index > recencyBars) continue;
      outType = m_events[i].type;
      outStrength = m_events[i].strength;
      outBarIndex = m_events[i].bar_index;
      return true;
     }
   return false;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/SmartMoney/Liquidity.mqh ----


// ---- BEGIN EA/includes/SmartMoney/SupportResistance.mqh ----
//+------------------------------------------------------------------+
//|                                     SmartMoney/SupportResistance.mqh |
//+------------------------------------------------------------------+
#ifndef SUPPORTRESISTANCE_MQH
#define SUPPORTRESISTANCE_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----


// ---- BEGIN EA/includes/Structure/SwingDetector.mqh ----

// ---- END EA/includes/Structure/SwingDetector.mqh ----

class CSupportResistance
  {
private:
   CCandleData*      m_candles;
   CSwingDetector*   m_swings;
   SRZone            m_zones[];
   int               m_zoneCount;

public:
                     CSupportResistance();
   void              Init(CCandleData* candles, CSwingDetector* swings);
   void              Detect();
   int               Count() const { return m_zoneCount; }
   SRZone            GetZone(int i) const; // 0 = strongest (most touches)
  };
//+------------------------------------------------------------------+
CSupportResistance::CSupportResistance() : m_candles(NULL), m_swings(NULL), m_zoneCount(0) {}
void CSupportResistance::Init(CCandleData* candles, CSwingDetector* swings)
  {
   m_candles = candles;
   m_swings = swings;
  }
//+------------------------------------------------------------------+
void CSupportResistance::Detect()
  {
   m_zoneCount = 0;
   if(m_swings == NULL || m_candles == NULL) return;
   ArrayFree(m_zones);

   // Cluster swing highs into resistance zones
   int hc = m_swings.HighCount();
   for(int i = 0; i < hc; i++)
     {
      SwingPoint sp = m_swings.GetHigh(i);
      double atr = m_candles.GetATR(sp.bar_index);
      double band = 0.3 * atr;
      bool added = false;
      for(int j = 0; j < m_zoneCount; j++)
        {
         // FIX: original didn't check zone type here, so this only
         // worked "by accident" because support zones hadn't been added
         // yet at this point in execution. Explicit type check now.
         bool isResistance = (m_zones[j].type == SR_MAJOR_RESISTANCE || m_zones[j].type == SR_MINOR_RESISTANCE);
         if(isResistance && MathAbs(sp.price - m_zones[j].top) <= band)
           {
            m_zones[j].touches++;
            m_zones[j].top = MathMax(m_zones[j].top, sp.price);
            m_zones[j].bottom = MathMin(m_zones[j].bottom, sp.price);
            if(m_zones[j].touches >= 3)
               m_zones[j].type = SR_MAJOR_RESISTANCE;
            added = true;
            break;
           }
        }
      if(!added)
        {
         SRZone zone;
         zone.top = sp.price;
         zone.bottom = sp.price;
         zone.type = (sp.strength > 0.5) ? SR_MAJOR_RESISTANCE : SR_MINOR_RESISTANCE;
         zone.touches = 1;
         zone.startTime = sp.time;
         int n = m_zoneCount++;
         ArrayResize(m_zones, m_zoneCount);
         m_zones[n] = zone;
        }
     }
   // Cluster swing lows into support zones
   int lc = m_swings.LowCount();
   for(int i = 0; i < lc; i++)
     {
      SwingPoint sp = m_swings.GetLow(i);
      double atr = m_candles.GetATR(sp.bar_index);
      double band = 0.3 * atr;
      bool added = false;
      for(int j = 0; j < m_zoneCount; j++)
        {
         bool isSupport = (m_zones[j].type == SR_MAJOR_SUPPORT || m_zones[j].type == SR_MINOR_SUPPORT);
         if(isSupport && MathAbs(sp.price - m_zones[j].bottom) <= band)
           {
            m_zones[j].touches++;
            m_zones[j].top = MathMax(m_zones[j].top, sp.price);
            m_zones[j].bottom = MathMin(m_zones[j].bottom, sp.price);
            if(m_zones[j].touches >= 3)
               m_zones[j].type = SR_MAJOR_SUPPORT;
            added = true;
            break;
           }
        }
      if(!added)
        {
         SRZone zone;
         zone.top = sp.price;
         zone.bottom = sp.price;
         zone.type = (sp.strength > 0.5) ? SR_MAJOR_SUPPORT : SR_MINOR_SUPPORT;
         zone.touches = 1;
         zone.startTime = sp.time;
         int n = m_zoneCount++;
         ArrayResize(m_zones, m_zoneCount);
         m_zones[n] = zone;
        }
     }
   // FIX: original did an unconditional "reverse to have most recent
   // first" here, but S/R zones aren't a time-ordered event log — the
   // touches accumulate across the whole scan, so "most recent" isn't a
   // meaningful concept for them. Sorting by touch count puts the
   // strongest, most confluence-backed zones first, which is what
   // scoring/trade logic actually wants.
   for(int a = 0; a < m_zoneCount - 1; a++)
      for(int b = a + 1; b < m_zoneCount; b++)
         if(m_zones[b].touches > m_zones[a].touches)
           {
            SRZone t = m_zones[a];
            m_zones[a] = m_zones[b];
            m_zones[b] = t;
           }
  }
SRZone CSupportResistance::GetZone(int i) const { if(i<0||i>=m_zoneCount) { SRZone e; ZeroMemory(e); return e; } return m_zones[i]; }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/SmartMoney/SupportResistance.mqh ----


// ---- BEGIN EA/includes/SmartMoney/VolumeEngine.mqh ----
//+------------------------------------------------------------------+
//|                                       SmartMoney/VolumeEngine.mqh |
//+------------------------------------------------------------------+
#ifndef VOLUMEENGINE_MQH
#define VOLUMEENGINE_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----

// Volume Engine — answers "is this move supported by participation?"
// Per spec: volume is a FILTER/VALIDATOR, never a signal generator on its
// own. Relative Volume (RVOL) compares a bar's volume against its own
// recent average; a breakout with low RVOL is treated as unsupported and
// gated out in Scoring.mqh rather than scored up.
//
// CAVEAT: MT5's tick_volume is a count of price changes, not necessarily
// broker-reported traded volume (real Volume is feed-dependent and often
// absent on FX symbols). RVOL here is always computed from tick_volume —
// a reasonable participation proxy on most FX/CFD symbols, but treat it
// as directional evidence, not an exact volume reading.
class CVolumeEngine
  {
private:
   CCandleData*      m_candles;
   int               m_lookback;      // bars averaged for the RVOL baseline

public:
                     CVolumeEngine();
   void              Init(CCandleData* candles, int lookback = 20);

   // Mean tick_volume over the `lookback` bars immediately BEFORE `shift`
   // (i.e. [shift+1 .. shift+lookback]) — deliberately excludes the bar
   // being measured so a spike can't inflate its own baseline.
   double            AverageVolume(int shift, int lookback) const;
   double            RVOL(int shift = 0) const;                 // tick_volume[shift] / AverageVolume(shift, m_lookback)
   bool              IsSpike(int shift = 0, double thresholdMult = 1.5) const;

   // Mirrors the spec's BOS validation rule: "Body > 0.5*ATR AND RVOL >= threshold"
   // CONFIRMATION filter (see gate convention, Core/Config.mqh) — fails
   // closed on purpose: no candles/ATR means nothing to confirm.
   bool              ConfirmsBreakout(int shift, double atr, double bodyRatioMin = 0.5, double rvolThreshold = 1.5) const;

   // 0-1 normalized score for confluence ranking/diagnostics only — NOT
   // used to manufacture confidence on its own. See the gating discipline
   // note in Analysis/Scoring.mqh.
   double            Score(int shift = 0, double rvolThreshold = 1.5) const;
  };
//+------------------------------------------------------------------+
CVolumeEngine::CVolumeEngine() : m_candles(NULL), m_lookback(20) {}
//+------------------------------------------------------------------+
void CVolumeEngine::Init(CCandleData* candles, int lookback)
  {
   m_candles = candles;
   m_lookback = MathMax(5, lookback);
  }
//+------------------------------------------------------------------+
double CVolumeEngine::AverageVolume(int shift, int lookback) const
  {
   if(m_candles == NULL) return 0.0;
   int total = m_candles.Total();
   double sum = 0.0;
   int count = 0;
   for(int i = shift + 1; i <= shift + lookback && i < total; i++)
     {
      sum += (double)m_candles.GetCandle(i).tick_volume;
      count++;
     }
   if(count == 0) return 0.0;
   return sum / count;
  }
//+------------------------------------------------------------------+
double CVolumeEngine::RVOL(int shift) const
  {
   if(m_candles == NULL || shift < 0 || shift >= m_candles.Total()) return 0.0;
   double avg = AverageVolume(shift, m_lookback);
   if(avg <= 0) return 0.0;
   double v = (double)m_candles.GetCandle(shift).tick_volume;
   return v / avg;
  }
//+------------------------------------------------------------------+
bool CVolumeEngine::IsSpike(int shift, double thresholdMult) const
  {
   return RVOL(shift) >= thresholdMult;
  }
//+------------------------------------------------------------------+
bool CVolumeEngine::ConfirmsBreakout(int shift, double atr, double bodyRatioMin, double rvolThreshold) const
  {
   if(m_candles == NULL || atr <= 0) return false;
   CandleData cd = m_candles.GetCandle(shift);
   double body = MathAbs(cd.close - cd.open);
   if(body < bodyRatioMin * atr) return false;
   return RVOL(shift) >= rvolThreshold;
  }
//+------------------------------------------------------------------+
double CVolumeEngine::Score(int shift, double rvolThreshold) const
  {
   double r = RVOL(shift);
   if(r <= 0 || rvolThreshold <= 0) return 0.0;
   // Linear ramp: 0 at RVOL=0, 1.0 at RVOL == 2x threshold, capped —
   // gives a smooth confluence weight instead of a hard step once past
   // the gating threshold.
   double score = r / (2.0 * rvolThreshold);
   return MathMin(MathMax(score, 0.0), 1.0);
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/SmartMoney/VolumeEngine.mqh ----


// ---- BEGIN EA/includes/SmartMoney/FibonacciEngine.mqh ----
//+------------------------------------------------------------------+
//|                                    SmartMoney/FibonacciEngine.mqh |
//+------------------------------------------------------------------+
#ifndef FIBONACCIENGINE_MQH
#define FIBONACCIENGINE_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----


// ---- BEGIN EA/includes/Structure/SwingDetector.mqh ----

// ---- END EA/includes/Structure/SwingDetector.mqh ----

// Fibonacci Engine — a LOCATION filter, never a signal generator. Anchors
// come only from confirmed swing highs/lows produced by CSwingDetector;
// manual anchor selection is deliberately not exposed anywhere in this
// class. For an uptrend leg: 0% retracement = the confirmed swing high,
// 100% = the confirmed swing low it retraced from (mirrored for a
// downtrend leg). Levels are always computed fresh from the live swing
// series — nothing here is cached or hand-placed.
struct FibLeg
  {
   bool              valid;
   bool              bullish;     // true = uptrend leg (retracement measured down from the high)
   double            lowPrice;
   double            highPrice;
   datetime          lowTime;
   datetime          highTime;
   int               lowBar;
   int               highBar;
  };

class CFibonacciEngine
  {
private:
   CSwingDetector*   m_swings;
   CCandleData*      m_candles;

   bool              FindLeg(bool forBuy, FibLeg &out) const;
   double            LevelPrice(const FibLeg &leg, double pct) const;

public:
                     CFibonacciEngine();
   void              Init(CSwingDetector* swings, CCandleData* candles);

   // CONFIRMATION filter (see gate convention, Core/Config.mqh) — fails
   // closed on purpose: no confirmed swing pair means no leg to measure.
   bool              GetLeg(bool forBuy, FibLeg &out) const { return FindLeg(forBuy, out); }
   double            RetracementPct(bool forBuy, double price) const; // 0 at the impulse extreme, 100 at the leg's origin, -1 if no leg
   ENUM_FIB_ZONE     Zone(bool forBuy, double price) const;
   bool              InPullbackZone(bool forBuy, double price, double zoneMinPct = 50.0, double zoneMaxPct = 61.8) const;
   double            NearestLevel(bool forBuy, double price, double &pctOut) const; // price of nearest of {38.2, 50, 61.8, 78.6}

   // 0-1 confluence score: 1.0 inside [zoneMinPct, zoneMaxPct], decaying
   // to 0 by the 38.2%/78.6% guard rails outside it. Diagnostic/ranking
   // only — see the gating discipline note in Analysis/Scoring.mqh.
   double            Score(bool forBuy, double price, double zoneMinPct = 50.0, double zoneMaxPct = 61.8) const;
  };
//+------------------------------------------------------------------+
CFibonacciEngine::CFibonacciEngine() : m_swings(NULL), m_candles(NULL) {}
//+------------------------------------------------------------------+
void CFibonacciEngine::Init(CSwingDetector* swings, CCandleData* candles)
  {
   m_swings = swings;
   m_candles = candles;
  }
//+------------------------------------------------------------------+
// forBuy (uptrend leg): anchor on the most recent confirmed swing high,
// then the nearest confirmed swing low OLDER than it (the low that
// started the impulse leg ending at that high).
// forBuy == false (downtrend leg): mirrored — most recent swing low, and
// the nearest older swing high that started the down-leg.
// NOTE: series convention (matches SwingDetector.mqh) — index 0 is the
// most recent point, and a LARGER bar_index means an OLDER bar.
bool CFibonacciEngine::FindLeg(bool forBuy, FibLeg &out) const
  {
   ZeroMemory(out);
   if(m_swings == NULL) return false;
   if(m_swings.HighCount() == 0 || m_swings.LowCount() == 0) return false;

   if(forBuy)
     {
      SwingPoint hi = m_swings.GetHigh(0);
      bool found = false;
      SwingPoint bestLow;
      for(int i = 0; i < m_swings.LowCount(); i++)
        {
         SwingPoint lo = m_swings.GetLow(i);
         if(lo.bar_index > hi.bar_index)          // older than the high
           {
            if(!found || lo.bar_index < bestLow.bar_index) { bestLow = lo; found = true; }
           }
        }
      if(!found) return false;
      out.valid = true;
      out.bullish = true;
      out.lowPrice = bestLow.price;
      out.highPrice = hi.price;
      out.lowTime = bestLow.time;
      out.highTime = hi.time;
      out.lowBar = bestLow.bar_index;
      out.highBar = hi.bar_index;
      return true;
     }
   else
     {
      SwingPoint lo = m_swings.GetLow(0);
      bool found = false;
      SwingPoint bestHigh;
      for(int i = 0; i < m_swings.HighCount(); i++)
        {
         SwingPoint hi2 = m_swings.GetHigh(i);
         if(hi2.bar_index > lo.bar_index)         // older than the low
           {
            if(!found || hi2.bar_index < bestHigh.bar_index) { bestHigh = hi2; found = true; }
           }
        }
      if(!found) return false;
      out.valid = true;
      out.bullish = false;
      out.lowPrice = lo.price;
      out.highPrice = bestHigh.price;
      out.lowTime = lo.time;
      out.highTime = bestHigh.time;
      out.lowBar = lo.bar_index;
      out.highBar = bestHigh.bar_index;
      return true;
     }
  }
//+------------------------------------------------------------------+
// pct is a retracement percentage (0-100): 0 = the impulse extreme (the
// high in an uptrend leg, the low in a downtrend leg), 100 = the leg's
// origin.
double CFibonacciEngine::LevelPrice(const FibLeg &leg, double pct) const
  {
   double range = leg.highPrice - leg.lowPrice;
   double frac = pct / 100.0;
   if(leg.bullish)
      return leg.highPrice - frac * range;   // retracing down from the high
   else
      return leg.lowPrice + frac * range;    // retracing up from the low
  }
//+------------------------------------------------------------------+
double CFibonacciEngine::RetracementPct(bool forBuy, double price) const
  {
   FibLeg leg;
   if(!FindLeg(forBuy, leg)) return -1.0;
   double range = leg.highPrice - leg.lowPrice;
   if(range <= 0) return -1.0;
   double pct = leg.bullish ? (leg.highPrice - price) / range * 100.0
                            : (price - leg.lowPrice) / range * 100.0;
   return pct;
  }
//+------------------------------------------------------------------+
// Discount = price has pulled back deep into the leg (cheap relative to
// the impulse — favorable for the trend direction). Premium = still
// shallow / close to the impulse extreme (expensive). Matches the same
// discount/premium vocabulary SmartMoney/PremiumDiscount.mqh uses for the
// (separate) inducement-leg gate — this one is swing-anchored, that one
// is impulse-anchored; they will usually agree but are not the same leg.
ENUM_FIB_ZONE CFibonacciEngine::Zone(bool forBuy, double price) const
  {
   double pct = RetracementPct(forBuy, price);
   if(pct < 0) return FIB_ZONE_UNDEFINED;
   if(pct >= 61.8) return FIB_ZONE_DISCOUNT;
   if(pct >= 38.2) return FIB_ZONE_NEUTRAL;
   return FIB_ZONE_PREMIUM;
  }
//+------------------------------------------------------------------+
bool CFibonacciEngine::InPullbackZone(bool forBuy, double price, double zoneMinPct, double zoneMaxPct) const
  {
   double pct = RetracementPct(forBuy, price);
   if(pct < 0) return false;
   double lo = MathMin(zoneMinPct, zoneMaxPct);
   double hi = MathMax(zoneMinPct, zoneMaxPct);
   return (pct >= lo && pct <= hi);
  }
//+------------------------------------------------------------------+
double CFibonacciEngine::NearestLevel(bool forBuy, double price, double &pctOut) const
  {
   FibLeg leg;
   if(!FindLeg(forBuy, leg)) { pctOut = -1.0; return 0.0; }
   double levels[4] = {38.2, 50.0, 61.8, 78.6};
   double bestDist = -1.0;
   double bestPrice = 0.0;
   double bestPct = -1.0;
   for(int i = 0; i < 4; i++)
     {
      double lvlPrice = LevelPrice(leg, levels[i]);
      double dist = MathAbs(price - lvlPrice);
      if(bestDist < 0 || dist < bestDist) { bestDist = dist; bestPrice = lvlPrice; bestPct = levels[i]; }
     }
   pctOut = bestPct;
   return bestPrice;
  }
//+------------------------------------------------------------------+
double CFibonacciEngine::Score(bool forBuy, double price, double zoneMinPct, double zoneMaxPct) const
  {
   double pct = RetracementPct(forBuy, price);
   if(pct < 0) return 0.0;
   double lo = MathMin(zoneMinPct, zoneMaxPct);
   double hi = MathMax(zoneMinPct, zoneMaxPct);
   if(pct >= lo && pct <= hi) return 1.0;

   if(pct < lo)
     {
      double floor = 38.2;
      if(pct <= floor) return 0.0;
      return (pct - floor) / (lo - floor);
     }
   else
     {
      double ceilPct = 78.6;
      if(pct >= ceilPct) return 0.0;
      return (ceilPct - pct) / (ceilPct - hi);
     }
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/SmartMoney/FibonacciEngine.mqh ----


// ---- BEGIN EA/includes/SmartMoney/ValueAreaEngine.mqh ----
//+------------------------------------------------------------------+
//|                                    SmartMoney/ValueAreaEngine.mqh |
//+------------------------------------------------------------------+
#ifndef VALUEAREAENGINE_MQH
#define VALUEAREAENGINE_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----

// Value Area Engine — "is price cheap or expensive relative to where
// most trading actually happened recently?" A location filter, same
// discipline as Volume and Fibonacci: it never generates a signal, it
// only says whether the price a setup wants to trade at sits inside,
// below, or above the recent Value Area.
//
// Standard volume-profile construction:
//   1. Bucket the lookback window's high/low range into N price bins.
//   2. Distribute each bar's volume across every bin its range touches
//      (evenly split across touched bins — an approximation, since MT5
//      doesn't expose true intrabar trade-price volume without a tick
//      history feed; see the caveat below).
//   3. POC = the bin with the most accumulated volume.
//   4. Value Area = POC bin, expanded outward one bin at a time — always
//      toward whichever neighboring bin (above or below the current
//      envelope) carries more volume — until the accumulated volume
//      reaches valueAreaPercent (default 70%, the standard Market
//      Profile convention) of the window's total.
//
// CAVEAT: this is a bar-range approximation of a true tick-built volume
// profile. It distributes each bar's tick_volume uniformly across the
// bins its (low, high) span touches, which is standard practice for
// building a profile from OHLCV bars but is not the same as a profile
// built from actual trade prints. Treat POC/VAH/VAL as a location
// estimate, not an exact figure — same epistemic status as RVOL's
// tick_volume proxy in VolumeEngine.mqh.
class CValueAreaEngine
  {
private:
   CCandleData*      m_candles;
   int               m_lookbackBars;
   int               m_numBins;
   double            m_valueAreaPercent;   // fraction 0-1, e.g. 0.70

   bool              m_valid;
   double            m_poc;
   double            m_vah;
   double            m_val;
   datetime          m_lastBarTime;        // avoids recomputing the profile more than once per bar

public:
                     CValueAreaEngine();
   void              Init(CCandleData* candles, int lookbackBars = 100, int numBins = 24, double valueAreaPercent = 0.70);
   void              Compute(bool forceRecompute = false);

   bool              IsValid() const { return m_valid; }
   double            POC() const { return m_poc; }
   double            VAH() const { return m_vah; }
   double            VAL() const { return m_val; }

   ENUM_VALUE_AREA_ZONE Zone(double price) const;
   // BUY: price at/below VAH (inside or below Value Area — "discount").
   // SELL: price at/above VAL (inside or above Value Area — "premium").
   // Mirrors the doc's Final Entry Rule: "Price below or within Value
   // Area." Returns true (don't block) if no valid profile exists yet.
   // LOCATION filter (see gate convention, Core/Config.mqh) — fails open
   // for the same reason as CPremiumDiscount::OK(): no profile, no wrong side.
   bool              LocationOK(bool forBuy, double price) const;

   // 0-1 confluence score for ranking only — 1.0 at POC, decaying to 0 at
   // the far edge of the Value Area, 0 outside it entirely.
   double            Score(bool forBuy, double price) const;
  };
//+------------------------------------------------------------------+
CValueAreaEngine::CValueAreaEngine() : m_candles(NULL), m_lookbackBars(100), m_numBins(24),
                                        m_valueAreaPercent(0.70), m_valid(false),
                                        m_poc(0.0), m_vah(0.0), m_val(0.0), m_lastBarTime(0) {}
//+------------------------------------------------------------------+
void CValueAreaEngine::Init(CCandleData* candles, int lookbackBars, int numBins, double valueAreaPercent)
  {
   m_candles = candles;
   m_lookbackBars = MathMax(10, lookbackBars);
   m_numBins = MathMax(5, numBins);
   m_valueAreaPercent = (valueAreaPercent > 0.0 && valueAreaPercent < 1.0) ? valueAreaPercent : 0.70;
   m_valid = false;
   m_lastBarTime = 0;
  }
//+------------------------------------------------------------------+
void CValueAreaEngine::Compute(bool forceRecompute)
  {
   m_valid = false;
   if(m_candles == NULL || m_candles.Total() < 10) return;

   // Rebuilding a 24-bin histogram over 100 bars every tick is wasted
   // work — the profile only needs to change once a new bar closes.
   datetime barTime = m_candles.GetCandle(0).time;
   if(!forceRecompute && barTime == m_lastBarTime && m_poc != 0.0)
     {
      m_valid = true; // last computed profile still applies to this bar
      return;
     }

   int total = m_candles.Total();
   int bars = MathMin(m_lookbackBars, total);
   if(bars < 10) return;

   double rangeHigh = -DBL_MAX, rangeLow = DBL_MAX;
   for(int i = 0; i < bars; i++)
     {
      CandleData cd = m_candles.GetCandle(i);
      if(cd.high > rangeHigh) rangeHigh = cd.high;
      if(cd.low  < rangeLow)  rangeLow  = cd.low;
     }
   double range = rangeHigh - rangeLow;
   if(range <= 0) return;

   double binSize = range / m_numBins;
   if(binSize <= 0) return;

   double volumes[];
   ArrayResize(volumes, m_numBins);
   ArrayInitialize(volumes, 0.0);

   for(int i = 0; i < bars; i++)
     {
      CandleData cd = m_candles.GetCandle(i);
      double vol = (double)cd.tick_volume;
      if(vol <= 0) continue;

      if(cd.high <= cd.low)
        {
         int singleBin = (int)((cd.close - rangeLow) / binSize);
         singleBin = (int)MathMax(0, MathMin(m_numBins - 1, singleBin));
         volumes[singleBin] += vol;
         continue;
        }

      int startBin = (int)((cd.low  - rangeLow) / binSize);
      int endBin   = (int)((cd.high - rangeLow) / binSize);
      startBin = (int)MathMax(0, MathMin(m_numBins - 1, startBin));
      endBin   = (int)MathMax(0, MathMin(m_numBins - 1, endBin));
      if(endBin < startBin) { int t = startBin; startBin = endBin; endBin = t; }

      int touched = endBin - startBin + 1;
      double volPerBin = vol / touched;
      for(int b = startBin; b <= endBin; b++)
         volumes[b] += volPerBin;
     }

   double totalVol = 0.0;
   int pocBin = 0;
   double pocVol = -1.0;
   for(int b = 0; b < m_numBins; b++)
     {
      totalVol += volumes[b];
      if(volumes[b] > pocVol) { pocVol = volumes[b]; pocBin = b; }
     }
   if(totalVol <= 0) return;

   int lowIdx = pocBin, highIdx = pocBin;
   double cumVol = volumes[pocBin];
   double targetVol = totalVol * m_valueAreaPercent;

   while(cumVol < targetVol && (lowIdx > 0 || highIdx < m_numBins - 1))
     {
      double volBelow = (lowIdx > 0) ? volumes[lowIdx - 1] : -1.0;
      double volAbove = (highIdx < m_numBins - 1) ? volumes[highIdx + 1] : -1.0;
      if(volBelow < 0 && volAbove < 0) break;
      if(volBelow >= volAbove) { lowIdx--; cumVol += volumes[lowIdx]; }
      else                     { highIdx++; cumVol += volumes[highIdx]; }
     }

   m_val = rangeLow + lowIdx * binSize;
   m_vah = rangeLow + (highIdx + 1) * binSize;
   m_poc = rangeLow + (pocBin + 0.5) * binSize;
   m_lastBarTime = barTime;
   m_valid = true;
  }
//+------------------------------------------------------------------+
ENUM_VALUE_AREA_ZONE CValueAreaEngine::Zone(double price) const
  {
   if(!m_valid) return VA_ZONE_UNDEFINED;
   if(price > m_vah) return VA_ZONE_ABOVE;   // premium — expensive relative to recent fair value
   if(price < m_val) return VA_ZONE_BELOW;   // discount — cheap relative to recent fair value
   return VA_ZONE_INSIDE;
  }
//+------------------------------------------------------------------+
bool CValueAreaEngine::LocationOK(bool forBuy, double price) const
  {
   if(!m_valid) return true; // no profile yet — don't block on missing data
   ENUM_VALUE_AREA_ZONE z = Zone(price);
   if(forBuy)  return (z == VA_ZONE_INSIDE || z == VA_ZONE_BELOW);
   else        return (z == VA_ZONE_INSIDE || z == VA_ZONE_ABOVE);
  }
//+------------------------------------------------------------------+
double CValueAreaEngine::Score(bool forBuy, double price) const
  {
   if(!m_valid) return 0.0;
   if(!LocationOK(forBuy, price)) return 0.0;
   if(price >= m_val && price <= m_vah)
     {
      double half = (m_vah - m_val) / 2.0;
      if(half <= 0) return 1.0;
      double distFromPOC = MathAbs(price - m_poc);
      return MathMax(0.0, 1.0 - distFromPOC / half);
     }
   return 1.0; // outside the VA but on the favorable (LocationOK) side — full credit, same as a fresh discount/premium read
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/SmartMoney/ValueAreaEngine.mqh ----


// ---- BEGIN EA/includes/SmartMoney/OrderBlock.mqh ----
//+------------------------------------------------------------------+
//|                                         SmartMoney/OrderBlock.mqh |
//+------------------------------------------------------------------+
#ifndef ORDERBLOCK_MQH
#define ORDERBLOCK_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----


// ---- BEGIN EA/includes/Structure/BOS.mqh ----

// ---- END EA/includes/Structure/BOS.mqh ----

// v2.8 addition, closing the gap flagged in the pre-rewrite audit: the
// codebase had Inducement/FVG/Liquidity/SR confluence but nothing reading
// Order Blocks on a higher timeframe, even though the point-table spec's
// "HTF Alignment" bucket implicitly assumes one. This engine is meant to
// run on an HTF CTFContext (H4/D1) separate from the entry-timeframe FVG
// context — same "own candle series per timeframe" discipline as
// CTFContext itself.
//
// Definition used (standard SMC OB, not a proprietary variant):
//   Bullish OB = the last down-close candle immediately before a
//                displacement leg that breaks structure upward.
//   Bearish OB = the last up-close candle immediately before a
//                displacement leg that breaks structure downward.
// Zone = candle's [open, low] for a bullish OB, [open, high] for a
// bearish OB — the body-to-wick-extreme range, which is where the
// original imbalance/inefficiency actually sits, not the full [high,low]
// wick range (that overstates the zone and generates false confluence).
class COrderBlock
  {
private:
   CCandleData*      m_candles;
   OrderBlockZone     m_zones[];
   int                m_zoneCount;
   double             m_displacementATRMult;   // min range/ATR to count as a displacement leg
   double             m_minBodyRatio;          // min body/range of the displacement candle
   int                m_maxZones;              // cap so old HTF zones don't accumulate forever

   bool              IsDisplacement(int idx, bool &bullish);
   // FIX (audit #18): checks whether a genuine, chronologically-confirmed
   // BOS event (from the already-fixed CBOS engine — see Structure/BOS.mqh)
   // exists at or near this candle, in the matching direction.
   bool              CoincidesWithStructureBreak(int idx, bool bullish);
   void              UpdateState(OrderBlockZone &z);
   CBOS*             m_bos;

public:
                     COrderBlock();
   void              Init(CCandleData* candleData, CBOS* bos, double displacementATRMult = 1.5,
                          double minBodyRatio = 0.5, int maxZones = 15);
   void              Detect();
   void              UpdateAllStates();
   int               Count() const { return m_zoneCount; }
   OrderBlockZone     GetZone(int i) const; // 0 = most recent
   // Nearest fresh/tested zone in `dir` within distATRMax of price; returns
   // false if none. Used by Scoring::ObScore()/ObGate().
   bool              NearestZone(ENUM_FVG_DIR dir, double price, double atr, double distATRMax, OrderBlockZone &out);
  };
//+------------------------------------------------------------------+
COrderBlock::COrderBlock() : m_candles(NULL), m_bos(NULL), m_zoneCount(0), m_displacementATRMult(1.5),
                              m_minBodyRatio(0.5), m_maxZones(15) {}
//+------------------------------------------------------------------+
void COrderBlock::Init(CCandleData* candleData, CBOS* bos, double displacementATRMult, double minBodyRatio, int maxZones)
  {
   m_candles = candleData;
   m_bos = bos;
   m_displacementATRMult = displacementATRMult;
   m_minBodyRatio = minBodyRatio;
   m_maxZones = MathMax(3, maxZones);
  }
//+------------------------------------------------------------------+
bool COrderBlock::IsDisplacement(int idx, bool &bullish)
  {
   if(m_candles == NULL) return false;
   CandleData cd = m_candles.GetCandle(idx);
   double atr = cd.atr;
   if(atr <= 0) return false;
   double range = cd.high - cd.low;
   if(range <= 0) return false;
   double body = MathAbs(cd.close - cd.open);
   if(range / atr < m_displacementATRMult) return false;
   if(body / range < m_minBodyRatio) return false;
   bullish = (cd.close > cd.open);
   return true;
  }
//+------------------------------------------------------------------+
// FIX (audit #18): "large directional candle" alone was standing in for
// "order block confirmed by displacement + structure break" — the docstring
// at the top of this file promised the latter but IsDisplacement() only
// ever checked the former (range/ATR, body/range, direction). A large
// candle in the middle of a trading range with no structure broken is not
// an institutional order block by any SMC definition; it's just a big
// candle. This cross-checks against CBOS's already-corrected, non-
// lookahead event list: a real BOS event of the matching direction must
// exist within a small tolerance of this bar for the displacement to
// count as genuine. Tolerance of 2 bars covers the close that actually
// triggers the BOS landing 1-2 bars after the visually "big" candle
// starts the move (common when displacement spans multiple candles).
bool COrderBlock::CoincidesWithStructureBreak(int idx, bool bullish)
  {
   if(m_bos == NULL) return true; // no BOS engine wired in — fail open rather than silently disabling OB detection entirely
   int n = m_bos.Count();
   for(int i = 0; i < n; i++)
     {
      BOSEvent ev = m_bos.GetBOS(i);
      if(ev.is_bullish != bullish) continue;
      if(MathAbs(ev.bar_index - idx) <= 2) return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
// Series-indexed like FVG.mqh: shift 0 = current bar, i grows toward the
// past. For a displacement at idx, the "last opposite-close candle before
// it" is walked backward from idx+1 (older bars) until a candle whose
// close/open sign is opposite the displacement direction is found. This
// mirrors the standard SMC OB definition rather than blindly taking
// idx+1, which would misfire whenever two displacement-direction candles
// print back to back.
void COrderBlock::Detect()
  {
   m_zoneCount = 0;
   if(m_candles == NULL) return;
   ArrayFree(m_zones);
   int total = m_candles.Total();
   if(total < 5) return;

   int lookback = MathMin(total - 2, 300); // HTF context, doesn't need the full buffer
   for(int i = 1; i < lookback && m_zoneCount < m_maxZones; i++)
     {
      bool dispBullish;
      if(!IsDisplacement(i, dispBullish)) continue;
      if(!CoincidesWithStructureBreak(i, dispBullish)) continue; // FIX #18: displacement alone isn't enough

      // walk backward (older bars) from the displacement candle for the
      // nearest candle of the opposite close direction, within 5 bars —
      // beyond that it's no longer "the" originating candle.
      for(int j = i + 1; j < MathMin(i + 6, total); j++)
        {
         CandleData ob = m_candles.GetCandle(j);
         bool obUp = (ob.close > ob.open);
         if(dispBullish && obUp) continue;       // want a DOWN candle before a bullish leg
         if(!dispBullish && !obUp) continue;      // want an UP candle before a bearish leg

         OrderBlockZone z;
         ZeroMemory(z);
         z.time = ob.time;
         z.bar_index = j;
         z.dir = dispBullish ? FVG_BULL : FVG_BEAR;
         z.state = OB_FRESH;
         z.displacement_atr = (m_candles.GetCandle(i).high - m_candles.GetCandle(i).low) / m_candles.GetCandle(i).atr;
         if(dispBullish) { z.top = ob.open; z.bottom = ob.low; }
         else             { z.top = ob.high; z.bottom = ob.open; }
         if(z.top < z.bottom) { double t = z.top; z.top = z.bottom; z.bottom = t; }

         UpdateState(z);
         if(z.state != OB_MITIGATED)
           {
            int n = ArraySize(m_zones);
            ArrayResize(m_zones, n + 1);
            m_zones[n] = z;
            m_zoneCount++;
           }
         break; // only the nearest opposite-close candle counts as THE origin
        }
     }
  }
//+------------------------------------------------------------------+
// Re-derives state by replaying candles newer than the zone (bar_index-1
// down to 0) against its top/bottom — same touched/mitigated logic FVG
// uses, kept local here since OB mitigation rule differs slightly (a
// CLOSE through the far edge invalidates; a wick-only touch just tests).
void COrderBlock::UpdateState(OrderBlockZone &z)
  {
   if(m_candles == NULL) return;
   bool bullish = (z.dir == FVG_BULL);
   for(int k = z.bar_index - 1; k >= 0; k--)
     {
      CandleData cd = m_candles.GetCandle(k);
      bool touched = (cd.low <= z.top && cd.high >= z.bottom);
      if(!touched) continue;
      bool closedThrough = bullish ? (cd.close < z.bottom) : (cd.close > z.top);
      if(closedThrough) { z.state = OB_MITIGATED; return; }
      if(z.state == OB_FRESH) z.state = OB_TESTED;
     }
  }
//+------------------------------------------------------------------+
void COrderBlock::UpdateAllStates()
  {
   for(int i = 0; i < m_zoneCount; i++)
      UpdateState(m_zones[i]);
  }
//+------------------------------------------------------------------+
OrderBlockZone COrderBlock::GetZone(int i) const
  {
   OrderBlockZone empty;
   ZeroMemory(empty);
   if(i < 0 || i >= m_zoneCount) return empty;
   // m_zones is filled oldest-displacement-first per outer loop order
   // (i ascends = older); present most-recent-first to match every other
   // engine's GetZone(0)==newest convention.
   return m_zones[m_zoneCount - 1 - i];
  }
//+------------------------------------------------------------------+
bool COrderBlock::NearestZone(ENUM_FVG_DIR dir, double price, double atr, double distATRMax, OrderBlockZone &out)
  {
   if(atr <= 0) return false;
   double bestDist = -1.0;
   for(int i = 0; i < m_zoneCount; i++)
     {
      OrderBlockZone z = GetZone(i);
      if(z.dir != dir) continue;
      if(z.state == OB_MITIGATED) continue;
      double mid = (z.top + z.bottom) / 2.0;
      double dist = MathAbs(price - mid) / atr;
      if(dist > distATRMax) continue;
      if(bestDist < 0 || dist < bestDist) { bestDist = dist; out = z; }
     }
   return bestDist >= 0;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/SmartMoney/OrderBlock.mqh ----


// ---- BEGIN EA/includes/Analysis/TrendEngine.mqh ----
//+------------------------------------------------------------------+
//|                                             Analysis/TrendEngine.mqh |
//+------------------------------------------------------------------+
#ifndef TRENDENGINE_MQH
#define TRENDENGINE_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----


// ---- BEGIN EA/includes/Structure/SwingDetector.mqh ----

// ---- END EA/includes/Structure/SwingDetector.mqh ----


// ---- BEGIN EA/includes/Structure/BOS.mqh ----

// ---- END EA/includes/Structure/BOS.mqh ----


// ---- BEGIN EA/includes/Structure/CHOCH.mqh ----

// ---- END EA/includes/Structure/CHOCH.mqh ----

class CTrendEngine
  {
private:
   CSwingDetector*   m_swings;
   CBOS*             m_bos;
   CCHOCH*           m_choch;
   CCandleData*      m_candles;

   ENUM_TREND_STATE  DetermineTrend();

public:
                     CTrendEngine();
   void              Init(CSwingDetector* swings, CBOS* bos, CCHOCH* choch, CCandleData* candles);
   ENUM_TREND_STATE  GetCurrentTrend();
  };
//+------------------------------------------------------------------+
CTrendEngine::CTrendEngine() : m_swings(NULL), m_bos(NULL), m_choch(NULL), m_candles(NULL) {}
void CTrendEngine::Init(CSwingDetector* swings, CBOS* bos, CCHOCH* choch, CCandleData* candles)
  {
   m_swings = swings;
   m_bos = bos;
   m_choch = choch;
   m_candles = candles;
  }
//+------------------------------------------------------------------+
ENUM_TREND_STATE CTrendEngine::DetermineTrend()
  {
   if(m_swings == NULL || m_bos == NULL) return TREND_NEUTRAL;
   int hc = m_swings.HighCount();
   int lc = m_swings.LowCount();
   if(hc < 2 || lc < 2) return TREND_NEUTRAL;

   SwingPoint lastHigh = m_swings.GetHigh(0);
   SwingPoint prevHigh = m_swings.GetHigh(1);
   SwingPoint lastLow  = m_swings.GetLow(0);
   SwingPoint prevLow  = m_swings.GetLow(1);

   bool higherHigh = (lastHigh.price > prevHigh.price);
   bool higherLow  = (lastLow.price > prevLow.price);

   bool bullishBOS = false, bearishBOS = false;
   if(m_bos.Count() > 0)
     {
      BOSEvent recent = m_bos.GetBOS(0);
      bullishBOS = recent.is_bullish;
      bearishBOS = !recent.is_bullish;
     }

   if(higherHigh && higherLow && bullishBOS) return TREND_BULL_STRONG;
   if(higherHigh && higherLow) return TREND_BULL;
   if(!higherHigh && !higherLow && bearishBOS) return TREND_BEAR_STRONG;
   if(!higherHigh && !higherLow) return TREND_BEAR;
   return TREND_NEUTRAL;
  }
//+------------------------------------------------------------------+
ENUM_TREND_STATE CTrendEngine::GetCurrentTrend()
  {
   return DetermineTrend();
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Analysis/TrendEngine.mqh ----

// One full SMC detection pipeline, scoped to a single timeframe. Building
// this was the actual fix for "real per-timeframe BOS/liquidity/FVG" —
// previously every concept ran on whatever timeframe the chart happened
// to be on, so labeling a signal "H4 BOS" while running on M15 would have
// been a lie. Each CTFContext owns its own candle series for its own TF.
class CTFContext
  {
private:
   datetime          m_lastBarTime; // FIX: per-context new-bar gate — see Detect() below

public:
   ENUM_TIMEFRAMES   tf;
   CCandleData       candles;
   CSwingDetector    swings;
   CBOS              bos;
   CCHOCH            choch;
   CFVG              fvg;
   CLiquidity        liquidity;
   CSupportResistance sr;
   CTrendEngine      trend;
   CVolumeEngine     volume;      // v2.6 — RVOL / breakout-volume confirmation on this TF
   CFibonacciEngine  fibonacci;   // v2.6 — swing-anchored retracement zone on this TF
   CValueAreaEngine  valueArea;   // v2.6 — volume-profile POC/VAH/VAL location filter on this TF
   COrderBlock       orderBlock;  // v2.8 — HTF Order Block zones; meaningful when this context's tf is a higher TF than the entry FVG context

   bool              Init(string symbol, ENUM_TIMEFRAMES timeframe, int maxBars,
                          int swingStrength, double fvgMinSizeATR, double liqThresholdATR,
                          int rvolLookback = 20, int vaLookbackBars = 100, int vaNumBins = 24,
                          double vaPercent = 0.70, double obDisplacementATRMult = 1.5, double obMinBodyRatio = 0.5);
   // FIX (perf trap flagged during the v2.8 audit): "refreshes the entire
   // historical buffer on every tick... acceptable for 500 bars [but] not
   // a scalable architecture." Detect() now only actually does the
   // Refresh()+redetect work when THIS context's own timeframe has
   // printed a new bar since the last call — a context on H4 doesn't
   // need CopyRates/swings/BOS/liquidity/etc. recomputed on every M15
   // tick just because the chart TF ticked. force=true bypasses the gate
   // (used once at EA/indicator startup so the first pass always runs).
   void              Detect(bool force = false);
  }; // FIX: this closing brace was dropped during the event-driven-refresh edit —
     // everything below (both method bodies, plus the entire CTFContextPool class)
     // was accidentally left nested inside CTFContext. Caught by manual brace-balance
     // review since no MQL5 compiler is available in this environment; would have been
     // a hard compile failure in MetaEditor.
//+------------------------------------------------------------------+
bool CTFContext::Init(string symbol, ENUM_TIMEFRAMES timeframe, int maxBars,
                      int swingStrength, double fvgMinSizeATR, double liqThresholdATR,
                      int rvolLookback, int vaLookbackBars, int vaNumBins, double vaPercent,
                      double obDisplacementATRMult, double obMinBodyRatio)
  {
   tf = timeframe;
   m_lastBarTime = 0; // 0 guarantees the very first Detect() call always runs, force or not
   if(!candles.Init(symbol, tf, maxBars))
      return false;
   swings.SetParameters(&candles, swingStrength);
   bos.Init(&swings, &candles);
   choch.Init(&swings, &candles);
   fvg.Init(&candles, fvgMinSizeATR);
   liquidity.Init(&candles, &swings, liqThresholdATR);
   sr.Init(&candles, &swings);
   trend.Init(&swings, &bos, &choch, &candles);
   volume.Init(&candles, rvolLookback);
   fibonacci.Init(&swings, &candles);
   valueArea.Init(&candles, vaLookbackBars, vaNumBins, vaPercent);
   orderBlock.Init(&candles, &bos, obDisplacementATRMult, obMinBodyRatio);
   return true;
  }
//+------------------------------------------------------------------+
void CTFContext::Detect(bool force)
  {
   datetime barTime = iTime(candles.Symbol(), tf, 0);
   if(!force && barTime != 0 && barTime == m_lastBarTime)
      return; // no new bar on THIS context's own timeframe — nothing has changed since the last full pass
   m_lastBarTime = barTime;

   candles.Refresh();
   if(!candles.IsReady()) return;
   swings.Detect();
   bos.Detect();
   choch.Detect();
   fvg.Detect();
   fvg.UpdateAllStates();
   liquidity.Detect();
   sr.Detect();
   valueArea.Compute();
   orderBlock.Detect();
  }
//+------------------------------------------------------------------+
#define TFPOOL_MAX 8

// Dedupes contexts by timeframe: if Trend=D1 and someone else also asks
// for D1, they get the SAME context (and the same, single Detect() call
// per bar) rather than two redundant pipelines computing identical data.
class CTFContextPool
  {
private:
   CTFContext*       m_ctx[TFPOOL_MAX];
   int               m_count;
   string            m_symbol;
   int               m_maxBars;
   int               m_swingStrength;
   double            m_fvgMinSizeATR;
   double            m_liqThresholdATR;
   int               m_rvolLookback;
   int               m_vaLookbackBars;
   int               m_vaNumBins;
   double            m_vaPercent;
   double            m_obDisplacementATRMult;
   double            m_obMinBodyRatio;

public:
                     CTFContextPool();
                    ~CTFContextPool();
   void              Configure(string symbol, int maxBars, int swingStrength,
                               double fvgMinSizeATR, double liqThresholdATR, int rvolLookback = 20,
                               int vaLookbackBars = 100, int vaNumBins = 24, double vaPercent = 0.70,
                               double obDisplacementATRMult = 1.5, double obMinBodyRatio = 0.5);
   CTFContext*       Get(ENUM_TIMEFRAMES tf); // creates on first request, reuses after
   void              DetectAll(bool force = false);
  };
//+------------------------------------------------------------------+
CTFContextPool::CTFContextPool() : m_count(0), m_rvolLookback(20), m_vaLookbackBars(100),
                                    m_vaNumBins(24), m_vaPercent(0.70),
                                    m_obDisplacementATRMult(1.5), m_obMinBodyRatio(0.5)
  {
   for(int i = 0; i < TFPOOL_MAX; i++) m_ctx[i] = NULL;
  }
CTFContextPool::~CTFContextPool()
  {
   for(int i = 0; i < m_count; i++)
      if(m_ctx[i] != NULL) delete m_ctx[i];
  }
//+------------------------------------------------------------------+
void CTFContextPool::Configure(string symbol, int maxBars, int swingStrength,
                               double fvgMinSizeATR, double liqThresholdATR, int rvolLookback,
                               int vaLookbackBars, int vaNumBins, double vaPercent,
                               double obDisplacementATRMult, double obMinBodyRatio)
  {
   m_symbol = symbol;
   m_maxBars = maxBars;
   m_swingStrength = swingStrength;
   m_fvgMinSizeATR = fvgMinSizeATR;
   m_liqThresholdATR = liqThresholdATR;
   m_rvolLookback = MathMax(5, rvolLookback);
   m_vaLookbackBars = MathMax(10, vaLookbackBars);
   m_vaNumBins = MathMax(5, vaNumBins);
   m_vaPercent = (vaPercent > 0.0 && vaPercent < 1.0) ? vaPercent : 0.70;
   m_obDisplacementATRMult = (obDisplacementATRMult > 0) ? obDisplacementATRMult : 1.5;
   m_obMinBodyRatio = (obMinBodyRatio > 0 && obMinBodyRatio <= 1.0) ? obMinBodyRatio : 0.5;
  }
//+------------------------------------------------------------------+
CTFContext* CTFContextPool::Get(ENUM_TIMEFRAMES tf)
  {
   for(int i = 0; i < m_count; i++)
      if(m_ctx[i] != NULL && m_ctx[i].tf == tf)
         return m_ctx[i];

   if(m_count >= TFPOOL_MAX)
     {
      Print("MedisTouch: TFContextPool full (", TFPOOL_MAX, " timeframes) — reusing last context.");
      return m_ctx[m_count - 1];
     }
   CTFContext* c = new CTFContext();
   if(!c.Init(m_symbol, tf, m_maxBars, m_swingStrength, m_fvgMinSizeATR, m_liqThresholdATR, m_rvolLookback,
             m_vaLookbackBars, m_vaNumBins, m_vaPercent, m_obDisplacementATRMult, m_obMinBodyRatio))
     {
      Print("MedisTouch: failed to init TFContext for timeframe ", EnumToString(tf));
      delete c;
      return NULL;
     }
   m_ctx[m_count++] = c;
   return c;
  }
//+------------------------------------------------------------------+
void CTFContextPool::DetectAll(bool force)
  {
   for(int i = 0; i < m_count; i++)
      if(m_ctx[i] != NULL)
         m_ctx[i].Detect(force);
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Analysis/TFContext.mqh ----

// ---- BEGIN EA/includes/Analysis/Scoring.mqh ----
//+------------------------------------------------------------------+
//|                                                Analysis/Scoring.mqh |
//+------------------------------------------------------------------+
#ifndef SCORING_MQH
#define SCORING_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----


// ---- BEGIN EA/includes/Analysis/TFContext.mqh ----

// ---- END EA/includes/Analysis/TFContext.mqh ----


// ---- BEGIN EA/includes/SmartMoney/Inducement.mqh ----
//+------------------------------------------------------------------+
//|                                          SmartMoney/Inducement.mqh |
//+------------------------------------------------------------------+
#ifndef INDUCEMENT_MQH
#define INDUCEMENT_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----

// Validates the sequence: Impulse -> Internal pullback structure ->
// Internal liquidity sweep (inducement) -> minor BOS -> only then is a
// setup "confirmed". This turns the indicator from a feature detector
// (does an FVG exist near price?) into a decision engine (did price
// actually get manipulated into a stop run before the real move?).
//
// SCOPE / HONEST LIMITATIONS:
//  - All detection here runs on ONE timeframe (whatever CCandleData this
//    is Init()'d with — normally the FVG/entry timeframe, since that's
//    where the setup actually triggers). It does not cross-check the
//    impulse against a higher timeframe.
//  - "Minor" structure is a local 1-bar fractal (compare each bar only to
//    its immediate left/right neighbor), deliberately looser than the
//    swing detector used elsewhere (which defaults to 3 bars) — the whole
//    point of this module is to see the SMALL structure inside a pullback
//    that the main SwingDetector is tuned to ignore.
//  - "Equal" highs/lows use the same ATR-fraction tolerance band as
//    Liquidity.mqh's internal pools, passed in as equalTolATR, so the two
//    concepts stay consistent with each other.
class CInducement
  {
private:
   CCandleData*      m_candles;
   int               m_lookbackBars;
   double            m_impulseATRMult;   // min (bar range / ATR) to qualify as a displacement bar
   double            m_impulseBodyRatio; // min body/range ratio for a displacement bar
   double            m_equalTolATR;      // tolerance band for "equal" highs/lows, as a fraction of ATR
   int               m_maxLegExtend;     // how many bars a leg can be extended outward while still qualifying

   bool              IsDisplacementBar(int idx, bool bullish);
   bool              FindImpulse(bool bullish, ImpulseLeg &leg);
   bool              FindMinorSwing(int idx, bool wantHigh); // local 1-bar fractal
   bool              FindEqualPair(bool wantLows, int scanFrom, int scanTo, double atr,
                                   double &poolPrice, int &nearIdx, int &farIdx);

   // --- v2.9 additions ---------------------------------------------
   bool              m_requireMinSweepGrade; // OFF by default — see Configure()
   ENUM_SWEEP_GRADE  m_minSweepGrade;
   bool              m_requireFreshSetup;    // OFF by default — hard-reject when TimeDecay() hits 0
   int               m_maxBarsSinceBOS;      // decay-to-zero cutoff, default 5 per the 0/90/75/55/0 curve

   ENUM_SWEEP_GRADE  GradeSweep(int sweepBarIdx, bool forBuy, double poolPrice, double &gradeScore);
   double            BOSStrength(int bosBarIdx, double breakLevel, bool forBuy);
   double            TimeDecay(int barsSinceBOS);

public:
                     CInducement();
   void              Init(CCandleData* candles, int lookbackBars = 40, double impulseATRMult = 1.2,
                          double impulseBodyRatio = 0.6, double equalTolATR = 0.2, int maxLegExtend = 10);
   // v2.9 addition. Both gates default OFF/lenient — same "unvalidated
   // until proven on this instrument via ablation testing" discipline as
   // every other v2.6/v2.8 filter in this codebase (see Scoring.mqh's
   // class-level comment). sweepGrade/bosStrength/timeDecay are computed
   // and returned on every call regardless of these flags; only whether
   // a sub-B-grade or fully-decayed setup gets hard-rejected is gated.
   void              ConfigureQualityGates(bool requireMinSweepGrade, ENUM_SWEEP_GRADE minSweepGrade,
                                            bool requireFreshSetup, int maxBarsSinceBOS = 5);
   InducementResult  Validate(bool forBuy);
  };
//+------------------------------------------------------------------+
CInducement::CInducement() : m_candles(NULL), m_lookbackBars(40), m_impulseATRMult(1.2),
                              m_impulseBodyRatio(0.6), m_equalTolATR(0.2), m_maxLegExtend(10),
                              m_requireMinSweepGrade(false), m_minSweepGrade(SWEEP_GRADE_B),
                              m_requireFreshSetup(false), m_maxBarsSinceBOS(5) {}
//+------------------------------------------------------------------+
void CInducement::Init(CCandleData* candles, int lookbackBars, double impulseATRMult,
                       double impulseBodyRatio, double equalTolATR, int maxLegExtend)
  {
   m_candles = candles;
   m_lookbackBars = MathMax(10, lookbackBars);
   m_impulseATRMult = impulseATRMult;
   m_impulseBodyRatio = impulseBodyRatio;
   m_equalTolATR = equalTolATR;
   m_maxLegExtend = MathMax(2, maxLegExtend);
  }
//+------------------------------------------------------------------+
void CInducement::ConfigureQualityGates(bool requireMinSweepGrade, ENUM_SWEEP_GRADE minSweepGrade,
                                        bool requireFreshSetup, int maxBarsSinceBOS)
  {
   m_requireMinSweepGrade = requireMinSweepGrade;
   m_minSweepGrade = minSweepGrade;
   m_requireFreshSetup = requireFreshSetup;
   m_maxBarsSinceBOS = MathMax(1, maxBarsSinceBOS);
  }
//+------------------------------------------------------------------+
bool CInducement::IsDisplacementBar(int idx, bool bullish)
  {
   if(m_candles == NULL) return false;
   CandleData cd = m_candles.GetCandle(idx);
   double atr = m_candles.GetATR(idx);
   if(atr <= 0) return false;
   double range = cd.high - cd.low;
   if(range <= 0) return false;
   double body = MathAbs(cd.close - cd.open);
   double bodyRatio = body / range;
   bool directional = bullish ? (cd.close > cd.open) : (cd.close < cd.open);
   if(!directional) return false;
   if(range / atr < m_impulseATRMult) return false;
   if(bodyRatio < m_impulseBodyRatio) return false;
   // Opposite wick should be small — a big rejection wick against the
   // move undercuts the "displacement" read even if the body qualifies.
   double oppWick = bullish ? (cd.open - cd.low) : (cd.high - cd.open);
   if(oppWick > 0.3 * range) return false;
   return true;
  }
//+------------------------------------------------------------------+
// Scans the lookback window for a qualifying displacement bar, then
// extends the leg outward (toward more-recent AND toward older bars)
// while price keeps making new extremes in the same direction, so the
// leg's start/end prices bound the whole impulse move, not just the one
// bar that tripped the threshold.
bool CInducement::FindImpulse(bool bullish, ImpulseLeg &leg)
  {
   ZeroMemory(leg);
   if(m_candles == NULL) return false;
   int total = m_candles.Total();
   int scanLimit = MathMin(m_lookbackBars, total - 1);

   for(int i = 1; i <= scanLimit; i++)
     {
      if(!IsDisplacementBar(i, bullish)) continue;

      int newerBar = i; // extend toward index 0 (more recent)
      int olderBar = i; // extend toward higher index (older)
      double bestExtreme = bullish ? m_candles.GetCandle(i).high : m_candles.GetCandle(i).low;

      for(int k = i - 1; k >= MathMax(0, i - m_maxLegExtend); k--)
        {
         CandleData cd = m_candles.GetCandle(k);
         bool extends = bullish ? (cd.high >= bestExtreme) : (cd.low <= bestExtreme);
         if(!extends) break;
         bestExtreme = bullish ? cd.high : cd.low;
         newerBar = k;
        }
      double oldExtreme = bullish ? m_candles.GetCandle(i).low : m_candles.GetCandle(i).high;
      for(int k = i + 1; k <= MathMin(total - 1, i + m_maxLegExtend); k++)
        {
         CandleData cd = m_candles.GetCandle(k);
         bool extends = bullish ? (cd.low <= oldExtreme) : (cd.high >= oldExtreme);
         if(!extends) break;
         oldExtreme = bullish ? cd.low : cd.high;
         olderBar = k;
        }

      leg.valid = true;
      leg.start_bar = olderBar;
      leg.end_bar = newerBar;
      leg.start_time = m_candles.GetCandle(olderBar).time;
      leg.end_time = m_candles.GetCandle(newerBar).time;
      leg.start_price = oldExtreme;
      leg.end_price = bestExtreme;
      leg.bullish = bullish;

      double atr = m_candles.GetATR(i);
      double distATR = (atr > 0) ? MathAbs(leg.end_price - leg.start_price) / atr : 0.0;
      leg.strength = MathMax(0.0, MathMin(distATR / 3.0, 1.0));
      return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
// Local 1-bar fractal: idx is a minor swing high/low if it beats its
// immediate left AND right neighbor. Deliberately tighter than the main
// SwingDetector (strength 3) — this is meant to catch the small internal
// structure a pullback makes, not the major structure.
bool CInducement::FindMinorSwing(int idx, bool wantHigh)
  {
   if(m_candles == NULL) return false;
   int total = m_candles.Total();
   if(idx < 1 || idx >= total - 1) return false;
   if(wantHigh)
     {
      double h = m_candles.GetCandle(idx).high;
      return (h >= m_candles.GetCandle(idx - 1).high && h >= m_candles.GetCandle(idx + 1).high);
     }
   double l = m_candles.GetCandle(idx).low;
   return (l <= m_candles.GetCandle(idx - 1).low && l <= m_candles.GetCandle(idx + 1).low);
  }
//+------------------------------------------------------------------+
// Scans [scanFrom, scanTo] (series indices, scanFrom = more recent) for
// two minor swings of the requested type whose prices sit within
// m_equalTolATR * atr of each other — an "equal highs/lows" pool, the
// classic resting-liquidity signature.
bool CInducement::FindEqualPair(bool wantLows, int scanFrom, int scanTo, double atr,
                                double &poolPrice, int &nearIdx, int &farIdx)
  {
   poolPrice = 0.0; nearIdx = -1; farIdx = -1;
   if(m_candles == NULL || atr <= 0) return false;
   double band = m_equalTolATR * atr;

   int found[]; ArrayResize(found, 0);
   for(int i = scanFrom; i <= scanTo; i++)
     {
      if(!FindMinorSwing(i, wantLows ? false : true)) continue; // wantLows -> look for swing LOWS
      int n = ArraySize(found);
      ArrayResize(found, n + 1);
      found[n] = i;
     }
   int fc = ArraySize(found);
   for(int a = 0; a < fc - 1; a++)
     {
      double pa = wantLows ? m_candles.GetCandle(found[a]).low : m_candles.GetCandle(found[a]).high;
      for(int b = a + 1; b < fc; b++)
        {
         double pb = wantLows ? m_candles.GetCandle(found[b]).low : m_candles.GetCandle(found[b]).high;
         if(MathAbs(pa - pb) <= band)
           {
            nearIdx = MathMin(found[a], found[b]);
            farIdx  = MathMax(found[a], found[b]);
            poolPrice = wantLows ? MathMin(pa, pb) : MathMax(pa, pb);
            return true;
           }
        }
     }
   return false;
  }
//+------------------------------------------------------------------+
// v2.9. Grades the sweep bar itself instead of just recording that
// price wicked past the pool and closed back inside it. Three
// components, each 0-1, blended 40/30/30:
//   - rejectionRatio: how much of the wick got reclaimed by the close
//     (a full reclaim reads 1.0; a close that barely got back inside
//     the pool reads near 0).
//   - penetration shape: penalizes both a near-zero poke (not enough of
//     a stop-run to mean anything) and a very deep wick (starts looking
//     like a breakout attempt, not a hunt) — full credit in the
//     0.03-0.60 ATR band, tapering outside it.
//   - followThrough: does the bar immediately after the sweep bar
//     qualify as its own displacement bar in the trade direction? This
//     is the "sweep -> rejection -> displacement -> BOS" causal chain
//     from the spec, not just "sweep -> tiny BOS".
// Thresholds (0.70 / 0.40) are starting points, not tuned constants —
// they need the same ablation-test treatment as everything else here
// before being trusted live.
ENUM_SWEEP_GRADE CInducement::GradeSweep(int sweepBarIdx, bool forBuy, double poolPrice, double &gradeScore)
  {
   gradeScore = 0.0;
   if(m_candles == NULL || sweepBarIdx < 0) return SWEEP_GRADE_NONE;
   CandleData cd = m_candles.GetCandle(sweepBarIdx);
   double atr = m_candles.GetATR(sweepBarIdx);
   if(atr <= 0) return SWEEP_GRADE_NONE;

   double wick = forBuy ? (poolPrice - cd.low) : (cd.high - poolPrice);
   if(wick <= 0) return SWEEP_GRADE_NONE; // shouldn't happen if sweepFound was true, but stay defensive

   double closeBack = forBuy ? (cd.close - poolPrice) : (poolPrice - cd.close);
   double rejectionRatio = MathMax(0.0, MathMin(closeBack / wick, 1.0));

   double penetrationATR = wick / atr;
   double shapeScore;
   if(penetrationATR >= 0.03 && penetrationATR <= 0.60)
      shapeScore = 1.0;
   else
      shapeScore = MathMax(0.0, 1.0 - MathAbs(penetrationATR - 0.30) / 0.60);

   bool followThrough = (sweepBarIdx - 1 >= 0) ? IsDisplacementBar(sweepBarIdx - 1, forBuy) : false;

   gradeScore = MathMax(0.0, MathMin(0.4 * rejectionRatio + 0.3 * shapeScore + 0.3 * (followThrough ? 1.0 : 0.0), 1.0));

   if(gradeScore >= 0.70) return SWEEP_GRADE_A;
   if(gradeScore >= 0.40) return SWEEP_GRADE_B;
   return SWEEP_GRADE_C;
  }
//+------------------------------------------------------------------+
// v2.9. Continuous replacement for the old binary bosConfirmed-only
// read: full credit at a 0.5 ATR break beyond the opposing minor swing
// (breakDist component), blended with the confirming bar's own
// body-dominance (a decisive close-through vs. a bar that barely
// tagged the level and closed unconvincingly). 60/40 weighting mirrors
// IsDisplacementBar()'s existing emphasis on range/ATR over raw body%.
double CInducement::BOSStrength(int bosBarIdx, double breakLevel, bool forBuy)
  {
   if(m_candles == NULL || bosBarIdx < 0) return 0.0;
   CandleData cd = m_candles.GetCandle(bosBarIdx);
   double atr = m_candles.GetATR(bosBarIdx);
   if(atr <= 0) return 0.0;

   double breakDist = forBuy ? (cd.close - breakLevel) : (breakLevel - cd.close);
   if(breakDist <= 0) return 0.0; // shouldn't happen if bosConfirmed was true

   double range = cd.high - cd.low;
   double bodyRatio = (range > 0) ? MathAbs(cd.close - cd.open) / range : 0.0;
   double distScore = MathMin(breakDist / (0.5 * atr), 1.0);
   return MathMax(0.0, MathMin(0.6 * distScore + 0.4 * bodyRatio, 1.0));
  }
//+------------------------------------------------------------------+
// v2.9. Item #18 from the review: a sweep/BOS 2 bars ago isn't the same
// setup as one 5 bars ago. Curve is a starting point (illustrative
// buckets from the spec), not learned from data yet.
double CInducement::TimeDecay(int barsSinceBOS)
  {
   if(barsSinceBOS <= 1) return 1.00;
   if(barsSinceBOS == 2) return 0.90;
   if(barsSinceBOS == 3) return 0.75;
   if(barsSinceBOS == 4) return 0.55;
   return 0.0;
  }
//+------------------------------------------------------------------+
InducementResult CInducement::Validate(bool forBuy)
  {
   InducementResult r;
   ZeroMemory(r);
   if(m_candles == NULL || m_candles.Total() < 20)
     {
      r.reason = "Not enough bars";
      return r;
     }

   ImpulseLeg leg;
   if(!FindImpulse(forBuy, leg))
     {
      r.reason = "No qualifying impulse (displacement) found in lookback window";
      return r;
     }
   r.impulseFound = true;
   r.impulseScore = 15.0;

   // Pullback/continuation region: everything more recent than the
   // impulse's newer edge, i.e. series indices [0, leg.end_bar - 1].
   int pullbackTo = leg.end_bar - 1;
   if(pullbackTo < 2)
     {
      r.reason = "Impulse too recent — no pullback bars to inspect yet";
      return r;
     }

   double atr = m_candles.GetATR(leg.end_bar);
   if(atr <= 0)
     {
      r.reason = "ATR unavailable at impulse edge";
      return r;
     }

   // Bullish impulse -> look for equal LOWS in the pullback (resting
   // sell-side liquidity that a stop-hunt would sweep before continuing
   // up). Bearish impulse -> equal HIGHS.
   double poolPrice; int nearIdx, farIdx;
   bool structureFound = FindEqualPair(forBuy /*wantLows*/, 0, pullbackTo, atr, poolPrice, nearIdx, farIdx);
   r.internalStructureFound = structureFound;
   r.structureScore = structureFound ? 10.0 : 0.0;
   if(!structureFound)
     {
      r.reason = "Impulse found, but no internal equal-highs/lows structure formed in the pullback";
      return r;
     }

   // Sweep: scan from the more-recent equal swing forward to now (index 0)
   // for a bar that wicks beyond the pool and closes back inside it.
   bool sweepFound = false;
   double sweepStrength = 0.0;
   int sweepBarIdx = -1;
   for(int i = nearIdx - 1; i >= 0; i--)
     {
      CandleData cd = m_candles.GetCandle(i);
      double barATR = m_candles.GetATR(i);
      if(barATR <= 0) continue;
      if(forBuy)
        {
         if(cd.low < poolPrice && cd.close > poolPrice)
           {
            sweepFound = true;
            sweepStrength = MathMax(0.0, MathMin(((poolPrice - cd.low) / barATR) / 0.5, 1.0));
            sweepBarIdx = i;
            break;
           }
        }
      else
        {
         if(cd.high > poolPrice && cd.close < poolPrice)
           {
            sweepFound = true;
            sweepStrength = MathMax(0.0, MathMin(((cd.high - poolPrice) / barATR) / 0.5, 1.0));
            sweepBarIdx = i;
            break;
           }
        }
     }
   r.sweepFound = sweepFound;
   r.sweepScore = sweepFound ? 25.0 : 0.0;
   if(!sweepFound)
     {
      r.reason = "Internal structure present, but liquidity was never swept — no inducement, no trade";
      return r;
     }

   // v2.9: grade the sweep instead of treating every sweepFound=true the
   // same way. Gate is OFF by default (see ConfigureQualityGates()); the
   // grade/score are always computed so the dashboard can show them even
   // when the gate isn't enforcing anything yet.
   double sweepGradeScore;
   ENUM_SWEEP_GRADE sweepGrade = GradeSweep(sweepBarIdx, forBuy, poolPrice, sweepGradeScore);
   r.sweepGrade = sweepGrade;
   r.sweepGradeScore = sweepGradeScore;
   r.barsSinceSweep = sweepBarIdx;
   // Sweep quality now WEIGHTS the 25-pt sweep score instead of it being
   // flat 0-or-25 — a barely-qualifying C sweep and a decisive A sweep no
   // longer score identically just because both technically passed.
   r.sweepScore = 25.0 * MathMax(sweepGradeScore, 0.15); // floor at 0.15 so a bare pass isn't scored as ~0
   if(m_requireMinSweepGrade && (int)sweepGrade < (int)m_minSweepGrade)
     {
      r.reason = StringFormat("Sweep found but graded %s (below required minimum) — weak penetration/reclaim/follow-through",
                               sweepGrade == SWEEP_GRADE_C ? "C" : "B");
      return r;
     }

   // Confirming minor BOS: after the sweep, price must close back beyond
   // the opposing minor swing formed during the pullback (a small
   // structure break confirming the reversal continues with the impulse).
   double minorOpp = forBuy ? -DBL_MAX : DBL_MAX;
   for(int i = sweepBarIdx; i <= pullbackTo; i++)
     {
      if(!FindMinorSwing(i, forBuy)) continue; // forBuy -> looking for a minor HIGH to break above
      double p = forBuy ? m_candles.GetCandle(i).high : m_candles.GetCandle(i).low;
      if(forBuy && p > minorOpp) minorOpp = p;
      if(!forBuy && p < minorOpp) minorOpp = p;
     }
   bool bosConfirmed = false;
   int bosBarIdx = -1;
   if((forBuy && minorOpp > -DBL_MAX) || (!forBuy && minorOpp < DBL_MAX))
     {
      for(int i = sweepBarIdx - 1; i >= 0; i--)
        {
         CandleData cd = m_candles.GetCandle(i);
         if(forBuy && cd.close > minorOpp) { bosConfirmed = true; bosBarIdx = i; break; }
         if(!forBuy && cd.close < minorOpp) { bosConfirmed = true; bosBarIdx = i; break; }
        }
     }
   r.bosConfirmed = bosConfirmed;
   if(!bosConfirmed)
     {
      r.bosScore = 0.0;
      r.reason = "Liquidity swept, but no confirming minor BOS yet — wait for structure to break";
      return r;
     }

   // v2.9: continuous BOS strength replaces the flat 20-or-0 score, plus
   // time decay on how stale the confirmed setup already is.
   double bosStrength = BOSStrength(bosBarIdx, minorOpp, forBuy);
   r.bosStrength = bosStrength;
   r.bosScore = 20.0 * MathMax(bosStrength, 0.15);
   r.barsSinceBOS = bosBarIdx;
   r.bosBarIndex = bosBarIdx;
   r.bosClosePrice = m_candles.GetCandle(bosBarIdx).close;
   double timeDecay = TimeDecay(bosBarIdx);
   r.timeDecay = timeDecay;
   if(m_requireFreshSetup && timeDecay <= 0.0)
     {
      r.reason = StringFormat("Sweep/BOS confirmed but setup is stale (%d bars since BOS, max %d)",
                               bosBarIdx, m_maxBarsSinceBOS);
      return r;
     }

   r.valid = true;
   r.leg = leg;
   r.totalScore = (r.impulseScore + r.structureScore + r.sweepScore + r.bosScore) * MathMax(timeDecay, 0.15);
   r.reason = StringFormat("Inducement sequence confirmed: impulse -> pullback structure -> %s sweep -> BOS (strength %.0f%%, decay %.0f%%)",
                            sweepGrade == SWEEP_GRADE_A ? "A-grade" : sweepGrade == SWEEP_GRADE_B ? "B-grade" : "C-grade",
                            bosStrength * 100.0, timeDecay * 100.0);
   return r;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/SmartMoney/Inducement.mqh ----


// ---- BEGIN EA/includes/SmartMoney/PremiumDiscount.mqh ----
//+------------------------------------------------------------------+
//|                                      SmartMoney/PremiumDiscount.mqh |
//+------------------------------------------------------------------+
#ifndef PREMIUMDISCOUNT_MQH
#define PREMIUMDISCOUNT_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----

// Static helper — no state, so no Init()/instance needed. Equilibrium is
// just the midpoint of a range; buys should only trigger below it
// (discount), sells only above it (premium). Deliberately takes a plain
// (high, low) pair rather than owning its own range source, so callers
// can feed it the impulse range (as the spec asks for), a swing range, or
// anything else without this file needing to know about ImpulseLeg.
class CPremiumDiscount
  {
public:
   static double     Equilibrium(double rangeHigh, double rangeLow) { return (rangeHigh + rangeLow) / 2.0; }
   static bool       IsDiscount(double price, double rangeHigh, double rangeLow)
     {
      if(rangeHigh <= rangeLow) return false;
      return price < Equilibrium(rangeHigh, rangeLow);
     }
   static bool       IsPremium(double price, double rangeHigh, double rangeLow)
     {
      if(rangeHigh <= rangeLow) return false;
      return price > Equilibrium(rangeHigh, rangeLow);
     }
   // Convenience wrapper for the impulse-range use case specifically.
   // LOCATION filter (see gate convention, Core/Config.mqh) — fails open
   // on purpose: with no range there's no "wrong side" to be on.
   static bool       OK(bool forBuy, double price, const ImpulseLeg &leg)
     {
      if(!leg.valid) return true; // no range to check against — don't block on missing data
      double hi = MathMax(leg.start_price, leg.end_price);
      double lo = MathMin(leg.start_price, leg.end_price);
      return forBuy ? IsDiscount(price, hi, lo) : IsPremium(price, hi, lo);
     }
  };
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/SmartMoney/PremiumDiscount.mqh ----


// ---- BEGIN EA/includes/SmartMoney/MarketPhase.mqh ----
//+------------------------------------------------------------------+
//|                                         SmartMoney/MarketPhase.mqh |
//+------------------------------------------------------------------+
#ifndef MARKETPHASE_MQH
#define MARKETPHASE_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----


// ---- BEGIN EA/includes/SmartMoney/Liquidity.mqh ----

// ---- END EA/includes/SmartMoney/Liquidity.mqh ----

// HONEST CAVEAT: this is the least rigorously-defined concept in the
// v2.1 upgrade — "accumulation / manipulation / distribution" is a
// narrative description, not something with a single agreed-upon
// technical definition the way BOS or an FVG is. What follows is a
// reasonable, ATR-relative heuristic (range compression -> recent sweep
// -> recent displacement), not a claim that it detects "institutional
// intent". Treat it as a supplementary filter, not a ground truth signal
// — that's why it ships as an optional gate (default OFF) rather than a
// hard requirement like the Inducement engine's sweep+BOS check.
class CMarketPhase
  {
private:
   CCandleData*      m_candles;
   CLiquidity*       m_liquidity;
   int               m_rangeLookback;
   double            m_compressionATRMult;
   int               m_sweepRecencyBars;
   double            m_displacementATRMult;

   bool              IsDisplacementBar(int idx);

public:
                     CMarketPhase();
   void              Init(CCandleData* candles, CLiquidity* liquidity, int rangeLookback = 20,
                          double compressionATRMult = 2.5, int sweepRecencyBars = 6,
                          double displacementATRMult = 1.2);
   ENUM_MARKET_PHASE Detect();
  };
//+------------------------------------------------------------------+
CMarketPhase::CMarketPhase() : m_candles(NULL), m_liquidity(NULL), m_rangeLookback(20),
                                m_compressionATRMult(2.5), m_sweepRecencyBars(6), m_displacementATRMult(1.2) {}
//+------------------------------------------------------------------+
void CMarketPhase::Init(CCandleData* candles, CLiquidity* liquidity, int rangeLookback,
                        double compressionATRMult, int sweepRecencyBars, double displacementATRMult)
  {
   m_candles = candles;
   m_liquidity = liquidity;
   m_rangeLookback = MathMax(5, rangeLookback);
   m_compressionATRMult = compressionATRMult;
   m_sweepRecencyBars = MathMax(1, sweepRecencyBars);
   m_displacementATRMult = displacementATRMult;
  }
//+------------------------------------------------------------------+
bool CMarketPhase::IsDisplacementBar(int idx)
  {
   if(m_candles == NULL) return false;
   CandleData cd = m_candles.GetCandle(idx);
   double atr = m_candles.GetATR(idx);
   if(atr <= 0) return false;
   double range = cd.high - cd.low;
   if(range <= 0) return false;
   double body = MathAbs(cd.close - cd.open);
   return (range / atr >= m_displacementATRMult) && (body / range >= 0.5);
  }
//+------------------------------------------------------------------+
ENUM_MARKET_PHASE CMarketPhase::Detect()
  {
   if(m_candles == NULL || m_candles.Total() < m_rangeLookback + 2) return PHASE_UNDEFINED;
   double atr = m_candles.GetATR(0);
   if(atr <= 0) return PHASE_UNDEFINED;

   double hh = -DBL_MAX, ll = DBL_MAX;
   for(int i = 0; i < m_rangeLookback; i++)
     {
      CandleData cd = m_candles.GetCandle(i);
      if(cd.high > hh) hh = cd.high;
      if(cd.low  < ll) ll = cd.low;
     }
   bool compressed = ((hh - ll) / atr) <= m_compressionATRMult;

   bool recentSweep = false;
   if(m_liquidity != NULL && m_liquidity.EventCount() > 0)
     {
      LiquidityEvent ev = m_liquidity.GetEvent(0);
      if(ev.bar_index <= m_sweepRecencyBars) recentSweep = true;
     }

   bool recentDisplacement = false;
   for(int i = 0; i < MathMin(3, m_sweepRecencyBars); i++)
      if(IsDisplacementBar(i)) { recentDisplacement = true; break; }

   if(recentSweep && recentDisplacement) return PHASE_DISTRIBUTION;
   if(recentSweep) return PHASE_MANIPULATION;
   if(compressed) return PHASE_ACCUMULATION;
   return PHASE_UNDEFINED;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/SmartMoney/MarketPhase.mqh ----


// ---- BEGIN EA/includes/SmartMoney/OrderBlock.mqh ----

// ---- END EA/includes/SmartMoney/OrderBlock.mqh ----


// ---- BEGIN EA/includes/Analysis/VolatilityRegime.mqh ----
//+------------------------------------------------------------------+
//|                                     Analysis/VolatilityRegime.mqh |
//+------------------------------------------------------------------+
#ifndef VOLATILITYREGIME_MQH
#define VOLATILITYREGIME_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----

// v2.8 addition. CMarketPhase already answers "is price compressed into a
// range right now" (binary, range/ATR vs one threshold). This answers a
// different question: "is the CURRENT bar's ATR itself unusually low or
// high relative to its own recent history" — independent of whether price
// is trending or ranging. A trending market can still be in a low-vol
// grind (thin follow-through, bad R:R) or a high-vol expansion (news-leg,
// needs a wider stop than the static 1.5xATR default). Percentile-based,
// not a fixed multiple, so it self-calibrates per symbol/timeframe
// instead of needing a magic constant re-tuned per instrument.
class CVolatilityRegime
  {
private:
   CCandleData*      m_candles;
   int                m_lookback;
   double             m_lowPct;     // e.g. 0.25 -> bottom quartile = LOW
   double             m_highPct;    // e.g. 0.75 -> top quartile = HIGH

public:
                     CVolatilityRegime();
   void              Init(CCandleData* candleData, int lookback = 100, double lowPct = 0.25, double highPct = 0.75);
   ENUM_VOL_REGIME    Classify(int shift = 0);
   double             CurrentATRPercentile(int shift = 0); // 0..1, for diagnostics/CSV
  };
//+------------------------------------------------------------------+
CVolatilityRegime::CVolatilityRegime() : m_candles(NULL), m_lookback(100), m_lowPct(0.25), m_highPct(0.75) {}
//+------------------------------------------------------------------+
void CVolatilityRegime::Init(CCandleData* candleData, int lookback, double lowPct, double highPct)
  {
   m_candles = candleData;
   m_lookback = MathMax(20, lookback);
   m_lowPct = lowPct;
   m_highPct = highPct;
  }
//+------------------------------------------------------------------+
double CVolatilityRegime::CurrentATRPercentile(int shift)
  {
   if(m_candles == NULL) return -1.0;
   int total = m_candles.Total();
   if(total < 10) return -1.0;
   double current = m_candles.GetCandle(shift).atr;
   if(current <= 0) return -1.0;

   int n = MathMin(m_lookback, total - shift);
   if(n < 10) return -1.0;

   int below = 0;
   int counted = 0;
   for(int i = shift; i < shift + n; i++)
     {
      double a = m_candles.GetCandle(i).atr;
      if(a <= 0) continue;
      counted++;
      if(a <= current) below++;
     }
   if(counted < 10) return -1.0;
   return (double)below / (double)counted;
  }
//+------------------------------------------------------------------+
ENUM_VOL_REGIME CVolatilityRegime::Classify(int shift)
  {
   double pct = CurrentATRPercentile(shift);
   if(pct < 0) return VOL_REGIME_UNDEFINED;   // fail-closed: unverifiable claim, see Config.mqh gate convention
   if(pct <= m_lowPct) return VOL_REGIME_LOW;
   if(pct >= m_highPct) return VOL_REGIME_HIGH;
   return VOL_REGIME_NORMAL;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Analysis/VolatilityRegime.mqh ----


// ---- BEGIN EA/includes/Core/SessionFilter.mqh ----
//+------------------------------------------------------------------+
//|                                          Core/SessionFilter.mqh   |
//+------------------------------------------------------------------+
#ifndef SESSIONFILTER_MQH
#define SESSIONFILTER_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----

// v2.8 addition. Pre-v2.8 the only session-aware code was
// CSignalLogger::SessionLabel() — a string used purely for CSV bucketing
// after the fact. It was never read by anything that decides whether to
// trade. This class is the actual gate: classifies the current GMT hour
// into a named session and exposes IsAllowed() so Scoring can block
// entries generated during configured-off windows (default: Tokyo-only
// and dead hours off, London/NY/overlap on) instead of trading every
// session uniformly regardless of liquidity.
//
// FIX (audit #20 — DST): London and New York's real trading hours are
// fixed in LOCAL time (roughly 08:00-16:30 London local, 08:00-17:00 NY
// local) — their GMT-hour equivalents shift by exactly 1 hour twice a
// year as each city's own DST turns on/off, AND London/NY don't switch
// on the same calendar date (EU DST: last Sunday of March -> last Sunday
// of October; US DST: second Sunday of March -> first Sunday of
// November — there are multi-week windows every spring and fall where
// one is on DST and the other isn't). The old code used one fixed GMT
// window per session year-round, which was quietly wrong for roughly
// half the year. This now computes each city's own DST status per tick
// and shifts that city's window accordingly, independently.
class CSessionFilter
  {
private:
   bool              m_enabled;
   bool              m_allowTokyo;
   bool              m_allowLondon;
   bool              m_allowNewYork;
   bool              m_allowOverlap;   // London/NY overlap — highest-liquidity window, allowed even if
                                        // m_allowLondon/m_allowNewYork are individually off

   static int        DaysInMonth(int year, int month);
   static datetime   NthSunday(int year, int month, int n); // n>0: nth Sunday; n<0: last Sunday
   static bool       IsEUDST(datetime gmtNow);   // London/EU: last Sun Mar - last Sun Oct
   static bool       IsUSDST(datetime gmtNow);   // New York/US: 2nd Sun Mar - 1st Sun Nov

public:
                     CSessionFilter();
   void              Configure(bool enabled, bool allowTokyo = false, bool allowLondon = true,
                               bool allowNewYork = true, bool allowOverlap = true);
   ENUM_TRADING_SESSION CurrentSession();
   // v2.17 addition — for CExtendedKeyLevels::NearestSessionLevel(),
   // which needs to know WHEN the current session opened, not just
   // which one is active. Reuses the exact same DST-aware start-hour
   // math CurrentSession() already computes, so the two can never
   // silently disagree about where a session's boundary sits. Returns 0
   // during SESSION_DEAD — there is no "current session" to report a
   // start for.
   datetime          CurrentSessionStartGMT();
   bool              IsAllowed(); // true if gate disabled, or current session is in the allow-list
  };
//+------------------------------------------------------------------+
CSessionFilter::CSessionFilter() : m_enabled(false), m_allowTokyo(false), m_allowLondon(true),
                                    m_allowNewYork(true), m_allowOverlap(true) {}
//+------------------------------------------------------------------+
void CSessionFilter::Configure(bool enabled, bool allowTokyo, bool allowLondon, bool allowNewYork, bool allowOverlap)
  {
   m_enabled = enabled;
   m_allowTokyo = allowTokyo;
   m_allowLondon = allowLondon;
   m_allowNewYork = allowNewYork;
   m_allowOverlap = allowOverlap;
  }
//+------------------------------------------------------------------+
int CSessionFilter::DaysInMonth(int year, int month)
  {
   static int dim[] = {31,28,31,30,31,30,31,31,30,31,30,31};
   if(month == 2)
     {
      bool leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
      return leap ? 29 : 28;
     }
   return dim[month - 1];
  }
//+------------------------------------------------------------------+
// n > 0: the n-th Sunday of the month. n < 0: the last Sunday of the month.
datetime CSessionFilter::NthSunday(int year, int month, int n)
  {
   MqlDateTime t;
   ZeroMemory(t);
   t.year = year; t.mon = month; t.day = 1; t.hour = 0; t.min = 0; t.sec = 0;
   datetime firstOfMonth = StructToTime(t);
   MqlDateTime t1;
   TimeToStruct(firstOfMonth, t1);
   int dow = t1.day_of_week; // 0 = Sunday
   int firstSundayDay = 1 + ((7 - dow) % 7);

   if(n > 0)
     {
      t.day = firstSundayDay + (n - 1) * 7;
      return StructToTime(t);
     }
   // last Sunday: walk back from the last day of the month
   int lastDay = DaysInMonth(year, month);
   t.day = lastDay;
   datetime lastOfMonth = StructToTime(t);
   MqlDateTime tl;
   TimeToStruct(lastOfMonth, tl);
   t.day = lastDay - tl.day_of_week;
   return StructToTime(t);
  }
//+------------------------------------------------------------------+
bool CSessionFilter::IsEUDST(datetime gmtNow)
  {
   MqlDateTime t;
   TimeToStruct(gmtNow, t);
   datetime start = NthSunday(t.year, 3, -1);   // last Sunday of March, 01:00 UTC transition
   datetime end   = NthSunday(t.year, 10, -1);  // last Sunday of October, 01:00 UTC transition
   return (gmtNow >= start && gmtNow < end);
  }
//+------------------------------------------------------------------+
bool CSessionFilter::IsUSDST(datetime gmtNow)
  {
   MqlDateTime t;
   TimeToStruct(gmtNow, t);
   datetime start = NthSunday(t.year, 3, 2);    // 2nd Sunday of March, ~07:00 UTC transition (2am EST)
   datetime end   = NthSunday(t.year, 11, 1);   // 1st Sunday of November, ~06:00 UTC transition (2am EDT)
   return (gmtNow >= start && gmtNow < end);
  }
//+------------------------------------------------------------------+
// London local session ~08:00-16:30; New York local session ~08:00-17:00.
// Each city's own DST state shifts its GMT window by exactly one hour.
ENUM_TRADING_SESSION CSessionFilter::CurrentSession()
  {
   datetime nowGmt = TimeGMT();
   MqlDateTime t;
   TimeToStruct(nowGmt, t);
   int h = t.hour;

   bool londonDST = IsEUDST(nowGmt);
   bool nyDST     = IsUSDST(nowGmt);

   int londonStart = londonDST ? 7  : 8;
   int londonEnd   = londonDST ? 16 : 17;
   int nyStart     = nyDST     ? 12 : 13;
   int nyEnd       = nyDST     ? 21 : 22;

   bool tokyo   = (h >= 0 && h < 9); // Tokyo doesn't observe DST — fixed window, unaffected
   bool london  = (h >= londonStart && h < londonEnd);
   bool newyork = (h >= nyStart && h < nyEnd);

   if(london && newyork) return SESSION_LONDON_NY_OVERLAP;
   if(london)  return SESSION_LONDON;
   if(newyork) return SESSION_NEWYORK;
   if(tokyo)   return SESSION_TOKYO;
   return SESSION_DEAD;
  }
//+------------------------------------------------------------------+
// Same start-hour derivation CurrentSession() uses, just returning the
// GMT timestamp of today's boundary instead of a bool membership test.
// SESSION_LONDON_NY_OVERLAP starts when the LATER of the two opens (NY,
// in every real-world case here) — the overlap by definition can't have
// begun before both sides are open.
datetime CSessionFilter::CurrentSessionStartGMT()
  {
   datetime nowGmt = TimeGMT();
   MqlDateTime t;
   TimeToStruct(nowGmt, t);

   bool londonDST = IsEUDST(nowGmt);
   bool nyDST     = IsUSDST(nowGmt);
   int londonStart = londonDST ? 7  : 8;
   int nyStart     = nyDST     ? 12 : 13;

   ENUM_TRADING_SESSION s = CurrentSession();
   int startHour;
   switch(s)
     {
      case SESSION_LONDON_NY_OVERLAP: startHour = nyStart;     break;
      case SESSION_LONDON:            startHour = londonStart; break;
      case SESSION_NEWYORK:           startHour = nyStart;     break;
      case SESSION_TOKYO:             startHour = 0;           break; // Tokyo doesn't observe DST — fixed window, unaffected
      default:                        return 0;                       // SESSION_DEAD — no boundary to report
     }

   MqlDateTime st = t;
   st.hour = startHour;
   st.min = 0;
   st.sec = 0;
   return StructToTime(st);
  }
//+------------------------------------------------------------------+
bool CSessionFilter::IsAllowed()
  {
   if(!m_enabled) return true; // fail-open when the gate itself is off — matches the
                                // Config.mqh LOCATION-filter convention: "no filter configured" != "wrong side"
   ENUM_TRADING_SESSION s = CurrentSession();
   switch(s)
     {
      case SESSION_LONDON_NY_OVERLAP: return m_allowOverlap;
      case SESSION_LONDON:            return m_allowLondon;
      case SESSION_NEWYORK:           return m_allowNewYork;
      case SESSION_TOKYO:             return m_allowTokyo;
      default:                        return false; // SESSION_DEAD — off by design, no allow flag for it
     }
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Core/SessionFilter.mqh ----


// ---- BEGIN EA/includes/Core/PipCalculator.mqh ----
//+------------------------------------------------------------------+
//|                                          Core/PipCalculator.mqh   |
//+------------------------------------------------------------------+
#ifndef PIPCALCULATOR_MQH
#define PIPCALCULATOR_MQH

// v2.9 addition. Scoring.mqh already computed this correctly (from
// SYMBOL_DIGITS/SYMBOL_POINT, not a hardcoded 0.0001) — this doesn't fix
// a live bug, it centralizes the ONE place that logic lives so every new
// consumer (Telegram payload pip display, dashboard, future risk
// tooling) uses the same definition instead of each re-deriving it and
// risking divergence on JPY pairs / gold / indices / 3-5 digit brokers.
//
// Convention: a "pip" is the traditional 4th decimal for most FX pairs
// (2nd for JPY pairs) — i.e. point*10 on a 5-digit broker, point*10 on a
// 3-digit JPY broker, and point*1 on a classic 4-digit broker. This
// matches MetaTrader's own informal pip convention, NOT SYMBOL_POINT
// directly (which is one price increment, not one pip, on 5/3-digit
// brokers). For gold/indices there's no universal "pip" — PipSize()
// still returns something scaled off SYMBOL_POINT/DIGITS, but treat the
// *_Points() variants as the reliable ones for those symbols; Pips() on
// XAUUSD is informational, not a market-standard unit.
class CPipCalculator
  {
public:
   static double     PipSize(string symbol)
     {
      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      if(point <= 0) return 0.0001; // defensive fallback only — should never trigger on a valid symbol
      return (digits == 3 || digits == 5) ? point * 10.0 : point;
     }
   static double     PointSize(string symbol)
     {
      return SymbolInfoDouble(symbol, SYMBOL_POINT);
     }
   // Price distance -> pips (rounded to 1 decimal for display; callers
   // needing raw precision should divide by PipSize() themselves).
   static double     Pips(string symbol, double priceDistance)
     {
      double pip = PipSize(symbol);
      if(pip <= 0) return 0.0;
      return MathAbs(priceDistance) / pip;
     }
   static double     Points(string symbol, double priceDistance)
     {
      double pt = PointSize(symbol);
      if(pt <= 0) return 0.0;
      return MathAbs(priceDistance) / pt;
     }
   // Monetary value of one pip for `lots` lots on `symbol`. Uses
   // SYMBOL_TRADE_TICK_VALUE/TICK_SIZE so it's correct for FX, metals,
   // and indices alike, not just a "$10/pip/lot" FX assumption.
   static double     PipValue(string symbol, double lots)
     {
      double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickSize <= 0) return 0.0;
      double pip = PipSize(symbol);
      return (pip / tickSize) * tickValue * lots;
     }
   // Convenience formatter for signal cards / logs: "87 pips / 870 pts"
   // per the review's debugging recommendation (item #2 of the pips
   // batch) — showing both makes broker-digit mismatches visible instead
   // of silently wrong.
   static string     FormatDistance(string symbol, double priceDistance)
     {
      return StringFormat("%.1f pips / %.0f pts", Pips(symbol, priceDistance), Points(symbol, priceDistance));
     }
  };
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Core/PipCalculator.mqh ----


// ---- BEGIN EA/includes/Regime/RegimeDetector.mqh ----
//+------------------------------------------------------------------+
//|                                       Regime/RegimeDetector.mqh   |
//+------------------------------------------------------------------+
#ifndef REGIMEDETECTOR_MQH
#define REGIMEDETECTOR_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Analysis/TrendEngine.mqh ----

// ---- END EA/includes/Analysis/TrendEngine.mqh ----


// ---- BEGIN EA/includes/Analysis/VolatilityRegime.mqh ----

// ---- END EA/includes/Analysis/VolatilityRegime.mqh ----


// ---- BEGIN EA/includes/SmartMoney/MarketPhase.mqh ----

// ---- END EA/includes/SmartMoney/MarketPhase.mqh ----

// v2.12 addition. Everything downstream in the multi-strategy design
// (Momentum/Breakout vs Mean Reversion vs Key-Level Price Action) is
// supposed to branch off "what kind of market is this", so this is
// built first, and deliberately reuses the three reads that already
// exist rather than inventing a fourth "is this trending" heuristic:
//   - CTrendEngine.GetCurrentTrend()   -> BOS-backed swing structure
//   - CVolatilityRegime.Classify()     -> ATR-percentile expansion/compression
//   - CMarketPhase.Detect()            -> range-compression + sweep/displacement read
//
// THE HONEST LIMIT: CMarketPhase's own header already flags itself as
// "the least rigorously-defined concept" in this codebase — a narrative
// heuristic, not a proven detector. This class inherits that limit
// rather than hiding it: REGIME_TRANSITION is deliberately the catch-all
// for everything that isn't a clean TRENDING or RANGING read, instead of
// forcing every bar into one of two buckets a weak signal can't actually
// support.
//
// DIAGNOSTIC ONLY. Nothing reads Classify()'s return value except
// CSV logging (see SetupReasons.regime in Core/Config.mqh) and, later,
// the strategy-selection engine this doc argues for — which does not
// exist yet. No entry filter, confidence calculation, or order path
// consults this today.
class CRegimeDetector
  {
private:
   CTrendEngine*        m_trend;
   CVolatilityRegime*   m_volRegime;
   CMarketPhase*        m_phase;

public:
                        CRegimeDetector() : m_trend(NULL), m_volRegime(NULL), m_phase(NULL) {}
   void                 Init(CTrendEngine* trend, CVolatilityRegime* volRegime, CMarketPhase* phase)
     {
      m_trend = trend;
      m_volRegime = volRegime;
      m_phase = phase;
     }
   ENUM_MARKET_REGIME   Classify();
  };
//+------------------------------------------------------------------+
ENUM_MARKET_REGIME CRegimeDetector::Classify()
  {
   if(m_trend == NULL || m_volRegime == NULL || m_phase == NULL)
      return REGIME_UNDEFINED;

   ENUM_TREND_STATE  trend = m_trend.GetCurrentTrend();
   ENUM_VOL_REGIME   vol   = m_volRegime.Classify(0);
   ENUM_MARKET_PHASE phase = m_phase.Detect();

   // Fail closed on an unverifiable volatility read, same convention as
   // every other percentile-based gate in this codebase (see
   // CVolatilityRegime::Classify's own comment).
   if(vol == VOL_REGIME_UNDEFINED)
      return REGIME_UNDEFINED;

   bool strongTrend = (trend == TREND_BULL_STRONG || trend == TREND_BEAR_STRONG);
   bool weakTrend    = (trend == TREND_BULL || trend == TREND_BEAR);

   // TRENDING: BOS-confirmed directional structure, and volatility is not
   // in a thin/choppy low-vol grind (LOW regime specifically flagged
   // elsewhere in this codebase as "thin, choppy, spread-risk-heavy" —
   // exactly the condition that makes a "trend" unreliable to trade).
   if(strongTrend && vol != VOL_REGIME_LOW)
      return REGIME_TRENDING;

   // RANGING: no directional structure at all, AND price is compressed
   // into a range with no recent sweep/displacement contaminating the
   // read (ACCUMULATION is CMarketPhase's own name for exactly this).
   if(trend == TREND_NEUTRAL && phase == PHASE_ACCUMULATION)
      return REGIME_RANGING;

   // Everything else is TRANSITION by construction: a weak/unconfirmed
   // trend, a strong trend fighting low volatility, a recent sweep or
   // displacement (MANIPULATION/DISTRIBUTION) that hasn't resolved into
   // either a clean trend or a clean range yet, or PHASE_UNDEFINED with
   // no compression to fall back on. This is not "figured it out and
   // it's ambiguous" — it's "the available reads don't support a
   // stronger claim", which is the same fail-closed posture the rest of
   // this class takes on VOL_REGIME_UNDEFINED above.
   return REGIME_TRANSITION;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Regime/RegimeDetector.mqh ----


// ---- BEGIN EA/includes/Strategies/MomentumBreakout.mqh ----
//+------------------------------------------------------------------+
//|                                 Strategies/MomentumBreakout.mqh   |
//+------------------------------------------------------------------+
#ifndef MOMENTUMBREAKOUT_MQH
#define MOMENTUMBREAKOUT_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----


// ---- BEGIN EA/includes/Structure/BOS.mqh ----

// ---- END EA/includes/Structure/BOS.mqh ----


// ---- BEGIN EA/includes/SmartMoney/Liquidity.mqh ----

// ---- END EA/includes/SmartMoney/Liquidity.mqh ----


// ---- BEGIN EA/includes/Analysis/VolatilityRegime.mqh ----

// ---- END EA/includes/Analysis/VolatilityRegime.mqh ----

// v2.12 addition. Strategy module #1 of the multi-strategy architecture
// (see docs/CHANGELOG.md v2.12 entry) — Mean Reversion and the Key-Level
// Price Action engine are next, not built yet. Deliberately reuses
// existing primitives instead of reimplementing them:
//   - CBOS already stores BOSEvent.strength (0-1, displacement/ATR +
//     volume ratio composite) and BOSEvent.bar_index (recency) per
//     event — that IS the "genuine displacement? volume abnormal?"
//     read the spec asked for, computed once by CBOS::Detect() and
//     reused here rather than recomputed.
//   - CLiquidity's own event list is reused to detect the overlap case
//     ("liquidity breakout... interesting because it overlaps with your
//     SMC engine") rather than guessing at a second sweep detector.
//
// CLASSIFICATION (BREAKOUT_*, see Core/Config.mqh for definitions):
//   FAILED     : checked first — price already closed back on the wrong
//                side of the broken level. Whatever else was true about
//                the break, it didn't hold, so this overrides every
//                other label.
//   LIQUIDITY  : the BOS bar coincides (within m_liqOverlapBars) with a
//                liquidity-sweep event. Checked before EXPANSION/
//                EXHAUSTION because a sweep-driven break and a pure
//                displacement break are different setups even when the
//                raw strength score looks similar.
//   EXHAUSTION : price was already extended (pre-break run measured over
//                m_extensionLookbackBars, in ATR) beyond m_exhaustionATR
//                BEFORE the break bar — a strong strength score here is
//                the doc's warning case ("do not chase"), not a green
//                light.
//   EXPANSION  : none of the above — fresh, displacement-and-volume-
//                backed, not already extended, not sweep-driven.
//   NONE       : no BOS in the setup direction within m_recencyBars.
//
// MOMENTUM SCORE is a separate, simpler read from BREAKOUT SCORE: net
// directional close-to-close movement over m_momentumLookbackBars,
// scaled by that window's own average ATR. This is a plain rate-of-
// change-over-volatility heuristic, not a proprietary momentum
// indicator — stated plainly per this codebase's convention of not
// overclaiming what a heuristic proves (see MarketPhase.mqh's own
// caveat for the precedent).
//
// DIAGNOSTIC ONLY. See Regime/RegimeDetector.mqh's header for the same
// disclosure: nothing here feeds CalculateConfidence(), CDecisionEngine,
// or order sizing. Read only by CSV logging today.
class CMomentumBreakoutEngine
  {
private:
   CCandleData*         m_candles;
   CBOS*                m_bos;
   CLiquidity*          m_liquidity;
   CVolatilityRegime*   m_volRegime;

   int                  m_recencyBars;            // how far back a BOS still counts as "recent" (default 10)
   int                  m_liqOverlapBars;          // BOS/liquidity bar_index gap allowed to call it LIQUIDITY (default 2)
   int                  m_extensionLookbackBars;   // window checked BEFORE the break bar for pre-existing extension (default 15)
   double               m_exhaustionATRMult;       // pre-break run, in ATR, above which a break counts as EXHAUSTION (default 3.0)
   int                  m_momentumLookbackBars;    // window for the momentum score (default 10)

   bool                 FindRecentBOS(bool forBuy, BOSEvent &out);
   bool                 HasNearbyLiquidityEvent(int barIndex);
   bool                 ClosedBackAcross(const BOSEvent &ev, bool forBuy);
   double               PreBreakExtensionATR(int barIndex, bool forBuy);

public:
                        CMomentumBreakoutEngine() : m_candles(NULL), m_bos(NULL), m_liquidity(NULL), m_volRegime(NULL),
                                                     m_recencyBars(10), m_liqOverlapBars(2),
                                                     m_extensionLookbackBars(15), m_exhaustionATRMult(3.0),
                                                     m_momentumLookbackBars(10) {}
   void                 Init(CCandleData* candles, CBOS* bos, CLiquidity* liquidity, CVolatilityRegime* volRegime)
     {
      m_candles = candles;
      m_bos = bos;
      m_liquidity = liquidity;
      m_volRegime = volRegime;
     }
   // All defaults above are starting points, not tuned constants — same
   // discipline note as every other Configure*() in this codebase
   // (e.g. CScoringEngine::ConfigureLearnedDiagnostics).
   void                 Configure(int recencyBars = 10, int liqOverlapBars = 2,
                                   int extensionLookbackBars = 15, double exhaustionATRMult = 3.0,
                                   int momentumLookbackBars = 10)
     {
      m_recencyBars = MathMax(1, recencyBars);
      m_liqOverlapBars = MathMax(0, liqOverlapBars);
      m_extensionLookbackBars = MathMax(1, extensionLookbackBars);
      m_exhaustionATRMult = (exhaustionATRMult > 0) ? exhaustionATRMult : 3.0;
      m_momentumLookbackBars = MathMax(1, momentumLookbackBars);
     }

   void                 Evaluate(bool forBuy, double &momentumScore, double &breakoutScore, ENUM_BREAKOUT_CLASS &breakoutClass);
  };
//+------------------------------------------------------------------+
// Scans most-recent-first for the first BOS event whose direction
// matches forBuy and whose bar_index is within m_recencyBars. GetBOS(0)
// alone isn't enough — the single most recent BOS overall may be in the
// OPPOSITE direction to the setup being evaluated.
bool CMomentumBreakoutEngine::FindRecentBOS(bool forBuy, BOSEvent &out)
  {
   if(m_bos == NULL) return false;
   int n = m_bos.Count();
   for(int i = 0; i < n; i++)
     {
      BOSEvent ev = m_bos.GetBOS(i);
      if(ev.bar_index > m_recencyBars) break; // events are stored most-recent-first; once we're past the window, nothing later helps
      if(ev.is_bullish == forBuy)
        {
         out = ev;
         return true;
        }
     }
   return false;
  }
//+------------------------------------------------------------------+
bool CMomentumBreakoutEngine::HasNearbyLiquidityEvent(int barIndex)
  {
   if(m_liquidity == NULL) return false;
   int n = m_liquidity.EventCount();
   for(int i = 0; i < n; i++)
     {
      LiquidityEvent ev = m_liquidity.GetEvent(i);
      if(MathAbs(ev.bar_index - barIndex) <= m_liqOverlapBars)
         return true;
      if(ev.bar_index - barIndex > m_liqOverlapBars + m_recencyBars) break; // sorted most-recent-first; far enough away we can stop
     }
   return false;
  }
//+------------------------------------------------------------------+
// Has price, since the break, closed back on the WRONG side of the
// level that was broken? ev.price is the level; a bullish BOS failing
// means a later (more recent, lower shift) candle closed back below it.
bool CMomentumBreakoutEngine::ClosedBackAcross(const BOSEvent &ev, bool forBuy)
  {
   if(m_candles == NULL) return false;
   for(int shift = 0; shift < ev.bar_index; shift++)
     {
      CandleData cd = m_candles.GetCandle(shift);
      if(forBuy && cd.close < ev.price) return true;
      if(!forBuy && cd.close > ev.price) return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
// How far, in ATR, price had already moved in the setup's direction
// over the m_extensionLookbackBars BEFORE the break bar — i.e. was the
// move already extended before this breakout even happened.
double CMomentumBreakoutEngine::PreBreakExtensionATR(int barIndex, bool forBuy)
  {
   if(m_candles == NULL) return 0.0;
   int startShift = barIndex + 1;
   int endShift = barIndex + m_extensionLookbackBars;
   if(endShift >= m_candles.Total()) endShift = m_candles.Total() - 1;
   if(startShift >= endShift) return 0.0;

   double atr = m_candles.GetATR(barIndex);
   if(atr <= 0) return 0.0;

   CandleData startCd = m_candles.GetCandle(endShift);   // older
   CandleData endCd   = m_candles.GetCandle(startShift); // just before the break
   double move = forBuy ? (endCd.close - startCd.close) : (startCd.close - endCd.close);
   return move / atr; // negative if price moved the "wrong" way before the break — not extended
  }
//+------------------------------------------------------------------+
void CMomentumBreakoutEngine::Evaluate(bool forBuy, double &momentumScore, double &breakoutScore, ENUM_BREAKOUT_CLASS &breakoutClass)
  {
   momentumScore = 0.0;
   breakoutScore = 0.0;
   breakoutClass = BREAKOUT_NONE;

   // --- momentum score: independent of whether a BOS exists at all ---
   if(m_candles != NULL && m_candles.Total() > m_momentumLookbackBars + 1)
     {
      double sumAtr = 0.0;
      int atrCount = 0;
      for(int i = 0; i < m_momentumLookbackBars; i++)
        {
         double a = m_candles.GetATR(i);
         if(a > 0) { sumAtr += a; atrCount++; }
        }
      if(atrCount > 0)
        {
         double avgAtr = sumAtr / atrCount;
         CandleData now = m_candles.GetCandle(0);
         CandleData then = m_candles.GetCandle(m_momentumLookbackBars);
         double netMove = forBuy ? (now.close - then.close) : (then.close - now.close);
         double raw = netMove / (avgAtr * m_momentumLookbackBars * 0.35); // 0.35 = expected fraction of ATR moved per bar in a genuine trend; empirical starting point, not fit
         momentumScore = MathMax(0.0, MathMin(raw * 100.0, 100.0));
        }
     }

   // --- breakout classification: requires a recent BOS in this direction ---
   BOSEvent ev;
   if(!FindRecentBOS(forBuy, ev))
      return; // stays BREAKOUT_NONE / breakoutScore 0.0

   breakoutScore = MathMax(0.0, MathMin(ev.strength * 100.0, 100.0));

   if(ClosedBackAcross(ev, forBuy))
     {
      breakoutClass = BREAKOUT_FAILED;
      return;
     }
   if(HasNearbyLiquidityEvent(ev.bar_index))
     {
      breakoutClass = BREAKOUT_LIQUIDITY;
      return;
     }
   if(PreBreakExtensionATR(ev.bar_index, forBuy) >= m_exhaustionATRMult)
     {
      breakoutClass = BREAKOUT_EXHAUSTION;
      return;
     }
   breakoutClass = BREAKOUT_EXPANSION;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Strategies/MomentumBreakout.mqh ----


// ---- BEGIN EA/includes/Strategies/MeanReversion.mqh ----
//+------------------------------------------------------------------+
//|                                    Strategies/MeanReversion.mqh   |
//+------------------------------------------------------------------+
#ifndef MEANREVERSION_MQH
#define MEANREVERSION_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----


// ---- BEGIN EA/includes/SmartMoney/SupportResistance.mqh ----

// ---- END EA/includes/SmartMoney/SupportResistance.mqh ----


// ---- BEGIN EA/includes/SmartMoney/ValueAreaEngine.mqh ----

// ---- END EA/includes/SmartMoney/ValueAreaEngine.mqh ----


// ---- BEGIN EA/includes/SmartMoney/Liquidity.mqh ----

// ---- END EA/includes/SmartMoney/Liquidity.mqh ----


// ---- BEGIN EA/includes/Structure/BOS.mqh ----

// ---- END EA/includes/Structure/BOS.mqh ----


// ---- BEGIN EA/includes/Analysis/VolatilityRegime.mqh ----

// ---- END EA/includes/Analysis/VolatilityRegime.mqh ----

// v2.13 addition. Strategy module #2 of the multi-strategy architecture
// (see Strategies/MomentumBreakout.mqh for module #1 and the same
// rationale for building one module at a time). Reuses existing
// primitives rather than reimplementing them:
//   - CValueAreaEngine.VAH()/VAL()   -> "statistically stretched price"
//   - CSupportResistance zones       -> "rejection at established level"
//   - CLiquidity's event list        -> "liquidity sweep"
//   - CBOS's stored BOSEvent.strength -> "declining momentum" read,
//     inverted: a STRONG opposing BOS means momentum is NOT declining,
//     which is this module's trend-conflict override.
//
// TWO QUALIFYING PATHS, not one bar:
//   VALUE_FADE       : price stretched beyond a value-area edge by at
//                      least m_minStretchATR, AND (a rejection wick OR
//                      a confirming liquidity sweep). The stronger path
//                      — the doc's primary case.
//   LEVEL_REJECTION  : price at a plain SR zone with a rejection wick,
//                      with no value-area stretch requirement. The
//                      weaker path — still a real setup, scored lower.
//   NONE             : neither path's minimum bar (wick OR SR touch) is
//                      met at all.
//   TREND_CONFLICT   : OVERRIDES either path above. A recent BOS in the
//                      direction the stretch is already moving (i.e.
//                      AGAINST the proposed fade) with strength at or
//                      above m_trendConflictMinStrength means the move
//                      being faded is still structurally confirmed.
//                      Per the doc: "mean reversion should not fight a
//                      strong trend merely because price looks
//                      expensive." The classification changes; the
//                      underlying reversion_score is left as computed
//                      rather than zeroed, so the CSV still shows "this
//                      looked like a fade, and here's why it's flagged
//                      risky" instead of erasing the read.
//
// TIMEFRAME NOTE (same disclosure as MomentumBreakout.mqh): candles/SR/
// value-area here are the chart-TF context (m_srCtx), so ATR and price
// distance are self-consistent. The liquidity and BOS pointers this
// class takes may belong to DIFFERENT timeframes if the EA is
// configured that way (InpLiquidityTF / InpBOSTF) — the same
// cross-timeframe caveat MomentumBreakout.mqh already carries, not a
// new one introduced here.
//
// "CONTROLLED VOLATILITY": the doc lists this as a qualifying condition,
// not just a bonus. Implemented as a simple gate — VOL_REGIME_HIGH
// suppresses the score's volatility component to 0 rather than
// disqualifying the setup outright, since a single percentile read
// shouldn't unilaterally veto a setup that's otherwise well-formed;
// scoring it low still lets it show up as a weak signal in the CSV
// rather than disappearing.
//
// DIAGNOSTIC ONLY. Same as every other v2.1x addition: nothing here
// feeds CalculateConfidence(), CDecisionEngine, or order sizing.
class CMeanReversionEngine
  {
private:
   CCandleData*         m_candles;      // chart-TF (m_srCtx.candles) — same context as m_sr/m_valueArea
   CSupportResistance*  m_sr;           // chart-TF SR zones
   CValueAreaEngine*    m_valueArea;    // chart-TF POC/VAH/VAL
   CLiquidity*          m_liquidity;    // see timeframe note above
   CVolatilityRegime*   m_volRegime;    // chart-TF instance — see Analysis/Scoring.mqh wiring note (deliberately separate from the BOS-TF instance Momentum/Regime use)
   CBOS*                m_opposingBos;  // see timeframe note above

   double               m_minStretchATR;            // VA-edge stretch, in ATR, required for the VALUE_FADE path (default 1.0)
   double               m_srZoneATRTolerance;        // how close price must be to an SR zone edge, in ATR, to count as "at" it (default 0.25)
   double               m_wickRejectionRatio;        // wick length / total range required to call a candle a rejection (default 0.55)
   int                  m_liqRecencyBars;            // how far back a sweep still counts as confirmation (default 10)
   int                  m_trendConflictRecencyBars;  // how far back an opposing BOS still counts as live conflict (default 10)
   double               m_trendConflictMinStrength;  // BOSEvent.strength (0-1) threshold to call it a real conflict (default 0.5)

   bool                 HasNearbySRZone(double price, double atr, bool forBuy);
   bool                 RejectionWickPresent(bool forBuy);
   bool                 HasRecentOpposingSweep(bool forBuy);
   bool                 HasTrendConflict(bool forBuy);

public:
                        CMeanReversionEngine() : m_candles(NULL), m_sr(NULL), m_valueArea(NULL), m_liquidity(NULL),
                                                  m_volRegime(NULL), m_opposingBos(NULL),
                                                  m_minStretchATR(1.0), m_srZoneATRTolerance(0.25),
                                                  m_wickRejectionRatio(0.55), m_liqRecencyBars(10),
                                                  m_trendConflictRecencyBars(10), m_trendConflictMinStrength(0.5) {}
   void                 Init(CCandleData* candles, CSupportResistance* sr, CValueAreaEngine* valueArea,
                              CLiquidity* liquidity, CVolatilityRegime* volRegime, CBOS* opposingBos)
     {
      m_candles = candles;
      m_sr = sr;
      m_valueArea = valueArea;
      m_liquidity = liquidity;
      m_volRegime = volRegime;
      m_opposingBos = opposingBos;
     }
   // Defaults are starting points from the spec's own reasoning, not
   // tuned constants — same discipline note as every other Configure()
   // in this codebase.
   void                 Configure(double minStretchATR = 1.0, double srZoneATRTolerance = 0.25,
                                   double wickRejectionRatio = 0.55, int liqRecencyBars = 10,
                                   int trendConflictRecencyBars = 10, double trendConflictMinStrength = 0.5)
     {
      m_minStretchATR = (minStretchATR > 0) ? minStretchATR : 1.0;
      m_srZoneATRTolerance = (srZoneATRTolerance >= 0) ? srZoneATRTolerance : 0.25;
      m_wickRejectionRatio = (wickRejectionRatio > 0 && wickRejectionRatio <= 1.0) ? wickRejectionRatio : 0.55;
      m_liqRecencyBars = MathMax(0, liqRecencyBars);
      m_trendConflictRecencyBars = MathMax(0, trendConflictRecencyBars);
      m_trendConflictMinStrength = (trendConflictMinStrength >= 0 && trendConflictMinStrength <= 1.0) ? trendConflictMinStrength : 0.5;
     }

   void                 Evaluate(bool forBuy, double &reversionScore, ENUM_REVERSION_CLASS &reversionClass);
  };
//+------------------------------------------------------------------+
// forBuy -> looking for a support zone AT/BELOW price (fading a downside
// stretch, expecting a bounce up). !forBuy -> resistance zone AT/ABOVE
// price. Price sitting inside a zone counts as "at" it (distance clamped
// to 0), same convention as the ATR-tolerance checks elsewhere in this
// codebase (e.g. OBScore's distance-to-zero-at-max decay).
bool CMeanReversionEngine::HasNearbySRZone(double price, double atr, bool forBuy)
  {
   if(m_sr == NULL) return false;
   int n = m_sr.Count();
   for(int i = 0; i < n; i++)
     {
      SRZone z = m_sr.GetZone(i);
      double dist = forBuy ? (price - z.top) : (z.bottom - price);
      if(dist < 0) dist = 0.0;
      if(dist <= atr * m_srZoneATRTolerance)
         return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
// Checked on shift 1 (the last fully CLOSED bar), not shift 0 — same
// "final, not still-forming" convention Scoring.mqh's RVOL check uses
// (see FIX #16 there): a wick on the still-printing bar can still grow
// or vanish, so it isn't yet evidence of anything.
bool CMeanReversionEngine::RejectionWickPresent(bool forBuy)
  {
   if(m_candles == NULL || m_candles.Total() < 2) return false;
   CandleData cd = m_candles.GetCandle(1);
   double range = cd.high - cd.low;
   if(range <= 0) return false;
   double lowerWick = MathMin(cd.open, cd.close) - cd.low;
   double upperWick = cd.high - MathMax(cd.open, cd.close);
   return forBuy ? ((lowerWick / range) >= m_wickRejectionRatio)
                 : ((upperWick / range) >= m_wickRejectionRatio);
  }
//+------------------------------------------------------------------+
// forBuy (fading a downside stretch) wants confirmation via a SELL-SIDE
// sweep (stops taken beneath the lows before the bounce); the bearish
// mirror wants a BUY-SIDE sweep.
bool CMeanReversionEngine::HasRecentOpposingSweep(bool forBuy)
  {
   if(m_liquidity == NULL) return false;
   ENUM_LIQ_TYPE target = forBuy ? LIQ_SELL_SIDE : LIQ_BUY_SIDE;
   int n = m_liquidity.EventCount();
   for(int i = 0; i < n; i++)
     {
      LiquidityEvent ev = m_liquidity.GetEvent(i);
      if(ev.bar_index > m_liqRecencyBars) break; // most-recent-first; nothing further back helps
      if(ev.type == target && ev.swept)
         return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
// A recent BOS in the direction the stretch is ALREADY moving (i.e.
// against the proposed fade) — is_bullish == !forBuy, since forBuy fades
// a bearish move and !forBuy fades a bullish one.
bool CMeanReversionEngine::HasTrendConflict(bool forBuy)
  {
   if(m_opposingBos == NULL) return false;
   int n = m_opposingBos.Count();
   for(int i = 0; i < n; i++)
     {
      BOSEvent ev = m_opposingBos.GetBOS(i);
      if(ev.bar_index > m_trendConflictRecencyBars) break; // most-recent-first
      if(ev.is_bullish == !forBuy && ev.strength >= m_trendConflictMinStrength)
         return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
void CMeanReversionEngine::Evaluate(bool forBuy, double &reversionScore, ENUM_REVERSION_CLASS &reversionClass)
  {
   reversionScore = 0.0;
   reversionClass = REVERSION_NONE;

   if(m_candles == NULL || m_candles.Total() < 2) return;
   double price = m_candles.GetCandle(0).close; // live/current-bar proxy, same convention MomentumBreakout.mqh uses
   double atr = m_candles.GetATR(0);
   if(atr <= 0) return;

   bool wickRejection = RejectionWickPresent(forBuy);
   bool srNear = HasNearbySRZone(price, atr, forBuy);

   // Neither qualifying bar is met at all — stay NONE rather than guess.
   if(!wickRejection && !srNear)
      return;

   bool volControlled = true; // fail OPEN here deliberately: an unavailable vol read shouldn't zero out an otherwise-scored setup, unlike the hard fail-closed on ATR<=0 above where the whole score is meaningless without it
   if(m_volRegime != NULL)
      volControlled = (m_volRegime.Classify(0) != VOL_REGIME_HIGH);

   double stretchATR = 0.0;
   bool vaStretched = false;
   if(m_valueArea != NULL && m_valueArea.IsValid())
     {
      stretchATR = forBuy ? (m_valueArea.VAL() - price) / atr : (price - m_valueArea.VAH()) / atr;
      vaStretched = (stretchATR >= m_minStretchATR);
     }

   bool sweepConfirmed = HasRecentOpposingSweep(forBuy);
   double score = 0.0;

   if(vaStretched)
     {
      score += MathMin(stretchATR / 3.0, 1.0) * 40.0; // stretch component, capped at 3 ATR beyond the VA edge
      if(wickRejection)   score += 25.0;
      if(sweepConfirmed)  score += 20.0;
      if(volControlled)   score += 15.0;
      reversionClass = REVERSION_VALUE_FADE;
     }
   else if(srNear)
     {
      if(wickRejection)   score += 35.0;
      if(sweepConfirmed)  score += 25.0;
      if(volControlled)   score += 15.0;
      reversionClass = REVERSION_LEVEL_REJECTION;
     }
   else
      return; // guarded above, kept here as an explicit fail-closed rather than falling through silently

   reversionScore = MathMax(0.0, MathMin(score, 100.0));

   if(HasTrendConflict(forBuy))
      reversionClass = REVERSION_TREND_CONFLICT; // score left as-is, see file header
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Strategies/MeanReversion.mqh ----


// ---- BEGIN EA/includes/Strategies/KeyLevelReaction.mqh ----
//+------------------------------------------------------------------+
//|                                 Strategies/KeyLevelReaction.mqh   |
//+------------------------------------------------------------------+
#ifndef KEYLEVELREACTION_MQH
#define KEYLEVELREACTION_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----


// ---- BEGIN EA/includes/Core/SessionFilter.mqh ----

// ---- END EA/includes/Core/SessionFilter.mqh ----


// ---- BEGIN EA/includes/SmartMoney/SupportResistance.mqh ----

// ---- END EA/includes/SmartMoney/SupportResistance.mqh ----


// ---- BEGIN EA/includes/SmartMoney/ValueAreaEngine.mqh ----

// ---- END EA/includes/SmartMoney/ValueAreaEngine.mqh ----


// ---- BEGIN EA/includes/SmartMoney/Liquidity.mqh ----

// ---- END EA/includes/SmartMoney/Liquidity.mqh ----


// ---- BEGIN EA/includes/SmartMoney/OrderBlock.mqh ----

// ---- END EA/includes/SmartMoney/OrderBlock.mqh ----


// ---- BEGIN EA/includes/SmartMoney/ExtendedKeyLevels.mqh ----
//+------------------------------------------------------------------+
//|                                SmartMoney/ExtendedKeyLevels.mqh   |
//+------------------------------------------------------------------+
#ifndef EXTENDEDKEYLEVELS_MQH
#define EXTENDEDKEYLEVELS_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----


// ---- BEGIN EA/includes/Core/SessionFilter.mqh ----

// ---- END EA/includes/Core/SessionFilter.mqh ----

// v2.17 addition. The three level sources v2.14's Strategies/
// KeyLevelReaction.mqh header explicitly flagged as unwired: "None of
// the three exist anywhere in the codebase yet — building three new
// level detectors in the same pass as everything above would be
// exactly the kind of unverified sprawl this codebase's own discipline
// argues against elsewhere." This is that new code, on its own pass.
//
// Grouped in one file/class rather than three, because all three are
// the same KIND of level — a raw price extreme or a round number — not
// a structure-derived zone the way SR/OrderBlock/ValueArea/Liquidity
// are. Each method is independent; nothing here depends on the others.
//
// DIAGNOSTIC ONLY, same as every level source before it — see
// Strategies/KeyLevelReaction.mqh for what actually reads these.
class CExtendedKeyLevels
  {
private:
   string            m_symbol;
   double            m_roundStep;   // psychological-level spacing. Default 10.0 == whole-$10 XAUUSD levels
                                     // (2640.00, 2650.00, ...) — this EA is single-symbol XAUUSD, not a
                                     // generic multi-pair round-pip scheme, so a price-unit step is the
                                     // honest choice here, not a pip count that wouldn't mean anything for gold.

   // Previous WEEK high/low — cached, recomputed only when the week
   // rolls over. iHigh/iLow(PERIOD_W1, 1) is cheap, but there's no
   // reason to call it every tick for a value that only changes once
   // every 5 trading days.
   double            m_prevWeekHigh;
   double            m_prevWeekLow;
   datetime          m_prevWeekCachedForMonday; // Monday 00:00 (broker time) of the week this cache belongs to
   bool              m_prevWeekValid;

   void              RefreshPrevWeekIfStale();

public:
                     CExtendedKeyLevels() : m_roundStep(10.0), m_prevWeekHigh(0.0), m_prevWeekLow(0.0),
                                             m_prevWeekCachedForMonday(0), m_prevWeekValid(false) {}
   void              Init(string symbol) { m_symbol = symbol; }
   // Defaults are starting points, not tuned constants — same
   // discipline note as every other Configure() in this codebase.
   void              Configure(double roundStep = 10.0) { m_roundStep = (roundStep > 0.0) ? roundStep : 10.0; }

   // Previous WEEK high/low — the most recently CLOSED weekly bar
   // (shift 1; shift 0 is the current, still-forming week). Checks BOTH
   // the high and the low as candidates and keeps whichever is nearer
   // and on the requested side — same "either one can flip role"
   // treatment FindNearestLevel() already gives SR zones (a broken
   // previous-week high can act as support just as readily as the low
   // can), not a hardcoded "low=support, high=resistance" assumption.
   bool              NearestPrevWeekLevel(bool forBuy, double price, double maxDist, double &levelPrice);
   // Current SESSION's high/low so far: scans `candles` (pass the same
   // chart-TF series every other source in KeyLevelReaction.mqh uses,
   // for the same self-consistency reason) for CLOSED bars at or after
   // the session's own start, per CSessionFilter::CurrentSessionStartGMT().
   // Returns false during SESSION_DEAD (no boundary to measure from) or
   // if no closed bar has printed since the session opened yet — a
   // session that just opened has no range to speak of, and reporting
   // one bar's high==low as a "level" would be noise, not signal.
   bool              NearestSessionLevel(bool forBuy, double price, double maxDist, double &levelPrice,
                                          CCandleData* candles, CSessionFilter* sessionFilter);
   // Nearest round-number level at m_roundStep spacing. Unlike the two
   // above, a round level's side relative to price is unambiguous by
   // construction (the one below price is the support candidate, the
   // one above is the resistance candidate) — no "check both, keep
   // nearer" needed.
   bool              NearestRoundLevel(bool forBuy, double price, double maxDist, double &levelPrice);
  };
//+------------------------------------------------------------------+
void CExtendedKeyLevels::RefreshPrevWeekIfStale()
  {
   datetime now = TimeCurrent();
   MqlDateTime t;
   TimeToStruct(now, t);
   int dow = t.day_of_week; // 0 = Sunday
   int daysSinceMonday = (dow == 0) ? 6 : (dow - 1);
   MqlDateTime mon = t;
   mon.hour = 0; mon.min = 0; mon.sec = 0;
   datetime mondayThisWeek = StructToTime(mon) - (long)daysSinceMonday * 86400;

   if(m_prevWeekValid && mondayThisWeek == m_prevWeekCachedForMonday)
      return; // still the same trading week as last time this was refreshed — cache holds

   double h = iHigh(m_symbol, PERIOD_W1, 1);
   double l = iLow(m_symbol, PERIOD_W1, 1);
   if(h <= 0.0 || l <= 0.0)
     {
      // Not enough weekly history yet (fresh account, or the broker
      // hasn't backfilled W1 history). Leave the cache invalid rather
      // than store a bogus 0.0 level that would silently pass every
      // downstream distance check.
      m_prevWeekValid = false;
      return;
     }
   m_prevWeekHigh = h;
   m_prevWeekLow = l;
   m_prevWeekCachedForMonday = mondayThisWeek;
   m_prevWeekValid = true;
  }
//+------------------------------------------------------------------+
bool CExtendedKeyLevels::NearestPrevWeekLevel(bool forBuy, double price, double maxDist, double &levelPrice)
  {
   levelPrice = 0.0;
   RefreshPrevWeekIfStale();
   if(!m_prevWeekValid) return false;

   double candidates[2];
   candidates[0] = m_prevWeekHigh;
   candidates[1] = m_prevWeekLow;

   bool found = false;
   double best = maxDist;
   for(int i = 0; i < 2; i++)
     {
      double lvl = candidates[i];
      double dist = forBuy ? (price - lvl) : (lvl - price); // forBuy -> level must sit at/below price to be a support candidate
      if(dist < 0) continue;
      if(dist <= best) { best = dist; levelPrice = lvl; found = true; }
     }
   return found;
  }
//+------------------------------------------------------------------+
bool CExtendedKeyLevels::NearestSessionLevel(bool forBuy, double price, double maxDist, double &levelPrice,
                                              CCandleData* candles, CSessionFilter* sessionFilter)
  {
   levelPrice = 0.0;
   if(candles == NULL || sessionFilter == NULL) return false;

   datetime sessionStart = sessionFilter.CurrentSessionStartGMT();
   if(sessionStart == 0) return false; // SESSION_DEAD

   double sessHigh = -1.0;
   double sessLow = -1.0;
   int total = candles.Total();
   // shift 1..total-1: closed bars only, matching the "not the
   // still-forming bar" convention every other source in this pipeline
   // uses. Candles are stored newest-first (ArraySetAsSeries), so the
   // first bar older than sessionStart means everything past it belongs
   // to a prior session — safe to stop scanning right there.
   for(int s = 1; s < total; s++)
     {
      CandleData cd = candles.GetCandle(s);
      if(cd.time < sessionStart) break;
      if(sessHigh < 0.0 || cd.high > sessHigh) sessHigh = cd.high;
      if(sessLow  < 0.0 || cd.low  < sessLow)  sessLow  = cd.low;
     }
   if(sessHigh < 0.0 || sessLow < 0.0) return false; // no closed bar since the session opened yet

   double candidates[2];
   candidates[0] = sessHigh;
   candidates[1] = sessLow;

   bool found = false;
   double best = maxDist;
   for(int i = 0; i < 2; i++)
     {
      double lvl = candidates[i];
      double dist = forBuy ? (price - lvl) : (lvl - price);
      if(dist < 0) continue;
      if(dist <= best) { best = dist; levelPrice = lvl; found = true; }
     }
   return found;
  }
//+------------------------------------------------------------------+
bool CExtendedKeyLevels::NearestRoundLevel(bool forBuy, double price, double maxDist, double &levelPrice)
  {
   levelPrice = 0.0;
   if(m_roundStep <= 0.0) return false;

   double below = MathFloor(price / m_roundStep) * m_roundStep;
   double above = below + m_roundStep;
   double lvl = forBuy ? below : above; // deterministic by construction — no "check both" needed like the two sources above

   double dist = forBuy ? (price - lvl) : (lvl - price);
   if(dist < 0.0 || dist > maxDist) return false;
   levelPrice = lvl;
   return true;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/SmartMoney/ExtendedKeyLevels.mqh ----

// v2.14 addition. Strategy module #3 of the multi-strategy architecture
// (see MomentumBreakout.mqh for module #1 and MeanReversion.mqh for
// module #2, and the shared "one module at a time" rationale). This is
// the doc's "Key-Level Reaction Engine": identify a level, then
// classify what price actually did there as structured data, instead
// of a discretionary "bearish engulfing candle" read.
//
// LEVEL SOURCES (ENUM_KEYLEVEL_SOURCE) — reused, not reinvented:
//   LEVEL_SR             : CSupportResistance zones (swing-based, chart TF)
//   LEVEL_ORDER_BLOCK     : COrderBlock zones (chart-TF instance — see
//                          the timeframe note below for why NOT the
//                          separate genuinely-HTF instance OBScore()
//                          uses)
//   LEVEL_VALUE_AREA      : CValueAreaEngine's POC/VAH/VAL
//   LEVEL_LIQUIDITY_POOL  : CLiquidity events flagged `external` — per
//                          that struct's own comment, "external = true
//                          = D1 high/low sweep", which IS the doc's
//                          "previous day high/low" entry, reused
//                          directly rather than recomputed.
//   LEVEL_PREV_WEEK       : CExtendedKeyLevels — previous week's high/low
//                          (v2.17, see that file's header)
//   LEVEL_SESSION         : CExtendedKeyLevels — current session's
//                          high/low so far (v2.17)
//   LEVEL_PSYCHOLOGICAL   : CExtendedKeyLevels — nearest round-number
//                          level (v2.17)
// v2.17: the three sources below are now wired in — see
// SmartMoney/ExtendedKeyLevels.mqh's header for why they were held back
// from the original v2.14 pass and built as their own pass instead.
//
// Of every candidate level across the four sources above, the NEAREST
// one to current price (within m_levelSearchATRMax) is picked — no
// source-type priority weighting. "Nearest, no favorites" is a
// deliberate, simple rule, not a gap.
//
// REACTION CLASSIFICATION (ENUM_KEYLEVEL_REACTION) — examines the last
// m_lookbackBars CLOSED bars (shift 1..N) relative to the chosen
// level's price, using "hold side" (the side price approached the
// level from, matching the setup's forBuy direction) and "far side"
// (the other side) rather than absolute up/down, so one classifier
// works for a support-side read and a resistance-side read alike:
//   ACCEPTANCE   : two or more of the most recent closes are on the far
//                  side — the level has flipped role, not just been
//                  poked at.
//   BREAK        : only the single most recent close is on the far
//                  side — fresh, unconfirmed by a second close.
//   RETEST       : price broke to the far side within the lookback
//                  window, has since come back, and is now sitting at
//                  the level again without having closed back past it.
//   FAILED_BREAK : price broke to the far side within the lookback
//                  window, then closed back on the hold side — the
//                  break didn't hold.
//   REJECTION    : price touched the level (candle range include it)
//                  but closed on the hold side with a rejection wick
//                  through the level.
//   ABSORPTION   : the level was touched at least m_absorptionMinTouches
//                  times in the window with no break and no strong
//                  rejection wick — repeated testing without resolving
//                  either way.
//   NONE         : no level within range, or a level was found but none
//                  of the above patterns fit.
//
// HONEST LIMIT ON THE SCORE: unlike MomentumBreakout's/MeanReversion's
// continuously computed 0-100 scores, `reaction_score` here is a FIXED
// per-classification conviction weight, not a composite calculated from
// multiple factors. The underlying signal this module produces is
// fundamentally categorical ("what happened"), and forcing a fake
// continuous score onto it to look consistent with the other two
// modules would misrepresent what's actually being measured.
//
// TIMEFRAME NOTE: candles/SR/value-area/order-block here are all the
// CHART-TF context (m_srCtx) — self-consistent. Liquidity reuses
// whichever timeframe InpLiquidityTF is configured to, same
// cross-timeframe caveat MomentumBreakout.mqh and MeanReversion.mqh
// already carry.
//
// DIAGNOSTIC ONLY, same as every v2.1x addition before it.
class CKeyLevelEngine
  {
private:
   CCandleData*         m_candles;
   CSupportResistance*  m_sr;
   CValueAreaEngine*    m_valueArea;
   CLiquidity*          m_liquidity;
   COrderBlock*         m_orderBlock;
   CExtendedKeyLevels*  m_extLevels;    // v2.17 — prev week / session / psychological
   CSessionFilter*      m_sessionFilter; // v2.17 — needed by m_extLevels.NearestSessionLevel() only

   int                  m_lookbackBars;           // closed bars examined for the reaction pattern (default 5)
   double               m_levelSearchATRMax;       // max distance, in ATR, for a level to count as "in range" (default 3.0)
   double               m_touchToleranceATRMult;   // how close a candle's range must come to the level, in ATR, to count as a touch (default 0.15)
   int                  m_absorptionMinTouches;    // touches required, with no break/rejection, to call it ABSORPTION (default 3)
   double               m_wickRejectionRatio;      // wick/range ratio required to call a candle a rejection (default 0.55, same default as MeanReversion.mqh)

   bool                 FindNearestLevel(bool forBuy, double atr, double price, double &levelPrice, ENUM_KEYLEVEL_SOURCE &source);
   bool                 CrossedFarSide(int shift, double levelPrice, double tol, bool forBuy);
   bool                 TouchedLevel(int shift, double levelPrice, double tol);
   bool                 RejectionWickAt(int shift, double levelPrice, bool forBuy);

public:
                        CKeyLevelEngine() : m_candles(NULL), m_sr(NULL), m_valueArea(NULL), m_liquidity(NULL), m_orderBlock(NULL),
                                             m_extLevels(NULL), m_sessionFilter(NULL),
                                             m_lookbackBars(5), m_levelSearchATRMax(3.0),
                                             m_touchToleranceATRMult(0.15), m_absorptionMinTouches(3),
                                             m_wickRejectionRatio(0.55) {}
   void                 Init(CCandleData* candles, CSupportResistance* sr, CValueAreaEngine* valueArea,
                              CLiquidity* liquidity, COrderBlock* orderBlock,
                              CExtendedKeyLevels* extLevels = NULL, CSessionFilter* sessionFilter = NULL)
     {
      m_candles = candles;
      m_sr = sr;
      m_valueArea = valueArea;
      m_liquidity = liquidity;
      m_orderBlock = orderBlock;
      // v2.17: both optional (default NULL) so existing call sites that
      // haven't been updated yet keep compiling and behave exactly as
      // before — FindNearestLevel() below skips these three sources
      // entirely when m_extLevels is NULL, same NULL-guard pattern
      // every other source here already follows.
      m_extLevels = extLevels;
      m_sessionFilter = sessionFilter;
     }
   // Defaults are starting points, not tuned constants — same
   // discipline note as every other Configure() in this codebase.
   void                 Configure(int lookbackBars = 5, double levelSearchATRMax = 3.0,
                                   double touchToleranceATRMult = 0.15, int absorptionMinTouches = 3,
                                   double wickRejectionRatio = 0.55)
     {
      m_lookbackBars = MathMax(2, lookbackBars);
      m_levelSearchATRMax = (levelSearchATRMax > 0) ? levelSearchATRMax : 3.0;
      m_touchToleranceATRMult = (touchToleranceATRMult >= 0) ? touchToleranceATRMult : 0.15;
      m_absorptionMinTouches = MathMax(2, absorptionMinTouches);
      m_wickRejectionRatio = (wickRejectionRatio > 0 && wickRejectionRatio <= 1.0) ? wickRejectionRatio : 0.55;
     }

   void                 Evaluate(bool forBuy, ENUM_KEYLEVEL_SOURCE &source, ENUM_KEYLEVEL_REACTION &reaction, double &reactionScore);
  };
//+------------------------------------------------------------------+
// forBuy -> nearest level ACTING AS SUPPORT (at/below price). !forBuy ->
// nearest level ACTING AS RESISTANCE (at/above price). "Nearest, no
// source-type favorites" — see file header.
bool CKeyLevelEngine::FindNearestLevel(bool forBuy, double atr, double price, double &levelPrice, ENUM_KEYLEVEL_SOURCE &source)
  {
   double bestDist = m_levelSearchATRMax * atr;
   bool found = false;
   levelPrice = 0.0;
   source = LEVEL_NONE;

   if(m_sr != NULL)
     {
      int n = m_sr.Count();
      for(int i = 0; i < n; i++)
        {
         SRZone z = m_sr.GetZone(i);
         double lvl = forBuy ? z.top : z.bottom;
         double dist = forBuy ? (price - lvl) : (lvl - price);
         if(dist < 0) dist = 0.0;
         if(dist <= bestDist) { bestDist = dist; levelPrice = lvl; source = LEVEL_SR; found = true; }
        }
     }
   if(m_orderBlock != NULL)
     {
      int n = m_orderBlock.Count();
      for(int i = 0; i < n; i++)
        {
         OrderBlockZone z = m_orderBlock.GetZone(i);
         // Demand (FVG_BULL) acts as support -> use its top as the
         // support line facing price from below. Supply (FVG_BEAR)
         // acts as resistance -> use its bottom.
         if(forBuy && z.dir != FVG_BULL) continue;
         if(!forBuy && z.dir != FVG_BEAR) continue;
         double lvl = forBuy ? z.top : z.bottom;
         double dist = forBuy ? (price - lvl) : (lvl - price);
         if(dist < 0) dist = 0.0;
         if(dist <= bestDist) { bestDist = dist; levelPrice = lvl; source = LEVEL_ORDER_BLOCK; found = true; }
        }
     }
   if(m_valueArea != NULL && m_valueArea.IsValid())
     {
      double lvl = forBuy ? m_valueArea.VAL() : m_valueArea.VAH();
      double dist = forBuy ? (price - lvl) : (lvl - price);
      if(dist < 0) dist = 0.0;
      if(dist <= bestDist) { bestDist = dist; levelPrice = lvl; source = LEVEL_VALUE_AREA; found = true; }
     }
   if(m_liquidity != NULL)
     {
      ENUM_LIQ_TYPE target = forBuy ? LIQ_SELL_SIDE : LIQ_BUY_SIDE; // sell-side pool = stops below lows = support-adjacent; mirror for resistance
      int n = m_liquidity.EventCount();
      for(int i = 0; i < n; i++)
        {
         LiquidityEvent ev = m_liquidity.GetEvent(i);
         if(!ev.external) continue; // doc's "previous day high/low" maps to external D1 sweeps specifically, not internal equal-highs/lows
         if(ev.type != target) continue;
         double dist = forBuy ? (price - ev.price) : (ev.price - price);
         if(dist < 0) dist = 0.0;
         if(dist <= bestDist) { bestDist = dist; levelPrice = ev.price; source = LEVEL_LIQUIDITY_POOL; found = true; }
        }
     }
   // v2.17 — the three sources v2.14 left unwired. Each returns its own
   // nearest-on-the-requested-side candidate already (see
   // ExtendedKeyLevels.mqh), so this just folds those three single
   // candidates into the same "nearest wins, no source-type favorites"
   // comparison every source above already participates in.
   if(m_extLevels != NULL)
     {
      double lvl;
      if(m_extLevels.NearestPrevWeekLevel(forBuy, price, bestDist, lvl))
        {
         double dist = forBuy ? (price - lvl) : (lvl - price);
         if(dist <= bestDist) { bestDist = dist; levelPrice = lvl; source = LEVEL_PREV_WEEK; found = true; }
        }
      if(m_candles != NULL && m_sessionFilter != NULL &&
         m_extLevels.NearestSessionLevel(forBuy, price, bestDist, lvl, m_candles, m_sessionFilter))
        {
         double dist = forBuy ? (price - lvl) : (lvl - price);
         if(dist <= bestDist) { bestDist = dist; levelPrice = lvl; source = LEVEL_SESSION; found = true; }
        }
      if(m_extLevels.NearestRoundLevel(forBuy, price, bestDist, lvl))
        {
         double dist = forBuy ? (price - lvl) : (lvl - price);
         if(dist <= bestDist) { bestDist = dist; levelPrice = lvl; source = LEVEL_PSYCHOLOGICAL; found = true; }
        }
     }
   return found;
  }
//+------------------------------------------------------------------+
bool CKeyLevelEngine::CrossedFarSide(int shift, double levelPrice, double tol, bool forBuy)
  {
   CandleData cd = m_candles.GetCandle(shift);
   return forBuy ? (cd.close < levelPrice - tol) : (cd.close > levelPrice + tol);
  }
//+------------------------------------------------------------------+
bool CKeyLevelEngine::TouchedLevel(int shift, double levelPrice, double tol)
  {
   CandleData cd = m_candles.GetCandle(shift);
   return (cd.low <= levelPrice + tol && cd.high >= levelPrice - tol);
  }
//+------------------------------------------------------------------+
// Same shift-1-only "final, not still-forming" convention MeanReversion.mqh
// uses for its own wick check, applied per-shift here since this scans a window.
bool CKeyLevelEngine::RejectionWickAt(int shift, double levelPrice, bool forBuy)
  {
   CandleData cd = m_candles.GetCandle(shift);
   double range = cd.high - cd.low;
   if(range <= 0) return false;
   double lowerWick = MathMin(cd.open, cd.close) - cd.low;
   double upperWick = cd.high - MathMax(cd.open, cd.close);
   // forBuy (support, hold side = above): rejection = long lower wick
   // poking through the level while the close stays above it.
   return forBuy ? ((lowerWick / range) >= m_wickRejectionRatio && cd.low <= levelPrice)
                 : ((upperWick / range) >= m_wickRejectionRatio && cd.high >= levelPrice);
  }
//+------------------------------------------------------------------+
void CKeyLevelEngine::Evaluate(bool forBuy, ENUM_KEYLEVEL_SOURCE &source, ENUM_KEYLEVEL_REACTION &reaction, double &reactionScore)
  {
   source = LEVEL_NONE;
   reaction = REACTION_NONE;
   reactionScore = 0.0;

   if(m_candles == NULL || m_candles.Total() < m_lookbackBars + 1) return;
   double atr = m_candles.GetATR(0);
   if(atr <= 0) return;
   double price = m_candles.GetCandle(0).close; // live/current-bar proxy, same convention as the other two strategy modules

   double levelPrice;
   if(!FindNearestLevel(forBuy, atr, price, levelPrice, source))
     {
      source = LEVEL_NONE;
      return; // no level in range at all — stays NONE/NONE/0
     }

   double tol = atr * m_touchToleranceATRMult;

   bool crossed1 = CrossedFarSide(1, levelPrice, tol, forBuy);
   bool crossed2 = CrossedFarSide(2, levelPrice, tol, forBuy);

   if(crossed1 && crossed2)
     {
      reaction = REACTION_ACCEPTANCE;
      reactionScore = 90.0;
      return;
     }
   if(crossed1)
     {
      reaction = REACTION_BREAK;
      reactionScore = 75.0;
      return;
     }

   // Not currently on the far side (crossed1 is false past this point).
   // Was it on the far side at any point earlier in the window?
   bool wasCrossedEarlier = false;
   for(int s = 2; s <= m_lookbackBars; s++)
      if(CrossedFarSide(s, levelPrice, tol, forBuy)) { wasCrossedEarlier = true; break; }

   if(wasCrossedEarlier)
     {
      if(TouchedLevel(1, levelPrice, tol))
        {
         reaction = REACTION_RETEST;
         reactionScore = 70.0;
        }
      else
        {
         reaction = REACTION_FAILED_BREAK;
         reactionScore = 60.0;
        }
      return;
     }

   if(RejectionWickAt(1, levelPrice, forBuy))
     {
      reaction = REACTION_REJECTION;
      reactionScore = 65.0;
      return;
     }

   int touchCount = 0;
   for(int s = 1; s <= m_lookbackBars; s++)
      if(TouchedLevel(s, levelPrice, tol)) touchCount++;

   if(touchCount >= m_absorptionMinTouches)
     {
      reaction = REACTION_ABSORPTION;
      reactionScore = 40.0;
      return;
     }
   // A level was found and possibly touched once, but no pattern above
   // fit cleanly — stays NONE rather than force a weak guess into one
   // of the six named buckets.
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Strategies/KeyLevelReaction.mqh ----


// ---- BEGIN EA/includes/Strategies/StrategySelector.mqh ----
//+------------------------------------------------------------------+
//|                                  Strategies/StrategySelector.mqh  |
//+------------------------------------------------------------------+
#ifndef STRATEGYSELECTOR_MQH
#define STRATEGYSELECTOR_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----

// v2.15 addition. This is the FOURTH and LAST layer added in this
// batch — per explicit agreement to stop here and compile/test v2.12
// through v2.15 as one unit before adding anything further. Nothing
// past this point (Price Action was the last strategy module; this is
// the selection layer on top of it) is built until that happens.
//
// This is the doc's "four different questions, keep them separate"
// layer #2 (strategy-specific score, THIS ONE: strategy selection,
// trade confidence, portfolio decision). It answers exactly one
// question — "which strategy's read is strongest given the regime" —
// and answers nothing else. It does not gate a trade, does not touch
// setup.confidence, and does not run its own detection: every input it
// reads was already computed by CRegimeDetector, CMomentumBreakoutEngine,
// CMeanReversionEngine, and CKeyLevelEngine before this runs.
//
// THE WARNING THIS CLASS EXISTS TO IMPLEMENT: the spec's strongest
// warning is explicit — do not sum every strategy's score into one
// number and call the total a confidence ("SMC=+20, Momentum=+15... =
// 115, BUY" — an arbitrary confidence soup). This class never sums
// anything. It compares candidate scores and picks the single highest
// one; the loser candidates' own scores are already logged separately
// (momentum_score, reversion_score, keylevel_score all remain on
// SetupReasons untouched) so nothing is lost, but nothing is blended
// either.
//
// SELECTION RULE (deliberately simple — a genuine first cut, not the
// doc's full cross-regime free-for-all where every strategy competes
// regardless of regime): the live SMC engine's own confidence is
// always the baseline candidate, since it's the only strategy actually
// trading today. Regime determines which ONE challenger gets compared
// against it:
//   REGIME_TRENDING    -> best of (momentum_score, breakout_score)
//   REGIME_RANGING     -> reversion_score, UNLESS reversion_class ==
//                         REVERSION_TREND_CONFLICT, in which case no
//                         challenger is considered at all — this is
//                         the doc's explicit "should not fight a strong
//                         trend" rule enforced here, not just noted
//   REGIME_TRANSITION  -> keylevel_score, UNLESS keylevel_reaction ==
//                         REACTION_NONE (nothing to challenge with)
//   REGIME_UNDEFINED   -> no challenger considered; fail closed the
//                         same way every regime-dependent read in this
//                         codebase does on an unreliable regime
// The challenger only wins if it clears m_minSelectionScore AND beats
// the SMC confidence outright. If no challenger applies or none wins,
// selected_strategy = STRATEGY_SMC (or STRATEGY_NONE if SMC confidence
// itself is 0 / regime is undefined and nothing was even a candidate).
//
// DIAGNOSTIC ONLY. See the file-level note above and every prior
// v2.1x module for the same disclosure.
class CStrategySelector
  {
private:
   double            m_minSelectionScore; // a challenger must clear this AND beat SMC confidence to win (default 60.0)

public:
                     CStrategySelector() : m_minSelectionScore(60.0) {}
   // Starting point from the spec's own reasoning, not a tuned constant
   // — same discipline note as every other Configure() in this codebase.
   void              Configure(double minSelectionScore = 60.0)
     {
      m_minSelectionScore = (minSelectionScore >= 0 && minSelectionScore <= 100.0) ? minSelectionScore : 60.0;
     }

   void              Select(const SetupReasons &r, double smcConfidence,
                             ENUM_SELECTED_STRATEGY &selected, double &selectedScore);
  };
//+------------------------------------------------------------------+
void CStrategySelector::Select(const SetupReasons &r, double smcConfidence,
                               ENUM_SELECTED_STRATEGY &selected, double &selectedScore)
  {
   selected = STRATEGY_SMC;
   selectedScore = smcConfidence;

   if(r.regime == REGIME_UNDEFINED)
     {
      if(smcConfidence <= 0) selected = STRATEGY_NONE;
      return; // no challenger considered on an unreliable regime read
     }

   double challengerScore = -1.0;
   ENUM_SELECTED_STRATEGY challenger = STRATEGY_NONE;

   if(r.regime == REGIME_TRENDING)
     {
      challengerScore = MathMax(r.momentum_score, r.breakout_score);
      challenger = STRATEGY_MOMENTUM_BREAKOUT;
     }
   else if(r.regime == REGIME_RANGING)
     {
      if(r.reversion_class != REVERSION_TREND_CONFLICT)
        {
         challengerScore = r.reversion_score;
         challenger = STRATEGY_MEAN_REVERSION;
        }
     }
   else if(r.regime == REGIME_TRANSITION)
     {
      if(r.keylevel_reaction != REACTION_NONE)
        {
         challengerScore = r.keylevel_score;
         challenger = STRATEGY_KEY_LEVEL;
        }
     }

   if(challenger != STRATEGY_NONE && challengerScore >= m_minSelectionScore && challengerScore > smcConfidence)
     {
      selected = challenger;
      selectedScore = challengerScore;
     }

   if(selected == STRATEGY_SMC && smcConfidence <= 0)
      selected = STRATEGY_NONE; // nothing actually cleared as a real candidate
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Strategies/StrategySelector.mqh ----

// v2.1 SCORING MODEL — replaces the old flat weighted sum with the
// point table from the inducement-engine spec:
//   Strong Impulse             +15  \
//   Internal Structure Formed  +10   |  from CInducement.Validate() —
//   Internal Liquidity Sweep   +25   |  see SmartMoney/Inducement.mqh
//   BOS after Sweep            +20  /
//   Fresh FVG                  +15
//   HTF Alignment               +15
//   -------------------------------
//   Total                      100
//
// GATING, not just scoring: if the liquidity sweep (and its confirming
// minor BOS) never happens, confidence is 0 and CTradeDecision's existing
// "confidence < threshold" check blocks the setup outright — per your
// instruction, this removes false entries rather than just down-weighting
// them. Two further gates are available and OFF/ON as noted:
//   - Premium/Discount filter: ON by default. Buys must be in the lower
//     half (discount) of the impulse range, sells in the upper half.
//   - Market Phase (Distribution-only) filter: OFF by default, because
//     the phase read is the least rigorously defined of the additions
//     (see MarketPhase.mqh's caveat) — enable via RequireDistribution
//     if you want to test it.
//
// The legacy Trend/BOS/Liquidity/FVG/SR sub-scores are KEPT and still
// computed (TrendScore, FVGScore feed the point table above; BOSChoCHScore,
// LiquidityScore, SRScore now feed EvaluateReasons() only, as informational
// "why" flags on the dashboard) — they are deliberately NOT re-added into
// CalculateConfidence's sum, since the Inducement engine's sweepScore/
// bosScore already covers that evidence on the entry timeframe and adding
// both would double-count the same signal under two names.
//
// v2.8 additions (see ConfigureHtfOrderBlock/ConfigureVolatilityRegime/
// ConfigureSessionFilter below): HTF Order Block confluence and the
// low-volatility-regime block follow the same OFF-by-default,
// unvalidated-until-backtested discipline as the v2.6 gates. The session
// filter is the one exception — it defaults ON, because "trade every
// session with equal weight" was never a validated assumption in the
// first place; it was just what happens when nothing gates on session at
// all. See Core/SessionFilter.mqh.
class CScoringEngine
  {
private:
   CTFContext*       m_trendCtx;
   CTFContext*       m_bosCtx;
   CTFContext*       m_liqCtx;
   CTFContext*       m_fvgCtx;
   CTFContext*       m_srCtx;
   CCandleData*      m_priceRef;   // chart-TF candles, used only for "current price"

   CInducement       m_inducement;
   bool              m_requirePremiumDiscount;
   bool              m_requireDistribution;
   CMarketPhase      m_phase;

   // v2.6: Volume + Fibonacci — see ConfigureVolumeFibonacci() below for
   // why both default OFF.
   bool              m_requireVolumeConfirmation;
   double            m_rvolThreshold;
   bool              m_requireFibonacciZone;
   double            m_fibZoneMinPct;
   double            m_fibZoneMaxPct;
   bool              m_requireValueAreaLocation;

   // --- v2.8 additions -------------------------------------------------
   CTFContext*       m_htfObCtx;             // separate, genuinely-higher timeframe context (e.g. H4/D1)
   bool              m_requireHtfOB;         // OFF by default — see class-level discipline note
   double            m_obDistATRMax;         // how far price may sit from an OB's midpoint and still count
   CVolatilityRegime m_volRegime;
   bool              m_blockLowVolRegime;    // OFF by default
   CSessionFilter    m_sessionFilter;        // ON by default (see Init()) — direct fix for
                                              // "trading time is across all sessions"

   // --- v2.9 additions ---------------------------------------------
   double            m_fvgMaxDistATR;        // was hardcoded 3.0; now 1.25 by default — see ConfigureFVGProximity()
   bool              m_requireChaseFilter;   // OFF by default — see ConfigureChaseFilter()
   double            m_maxChaseDistATR;

   // v2.9 — news-aware soft scoring. Distinct from the EA-level hard
   // IsLocked() block (which fully prevents entries in the narrow window
   // regardless of this). NULL pointer = feature inactive, same
   // fail-open-if-unconfigured convention as m_htfObCtx etc.
   CNewsFilter*      m_newsFilter;
   double            m_newsWarningMultiplier; // confidence *= this when in the WARNING tier

   // --- v2.10 diagnostic weights (see ConfigureLearnedDiagnostics()) ---
   // Used ONLY by the diagnostic block below; never enter
   // CalculateConfidence()'s arithmetic.
   double            m_contradictionWeight;  // scales the contradiction count into a 0-1 penalty
   double            m_envWeight;            // 0-1 blend: how much of env_score counts vs. assumed-neutral
   double            m_execWeight;           // 0-1 blend: same for exec_score

   // --- v2.12 strategy diagnostics (Regime/RegimeDetector.mqh,
   // Strategies/MomentumBreakout.mqh) — owned here rather than as
   // separate objects wired at the .mq5 level, because everything they
   // need (m_trendCtx.trend, m_bosCtx.bos, m_liqCtx.liquidity, m_phase,
   // m_volRegime) already exists on this class. Populated by
   // PopulateStrategyDiagnostics() only; never consulted by
   // CalculateConfidence() or anything that gates a trade.
   CRegimeDetector          m_regimeDetector;
   CMomentumBreakoutEngine  m_momentumEngine;
   // v2.13: Mean Reversion needs its own volatility-regime read scoped
   // to the CHART timeframe (m_srCtx), not the BOS-timeframe instance
   // (m_volRegime) Momentum/Regime already use above — VA/SR live on
   // the chart TF, so "controlled volatility" has to describe the same
   // market they're measuring, not a possibly-different BOS timeframe.
   CVolatilityRegime        m_volRegimeSR;
   CMeanReversionEngine     m_meanReversionEngine;
   // v2.14: no new detectors needed — reuses m_srCtx's own sr/valueArea/
   // orderBlock plus m_liqCtx.liquidity, same reuse pattern as the two
   // engines above. v2.17: now also wired to m_extendedKeyLevels below
   // and m_sessionFilter (already a member, above) for the three
   // previously-unwired sources.
   CKeyLevelEngine          m_keyLevelEngine;
   CExtendedKeyLevels       m_extendedKeyLevels; // v2.17 — prev week / session / psychological levels
   // v2.15: no Init() needed — see Strategies/StrategySelector.mqh, this
   // class only reads values the three engines above already computed.
   CStrategySelector        m_strategySelector;

   double            OBScore(bool forBuy);

   double            TrendScore(bool forBuy);
   double            BOSChoCHScore(bool forBuy);
   double            LiquidityScore(bool forBuy);
   double            FVGScore(bool forBuy);
   double            SRScore(bool forBuy);
   double            VolumeScore(bool forBuy);
   double            FibonacciScore(bool forBuy);
   double            ValueAreaScore(bool forBuy);
   double            PipSize();
   double            CurrentPrice();
   // v2.10 diagnostics - read the already-computed reasons instead of
   // re-deriving anything, so a diagnostic can never disagree with the
   // CSV row it is logged next to.
   double            ContradictionPenalty(const SetupReasons &r);
   double            EnvironmentScore(const SetupReasons &r);
   double            ExecutionScore(const SetupReasons &r);

public:
                     CScoringEngine();
   void              Init(CTFContext* trendCtx, CTFContext* bosCtx, CTFContext* liqCtx,
                          CTFContext* fvgCtx, CTFContext* srCtx, CCandleData* priceRef);
   void              ConfigureInducement(int lookbackBars, double impulseATRMult, double impulseBodyRatio,
                                         double equalTolATR, int maxLegExtend,
                                         bool requirePremiumDiscount, bool requireDistribution,
                                         int phaseRangeLookback, double phaseCompressionATRMult);
   // v2.6 addition. Volume and Fibonacci are FILTERS on top of the existing
   // Inducement-based confidence model, not additional signal generators:
   // when a gate is enabled and fails, CalculateConfidence returns 0 (same
   // as the premium/discount and phase gates above), exactly like the
   // spec's "trade is valid only if every mandatory filter passes." When a
   // gate passes (or is disabled), a small capped bonus (5 pts each) is
   // added for ranking, so a stronger volume/fib read can break a tie
   // between two otherwise-equal setups without being able to manufacture
   // a passing score on its own.
   //
   // Both gates default OFF. The spec's own "Backtesting Requirements"
   // section says a module should only be combined in after it's shown,
   // independently and out-of-sample, to improve results — and this
   // codebase currently has no MQL5 compile/backtest environment (Android/
   // Termux can't run MetaEditor's Strategy Tester; see project notes).
   // Shipping these gates pre-enabled would be exactly the un-validated
   // assumption that discipline exists to prevent. Flip both to true once
   // you've run the comparison on a Windows VPS/terminal.
   void              ConfigureVolumeFibonacci(bool requireVolumeConfirmation, double rvolThreshold,
                                              bool requireFibonacciZone, double fibZoneMinPct, double fibZoneMaxPct);
   // v2.6 addition. Same gating discipline as ConfigureVolumeFibonacci():
   // requires m_srCtx (the chart-TF context, same one SRScore() uses) to
   // have a valid volume profile. Defaults OFF — this engine is brand new
   // and hasn't been backtested at all yet, so it gets the same
   // "unvalidated until proven" treatment.
   void              ConfigureValueArea(bool requireValueAreaLocation);
   // v2.8 addition. htfObCtx MUST be a genuinely higher timeframe than
   // fvgCtx/bosCtx (e.g. entry on M15/H1, this on H4/D1) — passing the
   // same context defeats the point of "higher timeframe" confluence.
   // Defaults OFF for the same "unvalidated until proven" reason as
   // ConfigureVolumeFibonacci(): it's a brand-new engine, never backtested.
   void              ConfigureHtfOrderBlock(CTFContext* htfObCtx, bool requireHtfOB, double distATRMax = 2.0);
   // v2.8 addition. Blocks entries when the ATR-percentile regime reads
   // LOW (thin, choppy — see VolatilityRegime.mqh). Defaults OFF, same
   // discipline as above; the regime read itself is always populated in
   // EvaluateReasons() for diagnostics regardless of this flag.
   void              ConfigureVolatilityRegime(bool blockLowVolRegime, int lookback = 100,
                                                double lowPct = 0.25, double highPct = 0.75);
   // v2.8 addition. ON by default — this is the direct fix for "EA trades
   // every session uniformly": by default allows London, New York, and
   // the London/NY overlap; blocks Tokyo-only and dead hours. Pass
   // enabled=false to restore pre-v2.8 all-sessions behavior.
   void              ConfigureSessionFilter(bool enabled, bool allowTokyo = false, bool allowLondon = true,
                                            bool allowNewYork = true, bool allowOverlap = true);
   // v2.9 addition. FVGScore() now ranks every qualifying FVG and keeps
   // the best-scoring one instead of returning the first match found —
   // "first" had no relationship to "best" (freshness/proximity), so two
   // setups with identical top-line confidence could be resting on very
   // different FVG quality. Default distance cap tightened from the old
   // hardcoded 3.0 ATR to 1.25 ATR (item #8 in the review — a zone 2.8
   // ATR away isn't an immediate entry zone); this is a default-value
   // change, not a new OFF-by-default gate, since it only tightens an
   // existing filter rather than adding a new one. Still needs the same
   // ablation-test validation as everything else before being trusted.
   void              ConfigureFVGProximity(double maxDistATR = 1.25);
   // v2.9 addition (review item #4/#10 — "chase filter"). Rejects a
   // setup when price has already run too far past the BOS confirmation
   // close before the EA gets to evaluate it. Distinct from the existing
   // entry-deviation guard in OrderManager (which protects execution
   // AFTER a decision is made) — this catches a setup that was
   // strategically late before any order is even built. OFF by default,
   // same discipline as every other v2.8/v2.9 gate.
   void              ConfigureChaseFilter(bool requireChaseFilter, double maxChaseDistATR = 0.75);
   // v2.9 addition — passthrough to CInducement::ConfigureQualityGates().
   // See that method's comment for the OFF-by-default rationale.
   void              ConfigureSweepQuality(bool requireMinSweepGrade, ENUM_SWEEP_GRADE minSweepGrade,
                                           bool requireFreshSetup, int maxBarsSinceBOS = 5);
   // v2.9. warnMinutesBefore/After must be >= the EA's hard-block window
   // (InpNewsMinutesBefore/After) or they're clamped up to it inside
   // CNewsFilter::ConfigureWarningWindow() — WARNING is defined as a
   // superset of BLOCKED. newsWarningMultiplier default 0.85 is a
   // starting point, not a tuned constant.
   void              ConfigureNewsAwareness(CNewsFilter* newsFilter, int warnMinutesBefore = 60,
                                            int warnMinutesAfter = 30, double newsWarningMultiplier = 0.85);
   // v2.10 addition. Weights for the DIAGNOSTIC-ONLY contradiction /
   // environment / execution model. Defaults are the neutral starting
   // point from the upgrade spec, NOT tuned constants - replace them with
   // whatever tools/medistouch_retrain.py fits on your own resolved
   // outcomes. Changing these cannot change any trading decision; see the
   // SetupReasons v2.10 block in Core/Config.mqh.
   void              ConfigureLearnedDiagnostics(double contradictionWeight = 0.25,
                                                 double envWeight = 1.0,
                                                 double execWeight = 1.0);
   // v2.12 addition. Passthrough to CMomentumBreakoutEngine::Configure();
   // see that class for what each parameter means and why the defaults
   // are starting points, not tuned constants. The regime detector takes
   // no separate configuration — it has no tunable thresholds of its own
   // beyond what CVolatilityRegime/CMarketPhase already expose via their
   // own Configure calls above.
   void              ConfigureStrategyDiagnostics(int momentumBreakoutRecencyBars = 10,
                                                  int liqOverlapBars = 2,
                                                  int extensionLookbackBars = 15,
                                                  double exhaustionATRMult = 3.0,
                                                  int momentumLookbackBars = 10);
   // v2.13 addition. Passthrough to CMeanReversionEngine::Configure();
   // see that class for what each parameter means.
   void              ConfigureMeanReversionDiagnostics(double minStretchATR = 1.0,
                                                        double srZoneATRTolerance = 0.25,
                                                        double wickRejectionRatio = 0.55,
                                                        int liqRecencyBars = 10,
                                                        int trendConflictRecencyBars = 10,
                                                        double trendConflictMinStrength = 0.5);
   // v2.14 addition. Passthrough to CKeyLevelEngine::Configure(); see
   // that class for what each parameter means. v2.17: roundStep added —
   // passthrough to CExtendedKeyLevels::Configure(), default kept
   // separate from the other four params (own line) since it belongs to
   // a different underlying object, same separation the Init() wiring
   // above keeps.
   void              ConfigureKeyLevelDiagnostics(int lookbackBars = 5,
                                                   double levelSearchATRMax = 3.0,
                                                   double touchToleranceATRMult = 0.15,
                                                   int absorptionMinTouches = 3,
                                                   double wickRejectionRatio = 0.55,
                                                   double roundStep = 10.0);
   // v2.15 addition. Passthrough to CStrategySelector::Configure().
   void              ConfigureStrategySelection(double minSelectionScore = 60.0);
   double            CalculateConfidence(bool forBuy);
   void              EvaluateReasons(bool forBuy, SetupReasons &out);
   // v2.10. Call right after EvaluateReasons() with the confidence the
   // additive model actually returned; fills the four v2.10 diagnostic
   // fields on `out`. Separate from EvaluateReasons() because
   // env_exec_confidence needs a confidence value, and EvaluateReasons()
   // is deliberately allowed to run without one (the dashboard calls it).
   void              PopulateConfidenceDiagnostics(SetupReasons &out, double confidence);
   // v2.12. Same "call right after the fields it depends on exist"
   // convention as PopulateConfidenceDiagnostics(): call this after
   // EvaluateReasons() so out.regime/momentum_score/breakout_score/
   // breakout_class land on the same SetupReasons the rest of the row
   // describes. forBuy must match whatever direction EvaluateReasons()
   // was just called with, or the momentum/breakout read describes the
   // wrong side of the setup. confidence is the same value passed to
   // PopulateConfidenceDiagnostics() — v2.15 needs it to compare against
   // the three strategy scores computed in this same call.
   void              PopulateStrategyDiagnostics(bool forBuy, double confidence, SetupReasons &out);
   InducementResult  GetInducement(bool forBuy) { return m_inducement.Validate(forBuy); }
   ENUM_MARKET_PHASE GetPhase() { return m_phase.Detect(); }
  };
//+------------------------------------------------------------------+
CScoringEngine::CScoringEngine() : m_trendCtx(NULL), m_bosCtx(NULL), m_liqCtx(NULL),
                                    m_fvgCtx(NULL), m_srCtx(NULL), m_priceRef(NULL),
                                    m_requirePremiumDiscount(true), m_requireDistribution(false),
                                    m_requireVolumeConfirmation(false), m_rvolThreshold(1.5),
                                    m_requireFibonacciZone(false), m_fibZoneMinPct(50.0), m_fibZoneMaxPct(61.8),
                                    m_requireValueAreaLocation(false),
                                    m_htfObCtx(NULL), m_requireHtfOB(false), m_obDistATRMax(2.0),
                                    m_blockLowVolRegime(false),
                                    m_fvgMaxDistATR(1.25), m_requireChaseFilter(false), m_maxChaseDistATR(0.75),
                                    m_newsFilter(NULL), m_newsWarningMultiplier(0.85),
                                    m_contradictionWeight(0.25), m_envWeight(1.0), m_execWeight(1.0)
  {
   // Session filter defaults to ON — see ConfigureSessionFilter()'s
   // comment. Unlike the other v2.8 gates this isn't a new, unbacktested
   // signal; it's a liquidity-hours restriction, and trading 24h flat
   // (including the Tokyo-only dead zone) is itself the unvalidated
   // assumption per the audit that flagged it.
   m_sessionFilter.Configure(true, false, true, true, true);
  }
void CScoringEngine::Init(CTFContext* trendCtx, CTFContext* bosCtx, CTFContext* liqCtx,
                          CTFContext* fvgCtx, CTFContext* srCtx, CCandleData* priceRef)
  {
   m_trendCtx = trendCtx;
   m_bosCtx = bosCtx;
   m_liqCtx = liqCtx;
   m_fvgCtx = fvgCtx;
   m_srCtx = srCtx;
   m_priceRef = priceRef;
   if(m_fvgCtx != NULL)
     {
      m_inducement.Init(&m_fvgCtx.candles);
      if(m_liqCtx != NULL)
         m_phase.Init(&m_fvgCtx.candles, &m_liqCtx.liquidity);
     }
   if(m_bosCtx != NULL)
      m_volRegime.Init(&m_bosCtx.candles); // defaults: 100-bar lookback, 25th/75th pct bands
   // v2.12: regime detector needs all three reads; momentum/breakout
   // engine needs the BOS-timeframe's own candles/BOS/liquidity so its
   // bar_index comparisons stay on one timeframe's series (mixing BOS
   // events from one TF with liquidity events from another would make
   // HasNearbyLiquidityEvent's bar_index gap meaningless).
   if(m_trendCtx != NULL && m_bosCtx != NULL)
      m_regimeDetector.Init(&m_trendCtx.trend, &m_volRegime, &m_phase);
   if(m_bosCtx != NULL && m_liqCtx != NULL)
      m_momentumEngine.Init(&m_bosCtx.candles, &m_bosCtx.bos, &m_liqCtx.liquidity, &m_volRegime);
   // v2.13: chart-TF vol regime, deliberately separate instance from
   // m_volRegime above (see the member declaration comment for why).
   // Mean Reversion's candles/SR/valueArea all come from m_srCtx (chart
   // TF); liquidity/BOS reuse m_liqCtx/m_bosCtx same as Momentum does,
   // carrying the same cross-timeframe caveat documented there.
   if(m_srCtx != NULL)
     {
      m_volRegimeSR.Init(&m_srCtx.candles);
      if(m_liqCtx != NULL && m_bosCtx != NULL)
         m_meanReversionEngine.Init(&m_srCtx.candles, &m_srCtx.sr, &m_srCtx.valueArea,
                                    &m_liqCtx.liquidity, &m_volRegimeSR, &m_bosCtx.bos);
      // v2.14: same chart-TF sr/valueArea/orderBlock, same m_liqCtx
      // liquidity reuse (same cross-timeframe caveat as above).
      // v2.17: m_extendedKeyLevels.Init() needs a symbol — pulled from
      // this same chart-TF candle series rather than adding a new
      // parameter to CScoringEngine::Init(), since it's already the
      // exact symbol every other source in this engine is scoped to.
      // m_sessionFilter is already a member (see class declaration) —
      // passed by address, no separate Init() call needed for it here.
      if(m_liqCtx != NULL)
        {
         m_extendedKeyLevels.Init(m_srCtx.candles.Symbol());
         m_keyLevelEngine.Init(&m_srCtx.candles, &m_srCtx.sr, &m_srCtx.valueArea,
                               &m_liqCtx.liquidity, &m_srCtx.orderBlock,
                               &m_extendedKeyLevels, &m_sessionFilter);
        }
     }
  }
//+------------------------------------------------------------------+
void CScoringEngine::ConfigureInducement(int lookbackBars, double impulseATRMult, double impulseBodyRatio,
                                         double equalTolATR, int maxLegExtend,
                                         bool requirePremiumDiscount, bool requireDistribution,
                                         int phaseRangeLookback, double phaseCompressionATRMult)
  {
   if(m_fvgCtx != NULL)
     {
      m_inducement.Init(&m_fvgCtx.candles, lookbackBars, impulseATRMult, impulseBodyRatio, equalTolATR, maxLegExtend);
      if(m_liqCtx != NULL)
         m_phase.Init(&m_fvgCtx.candles, &m_liqCtx.liquidity, phaseRangeLookback, phaseCompressionATRMult);
     }
   m_requirePremiumDiscount = requirePremiumDiscount;
   m_requireDistribution = requireDistribution;
  }
//+------------------------------------------------------------------+
void CScoringEngine::ConfigureVolumeFibonacci(bool requireVolumeConfirmation, double rvolThreshold,
                                              bool requireFibonacciZone, double fibZoneMinPct, double fibZoneMaxPct)
  {
   m_requireVolumeConfirmation = requireVolumeConfirmation;
   m_rvolThreshold = (rvolThreshold > 0) ? rvolThreshold : 1.5;
   m_requireFibonacciZone = requireFibonacciZone;
   m_fibZoneMinPct = fibZoneMinPct;
   m_fibZoneMaxPct = fibZoneMaxPct;
  }
//+------------------------------------------------------------------+
void CScoringEngine::ConfigureValueArea(bool requireValueAreaLocation)
  {
   m_requireValueAreaLocation = requireValueAreaLocation;
  }
//+------------------------------------------------------------------+
void CScoringEngine::ConfigureHtfOrderBlock(CTFContext* htfObCtx, bool requireHtfOB, double distATRMax)
  {
   m_htfObCtx = htfObCtx;
   m_requireHtfOB = requireHtfOB;
   m_obDistATRMax = (distATRMax > 0) ? distATRMax : 2.0;
  }
//+------------------------------------------------------------------+
void CScoringEngine::ConfigureVolatilityRegime(bool blockLowVolRegime, int lookback, double lowPct, double highPct)
  {
   m_blockLowVolRegime = blockLowVolRegime;
   if(m_bosCtx != NULL)
      m_volRegime.Init(&m_bosCtx.candles, lookback, lowPct, highPct);
  }
//+------------------------------------------------------------------+
void CScoringEngine::ConfigureSessionFilter(bool enabled, bool allowTokyo, bool allowLondon,
                                            bool allowNewYork, bool allowOverlap)
  {
   m_sessionFilter.Configure(enabled, allowTokyo, allowLondon, allowNewYork, allowOverlap);
  }
//+------------------------------------------------------------------+
void CScoringEngine::ConfigureFVGProximity(double maxDistATR)
  {
   m_fvgMaxDistATR = (maxDistATR > 0) ? maxDistATR : 1.25;
  }
//+------------------------------------------------------------------+
void CScoringEngine::ConfigureChaseFilter(bool requireChaseFilter, double maxChaseDistATR)
  {
   m_requireChaseFilter = requireChaseFilter;
   m_maxChaseDistATR = (maxChaseDistATR > 0) ? maxChaseDistATR : 0.75;
  }
//+------------------------------------------------------------------+
void CScoringEngine::ConfigureSweepQuality(bool requireMinSweepGrade, ENUM_SWEEP_GRADE minSweepGrade,
                                           bool requireFreshSetup, int maxBarsSinceBOS)
  {
   m_inducement.ConfigureQualityGates(requireMinSweepGrade, minSweepGrade, requireFreshSetup, maxBarsSinceBOS);
  }
//+------------------------------------------------------------------+
void CScoringEngine::ConfigureNewsAwareness(CNewsFilter* newsFilter, int warnMinutesBefore,
                                            int warnMinutesAfter, double newsWarningMultiplier)
  {
   m_newsFilter = newsFilter;
   if(m_newsFilter != NULL)
      m_newsFilter.ConfigureWarningWindow(warnMinutesBefore, warnMinutesAfter);
   m_newsWarningMultiplier = (newsWarningMultiplier > 0 && newsWarningMultiplier <= 1.0) ? newsWarningMultiplier : 0.85;
  }
//+------------------------------------------------------------------+
double CScoringEngine::CurrentPrice()
  {
   if(m_priceRef == NULL || m_priceRef.Total() == 0) return 0.0;
   return m_priceRef.GetCandle(0).close;
  }
//+------------------------------------------------------------------+
double CScoringEngine::TrendScore(bool forBuy)
  {
   if(m_trendCtx == NULL) return 0.0;
   ENUM_TREND_STATE t = m_trendCtx.trend.GetCurrentTrend();
   if(forBuy)
     {
      if(t == TREND_BULL_STRONG) return 1.0;
      if(t == TREND_BULL) return 0.6;
      return 0.0;
     }
   else
     {
      if(t == TREND_BEAR_STRONG) return 1.0;
      if(t == TREND_BEAR) return 0.6;
      return 0.0;
     }
  }
//+------------------------------------------------------------------+
double CScoringEngine::BOSChoCHScore(bool forBuy)
  {
   if(m_bosCtx == NULL) return 0.0;
   const int recencyBars = 20;
   double score = 0.0;

   if(m_bosCtx.bos.Count() > 0)
     {
      BOSEvent recent = m_bosCtx.bos.GetBOS(0);
      if(recent.is_bullish == forBuy && recent.bar_index <= recencyBars)
         score += 0.6 * recent.strength;
     }
   if(m_bosCtx.choch.Count() > 0)
     {
      CHOCHPoint c0 = m_bosCtx.choch.Get(0);
      if(c0.bullish == forBuy && c0.bar_index <= recencyBars)
         score += 0.4;
      else if(m_bosCtx.choch.Count() > 1)
        {
         CHOCHPoint c1 = m_bosCtx.choch.Get(1);
         if(c1.bullish == forBuy && c1.bar_index <= recencyBars)
            score += 0.4;
        }
     }
   return MathMin(score, 1.0);
  }
//+------------------------------------------------------------------+
double CScoringEngine::LiquidityScore(bool forBuy)
  {
   if(m_liqCtx == NULL || m_liqCtx.liquidity.EventCount() == 0) return 0.0;
   const int recencyBars = 10;
   LiquidityEvent ev = m_liqCtx.liquidity.GetEvent(0);
   if(ev.bar_index > recencyBars) return 0.0;
   bool supportsBuy = (ev.type == LIQ_SELL_SIDE);
   if(forBuy == supportsBuy) return ev.strength;
   return 0.0;
  }
//+------------------------------------------------------------------+
double CScoringEngine::FVGScore(bool forBuy)
  {
   if(m_fvgCtx == NULL || m_fvgCtx.candles.Total() == 0) return 0.0;
   double price = CurrentPrice();
   double atr = m_fvgCtx.candles.GetATR(0);
   if(price <= 0 || atr <= 0) return 0.0;
   ENUM_FVG_DIR wantDir = forBuy ? FVG_BULL : FVG_BEAR;

   // v2.9 (review item #7/#8): rank every qualifying zone instead of
   // returning the first match — "first" is an artifact of detection
   // order, not quality. Distance cap now m_fvgMaxDistATR (default 1.25,
   // was hardcoded 3.0) — see ConfigureFVGProximity().
   double best = 0.0;
   for(int i = 0; i < m_fvgCtx.fvg.Count(); i++)
     {
      FVGZone z = m_fvgCtx.fvg.GetZone(i);
      if(z.dir != wantDir) continue;
      if(z.state != FVG_FRESH && z.state != FVG_TESTED) continue;
      double mid = (z.top + z.bottom) / 2.0;
      double distATR = MathAbs(price - mid) / atr;
      if(distATR > m_fvgMaxDistATR) continue;
      double base = (z.state == FVG_FRESH) ? 1.0 : 0.6;
      double proximity = MathMax(0.0, 1.0 - distATR / m_fvgMaxDistATR);
      double score = base * (0.5 + 0.5 * proximity);
      if(score > best) best = score;
     }
   return best;
  }
//+------------------------------------------------------------------+
double CScoringEngine::SRScore(bool forBuy)
  {
   if(m_srCtx == NULL || m_srCtx.candles.Total() == 0) return 0.0;
   double price = CurrentPrice();
   double atr = m_srCtx.candles.GetATR(0);
   if(price <= 0 || atr <= 0) return 0.0;

   for(int i = 0; i < m_srCtx.sr.Count(); i++)
     {
      SRZone z = m_srCtx.sr.GetZone(i);
      bool isSupport = (z.type == SR_MAJOR_SUPPORT || z.type == SR_MINOR_SUPPORT);
      bool isResistance = (z.type == SR_MAJOR_RESISTANCE || z.type == SR_MINOR_RESISTANCE);
      if(forBuy && !isSupport) continue;
      if(!forBuy && !isResistance) continue;
      double mid = (z.top + z.bottom) / 2.0;
      double distATR = MathAbs(price - mid) / atr;
      if(distATR > 1.5) continue;
      return MathMin((double)z.touches / 3.0, 1.0);
     }
   return 0.0;
  }
//+------------------------------------------------------------------+
// RVOL of the BOS/structure timeframe's most recently CLOSED bar.
// FIX (audit #16): the EA evaluates once per NEW bar (OnTick fires the
// instant iTime() for shift 0 changes -- i.e. the instant a bar OPENS),
// so shift 0 at that exact moment is a brand-new candle with almost no
// tick volume accumulated yet. Gating InpRVOLThreshold against that
// number checked volume at the single most uninformative instant
// possible. Shift 1 is the bar that just fully closed -- final volume,
// actually means something -- and matches what the audit itself
// recommended ("the volume gate should probably use a closed BOS/
// structure candle rather than the currently forming bar").
double CScoringEngine::VolumeScore(bool forBuy)
  {
   if(m_bosCtx == NULL) return 0.0;
   return m_bosCtx.volume.Score(1, m_rvolThreshold);
  }
//+------------------------------------------------------------------+
double CScoringEngine::FibonacciScore(bool forBuy)
  {
   if(m_bosCtx == NULL) return 0.0;
   double price = CurrentPrice();
   if(price <= 0) return 0.0;
   return m_bosCtx.fibonacci.Score(forBuy, price, m_fibZoneMinPct, m_fibZoneMaxPct);
  }
//+------------------------------------------------------------------+
// Value Area is chart-TF, same as SRScore() — it's "where is price
// relative to fair value on the resolution you're actually looking at."
double CScoringEngine::ValueAreaScore(bool forBuy)
  {
   if(m_srCtx == NULL) return 0.0;
   double price = CurrentPrice();
   if(price <= 0) return 0.0;
   return m_srCtx.valueArea.Score(forBuy, price);
  }
//+------------------------------------------------------------------+
// v2.8. Distance-scored the same way SRScore() rewards proximity: full
// credit at the OB midpoint, decaying to 0 at m_obDistATRMax. Uses the
// HTF context's OWN atr (m_htfObCtx.candles), not the entry-TF ATR — a
// "2 ATR" distance means something different on H4 than on M15, and
// mixing them would silently change what "near confluence" means.
double CScoringEngine::OBScore(bool forBuy)
  {
   if(m_htfObCtx == NULL) return 0.0;
   double price = CurrentPrice();
   if(price <= 0) return 0.0;
   double atr = m_htfObCtx.candles.GetATR(0);
   if(atr <= 0) return 0.0;

   OrderBlockZone z;
   ENUM_FVG_DIR dir = forBuy ? FVG_BULL : FVG_BEAR;
   if(!m_htfObCtx.orderBlock.NearestZone(dir, price, atr, m_obDistATRMax, z)) return 0.0;

   double mid = (z.top + z.bottom) / 2.0;
   double distATR = MathAbs(price - mid) / atr;
   double proximity = MathMax(0.0, 1.0 - distATR / m_obDistATRMax);
   double stateMult = (z.state == OB_FRESH) ? 1.0 : 0.7; // tested zones still count, just less
   return MathMin(proximity * stateMult, 1.0);
  }
//+------------------------------------------------------------------+
double CScoringEngine::CalculateConfidence(bool forBuy)
  {
   // v2.8: session gate runs first and cheapest — no point evaluating the
   // rest of the pipeline for a bar that's going to be rejected anyway.
   if(!m_sessionFilter.IsAllowed())
      return 0.0;

   InducementResult ind = m_inducement.Validate(forBuy);
   if(!ind.valid) return 0.0;

   // v2.9 (review item #4/#10 — chase filter). Rejects a setup that's
   // already run too far past the BOS confirmation close by the time the
   // EA evaluates it — the single worst entry location per the review
   // ("BOS -> price explodes 1.2 ATR -> EA enters after"). Distinct from
   // OrderManager's entry-deviation guard, which protects execution
   // slippage AFTER a decision, not the decision itself. OFF by default.
   if(m_requireChaseFilter && ind.bosBarIndex >= 0 && m_bosCtx != NULL)
     {
      double price = CurrentPrice();
      double atr = m_bosCtx.candles.GetATR(0);
      if(price > 0 && atr > 0)
        {
         double chaseDist = forBuy ? (price - ind.bosClosePrice) : (ind.bosClosePrice - price);
         if(chaseDist / atr > m_maxChaseDistATR)
            return 0.0;
        }
     }

   double score = ind.totalScore;

   // v2.9: news-aware soft discount. The EA-level IsLocked() hard-blocks
   // the narrow window already (this code path never even runs then,
   // since the EA skips setup generation entirely) — this only fires in
   // the wider WARNING band around the block window.
   if(m_newsFilter != NULL)
     {
      string newsLabel; int newsMinutes;
      ENUM_NEWS_RISK tier = m_newsFilter.GetRiskTier(newsLabel, newsMinutes);
      if(tier == NEWS_WARNING)
         score *= m_newsWarningMultiplier;
     }
   score += 15.0 * FVGScore(forBuy);
   score += 15.0 * TrendScore(forBuy);

   if(m_requirePremiumDiscount)
     {
      double price = CurrentPrice();
      if(price > 0 && !CPremiumDiscount::OK(forBuy, price, ind.leg))
         return 0.0;
     }

   if(m_requireDistribution)
     {
      if(m_phase.Detect() != PHASE_DISTRIBUTION)
         return 0.0;
     }

   // v2.6 gates — see ConfigureVolumeFibonacci()'s comment for why both
   // default OFF. When ON, a fail here zeroes confidence exactly like the
   // premium/discount and phase gates above; nothing downstream can undo
   // that with a high inducement score. When passed (or disabled), a
   // small capped bonus nudges ranking only.
   if(m_requireVolumeConfirmation)
     {
      if(m_bosCtx == NULL || m_bosCtx.volume.RVOL(1) < m_rvolThreshold) // FIX #16: shift 1, see VolumeScore() above
         return 0.0;
     }
   if(m_requireFibonacciZone)
     {
      double price = CurrentPrice();
      if(price <= 0 || m_bosCtx == NULL ||
         !m_bosCtx.fibonacci.InPullbackZone(forBuy, price, m_fibZoneMinPct, m_fibZoneMaxPct))
         return 0.0;
     }
   if(m_requireValueAreaLocation)
     {
      double price = CurrentPrice();
      if(price <= 0 || m_srCtx == NULL || !m_srCtx.valueArea.IsValid() ||
         !m_srCtx.valueArea.LocationOK(forBuy, price))
         return 0.0;
     }
   // v2.8 gates — same "fail-closed on unverifiable, hard-zero on
   // confirmed-wrong" discipline as the v2.6 block above. Both OFF by
   // default (see ConfigureHtfOrderBlock()/ConfigureVolatilityRegime()).
   if(m_requireHtfOB)
     {
      if(OBScore(forBuy) <= 0.0)
         return 0.0;
     }
   if(m_blockLowVolRegime)
     {
      ENUM_VOL_REGIME regime = m_volRegime.Classify(0);
      if(regime == VOL_REGIME_LOW)
         return 0.0;
      // VOL_REGIME_UNDEFINED (not enough ATR history) fails OPEN here,
      // deliberately inconsistent with the fail-closed CONFIRMATION rule
      // elsewhere: this is a data-availability gap, not a claim the setup
      // failed to confirm, and early-history warm-up shouldn't zero every
      // setup for the first `lookback` bars of a backtest.
     }

   score += 5.0 * VolumeScore(forBuy);
   score += 5.0 * FibonacciScore(forBuy);
   score += 5.0 * ValueAreaScore(forBuy);
   score += 5.0 * OBScore(forBuy);

   // FIX (audit #21 -- scoring model drift): real max raw score is 120
   // (70 inducement + 15 FVG + 15 Trend + 5+5+5+5 Vol/Fib/VA/OB), not the
   // 100 the old MathMin(score,100) clip implied. A hard clip means a
   // setup scoring 105 and one scoring 120 both reported as confidence
   // 100 -- indistinguishable to InpMinConfidenceExecute,
   // InpFullRiskConfidence, the dashboard, and the published signal, even
   // though one was meaningfully stronger. Rescaling against the TRUE
   // achievable maximum instead preserves relative ranking; confidence
   // 100 now only occurs when every component is actually maxed.
   const double MAX_RAW_SCORE = 120.0;
   double normalized = (score / MAX_RAW_SCORE) * 100.0;
   return MathMin(MathMax(normalized, 0.0), 100.0);
  }
//+------------------------------------------------------------------+
double CScoringEngine::PipSize()
  {
   if(m_priceRef == NULL) return 0.0001;
   // v2.9: delegates to CPipCalculator so this is the same definition
   // everywhere (Telegram payload, dashboard) instead of a locally
   // re-derived one. Behavior is unchanged — same formula as before.
   return CPipCalculator::PipSize(m_priceRef.Symbol());
  }
//+------------------------------------------------------------------+
void CScoringEngine::EvaluateReasons(bool forBuy, SetupReasons &out)
  {
   ZeroMemory(out);
   out.trend_aligned   = (TrendScore(forBuy) >= 0.6);
   out.bos_confirmed   = (BOSChoCHScore(forBuy) > 0.0);
   out.liquidity_swept = (LiquidityScore(forBuy) > 0.0);
   out.fresh_fvg       = (FVGScore(forBuy) > 0.0);
   out.sr_confluence   = (SRScore(forBuy) > 0.0);

   InducementResult ind = m_inducement.Validate(forBuy);
   out.inducement_valid = ind.valid;
   out.phase = m_phase.Detect();

   double price = CurrentPrice();
   out.premium_discount_ok = (price > 0) ? CPremiumDiscount::OK(forBuy, price, ind.leg) : true;

   // v2.6 diagnostics — always populated (dashboard/CSV visibility) even
   // when the corresponding gate in CalculateConfidence is disabled.
   if(m_bosCtx != NULL)
     {
      out.rvol = m_bosCtx.volume.RVOL(1); // FIX #16: shift 1, see VolumeScore() above -- diagnostics must match the live gate
      out.volume_confirmed = (out.rvol >= m_rvolThreshold);
      if(price > 0)
        {
         out.fib_zone = m_bosCtx.fibonacci.Zone(forBuy, price);
         out.fib_in_zone = m_bosCtx.fibonacci.InPullbackZone(forBuy, price, m_fibZoneMinPct, m_fibZoneMaxPct);
         double pctOut;
         out.fib_nearest_level = m_bosCtx.fibonacci.NearestLevel(forBuy, price, pctOut);
        }
     }

   if(m_srCtx != NULL && m_srCtx.valueArea.IsValid())
     {
      out.value_area_ok = m_srCtx.valueArea.LocationOK(forBuy, price);
      out.va_zone = m_srCtx.valueArea.Zone(price);
      out.va_poc = m_srCtx.valueArea.POC();
      out.va_high = m_srCtx.valueArea.VAH();
      out.va_low = m_srCtx.valueArea.VAL();
     }

   // v2.8 diagnostics — always populated regardless of gate state, same
   // convention as the v2.6 block above.
   out.htf_ob_confluence = (OBScore(forBuy) > 0.0);
   if(m_htfObCtx != NULL && price > 0)
     {
      double atr = m_htfObCtx.candles.GetATR(0);
      OrderBlockZone z;
      if(atr > 0 && m_htfObCtx.orderBlock.NearestZone(forBuy ? FVG_BULL : FVG_BEAR, price, atr, m_obDistATRMax, z))
         out.htf_ob_state = z.state;
     }
   out.vol_regime = m_volRegime.Classify(0);
   out.session = m_sessionFilter.CurrentSession();
   out.session_ok = m_sessionFilter.IsAllowed();

   // v2.9 diagnostics — always populated regardless of gate state, same
   // convention as the v2.6/v2.8 blocks above.
   out.sweep_grade = ind.sweepGrade;
   out.bos_strength = ind.bosStrength;
   out.time_decay = ind.timeDecay;
   out.chase_dist_atr = 0.0;
   out.chase_ok = true;
   if(ind.bosBarIndex >= 0 && m_bosCtx != NULL && price > 0)
     {
      double atrB = m_bosCtx.candles.GetATR(0);
      if(atrB > 0)
        {
         out.chase_dist_atr = (forBuy ? (price - ind.bosClosePrice) : (ind.bosClosePrice - price)) / atrB;
         out.chase_ok = (out.chase_dist_atr <= m_maxChaseDistATR);
        }
     }

   out.news_risk = NEWS_NONE;
   out.news_label = "";
   out.news_minutes_to_event = 0;
   if(m_newsFilter != NULL)
      out.news_risk = m_newsFilter.GetRiskTier(out.news_label, out.news_minutes_to_event);

   out.risk_warning = "";
   if(m_srCtx == NULL || m_priceRef == NULL || m_priceRef.Total() == 0) return;

   double pip = PipSize();
   if(pip <= 0) pip = 0.0001;
   double bestDist = -1.0;
   ENUM_SR_TYPE bestType = SR_MINOR_RESISTANCE;
   int bestTouches = 0;

   for(int i = 0; i < m_srCtx.sr.Count(); i++)
     {
      SRZone z = m_srCtx.sr.GetZone(i);
      bool isResistance = (z.type == SR_MAJOR_RESISTANCE || z.type == SR_MINOR_RESISTANCE);
      bool isSupport = (z.type == SR_MAJOR_SUPPORT || z.type == SR_MINOR_SUPPORT);
      double mid = (z.top + z.bottom) / 2.0;

      if(forBuy && isResistance && mid > price)
        {
         double dist = (mid - price) / pip;
         if(bestDist < 0 || dist < bestDist) { bestDist = dist; bestType = z.type; bestTouches = z.touches; }
        }
      else if(!forBuy && isSupport && mid < price)
        {
         double dist = (price - mid) / pip;
         if(bestDist < 0 || dist < bestDist) { bestDist = dist; bestType = z.type; bestTouches = z.touches; }
        }
     }

   if(bestDist >= 0 && bestDist <= 60.0)
     {
      string strength = (bestType == SR_MAJOR_RESISTANCE || bestType == SR_MAJOR_SUPPORT) ? "High-impact" : "Minor";
      string kind = forBuy ? "resistance" : "support";
      out.risk_warning = StringFormat("%s %s %.0f pips away (%d touches)", strength, kind, bestDist, bestTouches);
     }
  }
//+------------------------------------------------------------------+
void CScoringEngine::ConfigureLearnedDiagnostics(double contradictionWeight, double envWeight, double execWeight)
  {
   m_contradictionWeight = MathMax(0.0, contradictionWeight);
   m_envWeight  = MathMin(MathMax(envWeight, 0.0), 1.0);
   m_execWeight = MathMin(MathMax(execWeight, 0.0), 1.0);
  }
//+------------------------------------------------------------------+
// v2.10 - CONTRADICTION, not absence. The additive model's failure mode is
// that a missing component costs the same as a component actively pointing
// the other way: a setup with no HTF read and a setup fighting the HTF
// trend score identically. This counts only actively-opposing conditions,
// so "unknown" and "wrong" stop being the same number. Returns 0-1.
double CScoringEngine::ContradictionPenalty(const SetupReasons &r)
  {
   int hits = 0;
   if(!r.trend_aligned)               hits++; // trend does not support the direction
   if(!r.premium_discount_ok)         hits++; // buying premium / selling discount
   if(!r.chase_ok)                    hits++; // price already ran past the BOS close
   if(r.vol_regime == VOL_REGIME_LOW) hits++; // thin, chop-prone regime
   if(!r.session_ok)                  hits++; // outside the allowed liquidity hours
   if(r.news_risk != NEWS_NONE)       hits++; // inside a news risk tier
   if(r.htf_ob_state == OB_MITIGATED) hits++; // the HTF OB this leans on is already spent
   if(hits == 0) return 0.0;
   double penalty = m_contradictionWeight * (double)hits;
   return MathMin(MathMax(penalty, 0.0), 1.0);
  }
//+------------------------------------------------------------------+
// v2.10 - "is the market itself suitable right now", independent of this
// particular entry. Multiplicative by design: a perfect entry in an
// unsuitable environment should not score like a perfect entry in a
// suitable one, which is exactly what adding points cannot express.
double CScoringEngine::EnvironmentScore(const SetupReasons &r)
  {
   double s = 1.0;
   if(r.vol_regime == VOL_REGIME_LOW)            s *= 0.60;
   else if(r.vol_regime == VOL_REGIME_HIGH)      s *= 0.90; // tradeable, but stops get run
   else if(r.vol_regime == VOL_REGIME_UNDEFINED) s *= 0.85; // warm-up: unknown rather than bad
   if(!r.session_ok)                             s *= 0.70;
   if(r.news_risk == NEWS_WARNING)               s *= 0.80;
   else if(r.news_risk == NEWS_BLOCKED)          s *= 0.50; // the hard block already stops entries; this only shapes the diagnostic
   // m_envWeight blends toward neutral 1.0, so 0 disables the component's
   // influence without needing a separate on/off flag.
   return MathMin(MathMax(1.0 - m_envWeight * (1.0 - s), 0.0), 1.0);
  }
//+------------------------------------------------------------------+
// v2.10 - "how good is THIS entry", given the environment is acceptable.
// Built from the v2.9 continuous reads (sweep grade, BOS strength, time
// decay) that the additive model currently collapses into pass/fail.
double CScoringEngine::ExecutionScore(const SetupReasons &r)
  {
   double grade = 0.40; // no graded sweep
   switch(r.sweep_grade)
     {
      case SWEEP_GRADE_A: grade = 1.00; break;
      case SWEEP_GRADE_B: grade = 0.80; break;
      case SWEEP_GRADE_C: grade = 0.55; break;
      default:            grade = 0.40; break;
     }
   double strength = MathMin(MathMax(r.bos_strength, 0.0), 1.0);
   double freshness = MathMin(MathMax(r.time_decay, 0.0), 1.0);
   if(freshness <= 0.0) freshness = 1.0; // 0 means "not computed", not "infinitely stale"
   double s = grade * (0.5 + 0.5 * strength) * freshness;
   if(!r.fresh_fvg) s *= 0.85;
   if(!r.chase_ok)  s *= 0.75;
   return MathMin(MathMax(1.0 - m_execWeight * (1.0 - s), 0.0), 1.0);
  }
//+------------------------------------------------------------------+
void CScoringEngine::PopulateConfidenceDiagnostics(SetupReasons &out, double confidence)
  {
   out.contradiction_penalty = ContradictionPenalty(out);
   out.env_score = EnvironmentScore(out);
   out.exec_score = ExecutionScore(out);
   double c = MathMin(MathMax(confidence, 0.0), 100.0);
   out.env_exec_confidence = c * out.env_score * out.exec_score * (1.0 - out.contradiction_penalty);
  }
//+------------------------------------------------------------------+
void CScoringEngine::ConfigureStrategyDiagnostics(int momentumBreakoutRecencyBars, int liqOverlapBars,
                                                  int extensionLookbackBars, double exhaustionATRMult,
                                                  int momentumLookbackBars)
  {
   m_momentumEngine.Configure(momentumBreakoutRecencyBars, liqOverlapBars, extensionLookbackBars,
                              exhaustionATRMult, momentumLookbackBars);
  }
//+------------------------------------------------------------------+
// v2.13. Passthrough, same shape as ConfigureStrategyDiagnostics above.
void CScoringEngine::ConfigureMeanReversionDiagnostics(double minStretchATR, double srZoneATRTolerance,
                                                       double wickRejectionRatio, int liqRecencyBars,
                                                       int trendConflictRecencyBars, double trendConflictMinStrength)
  {
   m_meanReversionEngine.Configure(minStretchATR, srZoneATRTolerance, wickRejectionRatio,
                                   liqRecencyBars, trendConflictRecencyBars, trendConflictMinStrength);
  }
//+------------------------------------------------------------------+
// v2.14. Passthrough, same shape as the two Configure methods above.
// v2.17: roundStep passthrough to CExtendedKeyLevels added.
void CScoringEngine::ConfigureKeyLevelDiagnostics(int lookbackBars, double levelSearchATRMax,
                                                  double touchToleranceATRMult, int absorptionMinTouches,
                                                  double wickRejectionRatio, double roundStep)
  {
   m_keyLevelEngine.Configure(lookbackBars, levelSearchATRMax, touchToleranceATRMult,
                              absorptionMinTouches, wickRejectionRatio);
   m_extendedKeyLevels.Configure(roundStep);
  }
//+------------------------------------------------------------------+
// v2.15. Passthrough, same shape as the three Configure methods above.
void CScoringEngine::ConfigureStrategySelection(double minSelectionScore)
  {
   m_strategySelector.Configure(minSelectionScore);
  }
//+------------------------------------------------------------------+
// v2.12. Deliberately separate from PopulateConfidenceDiagnostics() even
// though both are called from the same two call sites in
// Trading/TradeZone.mqh — that one reads fields EvaluateReasons() just
// set, this one runs two independent engines. Keeping them as two
// methods (rather than folding this into PopulateConfidenceDiagnostics)
// means a future change to one can't silently change what the other
// logs, and matches this class's existing pattern of one method per
// diagnostic generation added (v2.10 got its own method; this does too).
void CScoringEngine::PopulateStrategyDiagnostics(bool forBuy, double confidence, SetupReasons &out)
  {
   out.regime = m_regimeDetector.Classify();
   m_momentumEngine.Evaluate(forBuy, out.momentum_score, out.breakout_score, out.breakout_class);
   // v2.13: independent second strategy score, same call site, same
   // "never feeds back" discipline as the momentum/breakout call above.
   m_meanReversionEngine.Evaluate(forBuy, out.reversion_score, out.reversion_class);
   // v2.14: third independent strategy score, same call site, same
   // "never feeds back" discipline as the two calls above.
   m_keyLevelEngine.Evaluate(forBuy, out.keylevel_source, out.keylevel_reaction, out.keylevel_score);
   // v2.15: runs LAST, after every score above is populated on `out` —
   // compares them, never sums them. See Strategies/StrategySelector.mqh
   // for why that distinction is the entire point of this class. Still
   // never feeds back into `confidence` itself — it only writes to
   // out.selected_strategy / out.selected_strategy_score.
   m_strategySelector.Select(out, confidence, out.selected_strategy, out.selected_strategy_score);
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Analysis/Scoring.mqh ----

// ---- BEGIN EA/includes/Trading/TradeZone.mqh ----
//+------------------------------------------------------------------+
//|                                              Trading/TradeZone.mqh |
//+------------------------------------------------------------------+
#ifndef TRADEZONE_MQH
#define TRADEZONE_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/CandleData.mqh ----

// ---- END EA/includes/Core/CandleData.mqh ----


// ---- BEGIN EA/includes/Core/RuntimeParameters.mqh ----
//+------------------------------------------------------------------+
//| Core/RuntimeParameters.mqh                                       |
//| Validated runtime configuration delivered by ConfigSync.          |
//+------------------------------------------------------------------+
#ifndef RUNTIMEPARAMETERS_MQH
#define RUNTIMEPARAMETERS_MQH

struct RuntimeParameters
  {
   int    ensemble_threshold;
   int    smc_threshold;
   int    momentum_threshold;
   int    breakout_threshold;
   int    mean_reversion_threshold;
   int    key_level_threshold;
   double fvg_proximity_atr;
   double contradiction_penalty;
   int    freshness_bars;

   void Defaults()
     {
      ensemble_threshold = 62;
      smc_threshold = 60;
      momentum_threshold = 60;
      breakout_threshold = 60;
      mean_reversion_threshold = 60;
      key_level_threshold = 60;
      fvg_proximity_atr = 0.20;
      contradiction_penalty = 0.10;
      freshness_bars = 12;
     }
  };

#endif // RUNTIMEPARAMETERS_MQH
//+------------------------------------------------------------------+


// ---- END EA/includes/Core/RuntimeParameters.mqh ----


// ---- BEGIN EA/includes/Core/RuntimeConfigBus.mqh ----
//+------------------------------------------------------------------+
//| Core/RuntimeConfigBus.mqh                                        |
//| Dependency-inversion seam between ConfigSync and the EA engine.   |
//+------------------------------------------------------------------+
#ifndef RUNTIMECONFIGBUS_MQH
#define RUNTIMECONFIGBUS_MQH

// ---- BEGIN EA/includes/Core/RuntimeParameters.mqh ----

// ---- END EA/includes/Core/RuntimeParameters.mqh ----

interface IRuntimeConfigConsumer
  {
   void ApplyRuntimeParameters(const RuntimeParameters &parameters);
  };

IRuntimeConfigConsumer *g_runtimeConfigConsumer = NULL;

void BindRuntimeConfigConsumer(IRuntimeConfigConsumer *consumer)
  {
   g_runtimeConfigConsumer = consumer;
  }

IRuntimeConfigConsumer *GetRuntimeConfigConsumer()
  {
   return g_runtimeConfigConsumer;
  }

#endif // RUNTIMECONFIGBUS_MQH
//+------------------------------------------------------------------+


// ---- END EA/includes/Core/RuntimeConfigBus.mqh ----


// ---- BEGIN EA/includes/Analysis/TFContext.mqh ----

// ---- END EA/includes/Analysis/TFContext.mqh ----


// ---- BEGIN EA/includes/Analysis/Scoring.mqh ----

// ---- END EA/includes/Analysis/Scoring.mqh ----


// ---- BEGIN EA/includes/Trading/Targets.mqh ----
//+------------------------------------------------------------------+
//|                                                Trading/Targets.mqh |
//+------------------------------------------------------------------+
#ifndef TARGETS_MQH
#define TARGETS_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Analysis/TFContext.mqh ----

// ---- END EA/includes/Analysis/TFContext.mqh ----

// Ranks resting liquidity by "how big a stop hunt would this be" and lays
// TP1/TP2/TP3 out along that ladder instead of fixed ATR multiples:
//   TP1 = nearest internal pool (equal highs/lows)      priority 75
//   TP2 = nearest external D1 high/low                  priority 90
//   TP3 = weekly high/low                                priority 100
// Any tier with no valid candidate (must be beyond price in the trade's
// direction, and — where a tier already exists before it — beyond the
// previous tier) falls back to an ATR step so a thin liquidity map never
// blocks target assignment outright.
class CTargetSelector
  {
private:
   static bool       NearestBeyond(CTFContext* liqCtx, bool wantInternal, bool forBuy,
                                   double entryPrice, double excludeBeyond, bool haveExclude,
                                   double &outPrice);
   static bool       WeeklyLevel(string symbol, bool forBuy, double &outPrice);

public:
   static void       AssignTargets(TradeSetup &setup, CTFContext* liqCtx, string symbol,
                                   double atr, double entryPrice);
  };
//+------------------------------------------------------------------+
// Scans liquidity pools for the nearest one on the correct side of price
// (LIQ_BUY_SIDE pools sit above price and are the natural target for a
// buy; LIQ_SELL_SIDE pools sit below and target a sell), optionally
// requiring it to sit beyond an already-chosen level (so TP2 can't land
// behind TP1).
bool CTargetSelector::NearestBeyond(CTFContext* liqCtx, bool wantInternal, bool forBuy,
                                    double entryPrice, double excludeBeyond, bool haveExclude,
                                    double &outPrice)
  {
   outPrice = 0.0;
   if(liqCtx == NULL) return false;
   double best = 0.0;
   bool have = false;

   for(int i = 0; i < liqCtx.liquidity.PoolCount(); i++)
     {
      LiquidityPool p = liqCtx.liquidity.GetPool(i);
      if(p.external == wantInternal) continue; // wantInternal=true means we want external==false
      double price = forBuy ? p.price_top : p.price_bottom;
      bool onRightSide = forBuy ? (price > entryPrice) : (price < entryPrice);
      if(!onRightSide) continue;
      if(haveExclude)
        {
         bool beyondPrior = forBuy ? (price > excludeBeyond) : (price < excludeBeyond);
         if(!beyondPrior) continue;
        }
      bool better = !have || (forBuy ? (price < best) : (price > best)); // nearest = smallest distance
      if(better) { best = price; have = true; }
     }
   if(have) outPrice = best;
   return have;
  }
//+------------------------------------------------------------------+
bool CTargetSelector::WeeklyLevel(string symbol, bool forBuy, double &outPrice)
  {
   double v = forBuy ? iHigh(symbol, PERIOD_W1, 1) : iLow(symbol, PERIOD_W1, 1);
   if(v <= 0) return false;
   outPrice = v;
   return true;
  }
//+------------------------------------------------------------------+
void CTargetSelector::AssignTargets(TradeSetup &setup, CTFContext* liqCtx, string symbol,
                                    double atr, double entryPrice)
  {
   bool forBuy = (setup.type == ORDER_TYPE_BUY);
   double tp1, tp2, tp3;

   // TP1: nearest internal (equal highs/lows) pool.
   if(!NearestBeyond(liqCtx, true, forBuy, entryPrice, 0.0, false, tp1))
      tp1 = forBuy ? entryPrice + 2.0 * atr : entryPrice - 2.0 * atr;

   // TP2: nearest external (D1) pool beyond TP1.
   if(!NearestBeyond(liqCtx, false, forBuy, entryPrice, tp1, true, tp2))
      tp2 = forBuy ? tp1 + atr : tp1 - atr;

   // TP3: weekly high/low beyond TP2.
   double weekly;
   if(WeeklyLevel(symbol, forBuy, weekly) && (forBuy ? (weekly > tp2) : (weekly < tp2)))
      tp3 = weekly;
   else
      tp3 = forBuy ? tp2 + atr : tp2 - atr;

   setup.tp1 = tp1;
   setup.tp2 = tp2;
   setup.final_tp = tp3;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Trading/Targets.mqh ----

class CTradeDecision : public IRuntimeConfigConsumer
  {
private:
   CCandleData*      m_priceRef;
   CTFContext*       m_fvgCtx;
   CTFContext*       m_liqCtx;
   CScoringEngine*   m_scoring;
   TradeSetup        m_lastSetup;
   double            m_slBufferATR;
   double            m_minStopSpreadMult;
   double            m_fvgMaxDistATR;
   bool              m_runtimeEnabled;
   RuntimeParameters m_runtime;

   bool              FindEntryFVG(ENUM_FVG_DIR dir, FVGZone &out);
   double            EnforceSpreadFloor(string symbol, double entry, double stopLoss, bool isBuy);
   double            RuntimeStrategyThreshold(const TradeSetup &setup);
   double            RuntimeContradictionPenalty(const SetupReasons &r);
   void              ApplyRuntimeOverlay(TradeSetup &setup);

public:
                     CTradeDecision();
   void              Init(CCandleData* priceRef, CTFContext* fvgCtx, CTFContext* liqCtx, CScoringEngine* scoring,
                          double slBufferATR = 0.25, double minStopSpreadMult = 3.0);
   void              ApplyRuntimeParameters(const RuntimeParameters &parameters);
   TradeSetup        GenerateBuySetup();
   TradeSetup        GenerateSellSetup();
   TradeSetup        GetLastSetup() const { return m_lastSetup; }
  };

CTradeDecision::CTradeDecision()
  {
   ZeroMemory(m_lastSetup);
   m_slBufferATR = 0.25;
   m_minStopSpreadMult = 3.0;
   m_fvgMaxDistATR = 3.0;
   m_runtimeEnabled = false;
   m_runtime.Defaults();
   BindRuntimeConfigConsumer(this);
  }

void CTradeDecision::Init(CCandleData* priceRef, CTFContext* fvgCtx, CTFContext* liqCtx, CScoringEngine* scoring,
                          double slBufferATR, double minStopSpreadMult)
  {
   m_priceRef = priceRef;
   m_fvgCtx = fvgCtx;
   m_liqCtx = liqCtx;
   m_scoring = scoring;
   m_slBufferATR = (slBufferATR > 0.0 ? slBufferATR : 0.25);
   m_minStopSpreadMult = (minStopSpreadMult >= 0.0 ? minStopSpreadMult : 3.0);
  }

void CTradeDecision::ApplyRuntimeParameters(const RuntimeParameters &parameters)
  {
   m_runtime = parameters;
   m_runtimeEnabled = true;
   m_fvgMaxDistATR = parameters.fvg_proximity_atr;
  }

double CTradeDecision::EnforceSpreadFloor(string symbol, double entry, double stopLoss, bool isBuy)
  {
   if(m_minStopSpreadMult <= 0.0) return stopLoss;
   long spreadPoints = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(spreadPoints <= 0 || point <= 0) return stopLoss;
   double minDist = spreadPoints * point * m_minStopSpreadMult;
   double curDist = MathAbs(entry - stopLoss);
   if(curDist >= minDist) return stopLoss;
   return isBuy ? (entry - minDist) : (entry + minDist);
  }

bool CTradeDecision::FindEntryFVG(ENUM_FVG_DIR dir, FVGZone &out)
  {
   if(m_fvgCtx == NULL || m_priceRef == NULL || m_priceRef.Total() == 0) return false;
   double price = m_priceRef.GetCandle(0).close;
   double atr = m_fvgCtx.candles.GetATR(0);
   if(atr <= 0) return false;

   for(int i = 0; i < m_fvgCtx.fvg.Count(); i++)
     {
      FVGZone z = m_fvgCtx.fvg.GetZone(i);
      if(z.dir != dir) continue;
      if(z.state != FVG_FRESH && z.state != FVG_TESTED) continue;
      double mid = (z.top + z.bottom) / 2.0;
      if(MathAbs(price - mid) / atr > m_fvgMaxDistATR) continue;
      out = z;
      return true;
     }
   return false;
  }

double CTradeDecision::RuntimeStrategyThreshold(const TradeSetup &setup)
  {
   if(!m_runtimeEnabled) return 60.0;
   double threshold = (double)m_runtime.ensemble_threshold;
   switch(setup.reasons.selected_strategy)
     {
      case STRATEGY_MOMENTUM_BREAKOUT:
         threshold = MathMax(threshold, (double)m_runtime.momentum_threshold);
         break;
      case STRATEGY_MEAN_REVERSION:
         threshold = MathMax(threshold, (double)m_runtime.mean_reversion_threshold);
         break;
      case STRATEGY_KEY_LEVEL:
         threshold = MathMax(threshold, (double)m_runtime.key_level_threshold);
         break;
      case STRATEGY_SMC:
         threshold = MathMax(threshold, (double)m_runtime.smc_threshold);
         break;
      default:
         threshold = MathMax(threshold, (double)m_runtime.smc_threshold);
         break;
     }
   return threshold;
  }

double CTradeDecision::RuntimeContradictionPenalty(const SetupReasons &r)
  {
   if(!m_runtimeEnabled) return 0.0;
   int hits = 0;
   if(!r.trend_aligned)               hits++;
   if(!r.premium_discount_ok)         hits++;
   if(!r.chase_ok)                    hits++;
   if(r.vol_regime == VOL_REGIME_LOW) hits++;
   if(!r.session_ok)                  hits++;
   if(r.news_risk != NEWS_NONE)       hits++;
   if(r.htf_ob_state == OB_MITIGATED) hits++;
   return MathMin((double)hits * m_runtime.contradiction_penalty, 1.0);
  }

void CTradeDecision::ApplyRuntimeOverlay(TradeSetup &setup)
  {
   if(!m_runtimeEnabled) return;

   bool forBuy = (setup.type == ORDER_TYPE_BUY);
   InducementResult ind = m_scoring.GetInducement(forBuy);
   if(!ind.valid || ind.bosBarIndex < 0 || ind.bosBarIndex > m_runtime.freshness_bars)
     {
      setup.active = false;
      return;
     }

   double contradiction = RuntimeContradictionPenalty(setup.reasons);
   setup.confidence *= (1.0 - contradiction);
   double required = RuntimeStrategyThreshold(setup);
   if(setup.confidence < required)
      setup.active = false;
  }

TradeSetup CTradeDecision::GenerateBuySetup()
  {
   TradeSetup setup;
   ZeroMemory(setup);
   if(m_priceRef == NULL || m_fvgCtx == NULL || m_scoring == NULL) return setup;
   double conf = m_scoring.CalculateConfidence(true);
   if(conf < 50.0) return setup;
   FVGZone entryFVG;
   if(!FindEntryFVG(FVG_BULL, entryFVG)) return setup;
   double atr = m_fvgCtx.candles.GetATR(0);
   if(atr <= 0) return setup;
   setup.type = ORDER_TYPE_BUY;
   setup.entry_top = entryFVG.top;
   setup.entry_bottom = entryFVG.bottom;
   setup.stop_loss = entryFVG.bottom - m_slBufferATR * atr;
   setup.stop_loss = EnforceSpreadFloor(m_priceRef.Symbol(), setup.entry_top, setup.stop_loss, true);
   CTargetSelector::AssignTargets(setup, m_liqCtx, m_priceRef.Symbol(), atr, setup.entry_bottom);
   setup.confidence = conf;
   setup.creation_time = TimeCurrent();
   setup.active = true;
   m_scoring.EvaluateReasons(true, setup.reasons);
   m_scoring.PopulateStrategyDiagnostics(true, setup.confidence, setup.reasons);
   ApplyRuntimeOverlay(setup);
   m_scoring.PopulateConfidenceDiagnostics(setup.reasons, setup.confidence);
   m_lastSetup = setup;
   return setup;
  }

TradeSetup CTradeDecision::GenerateSellSetup()
  {
   TradeSetup setup;
   ZeroMemory(setup);
   if(m_priceRef == NULL || m_fvgCtx == NULL || m_scoring == NULL) return setup;
   double conf = m_scoring.CalculateConfidence(false);
   if(conf < 50.0) return setup;
   FVGZone entryFVG;
   if(!FindEntryFVG(FVG_BEAR, entryFVG)) return setup;
   double atr = m_fvgCtx.candles.GetATR(0);
   if(atr <= 0) return setup;
   setup.type = ORDER_TYPE_SELL;
   setup.entry_top = entryFVG.top;
   setup.entry_bottom = entryFVG.bottom;
   setup.stop_loss = entryFVG.top + m_slBufferATR * atr;
   setup.stop_loss = EnforceSpreadFloor(m_priceRef.Symbol(), setup.entry_bottom, setup.stop_loss, false);
   CTargetSelector::AssignTargets(setup, m_liqCtx, m_priceRef.Symbol(), atr, setup.entry_top);
   setup.confidence = conf;
   setup.creation_time = TimeCurrent();
   setup.active = true;
   m_scoring.EvaluateReasons(false, setup.reasons);
   m_scoring.PopulateStrategyDiagnostics(false, setup.confidence, setup.reasons);
   ApplyRuntimeOverlay(setup);
   m_scoring.PopulateConfidenceDiagnostics(setup.reasons, setup.confidence);
   m_lastSetup = setup;
   return setup;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Trading/TradeZone.mqh ----

// ---- BEGIN EA/includes/Trading/RiskEngine.mqh ----
//+------------------------------------------------------------------+
//|                                              Trading/RiskEngine.mqh |
//+------------------------------------------------------------------+
#ifndef RISKENGINE_MQH
#define RISKENGINE_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Trading/TradeZone.mqh ----

// ---- END EA/includes/Trading/TradeZone.mqh ----

class CRiskEngine
  {
public:
   bool              ValidateSetup(TradeSetup &setup, double minRR, double maxSLDistanceATR, double currentATR);
   double            CalculateLotSize(string symbol, double riskPercent, double entry, double stopLoss,
                                      bool halveForReducedRisk, bool allowMinLotOverride, bool &exceededRiskBudget,
                                      double sizeMultiplier = 1.0); // RiskGuard's drawdown de-risk ramp — see Portfolio/RiskGuard.mqh
   double            RiskAmountForLots(string symbol, double lots, double entry, double stopLoss);
  };
//+------------------------------------------------------------------+
// NEW: nothing in v2.1 converted a validated setup into an actual lot
// size — risk was checked as a ratio (R:R, SL-in-ATR) but never turned
// into "how many lots does riskPercent of this account's equity buy at
// this stop distance". Required by the new Execution Engine; wasn't
// needed before because nothing placed real orders.
//
// FIXED: this used to clamp the result UP to the broker's minimum lot
// whenever riskPercent's true size fell below it — meaning a small
// account could silently risk more than InpRiskPercentPerTrade asked
// for, every single time it happened, with no signal that it had. The
// floor-rounding a few lines up exists specifically so this class never
// risks more than requested; clamping up at the far end quietly broke
// that same guarantee. Now: below broker minimum, the caller decides —
// reject the trade (default, and the only choice that keeps the risk%
// promise exact) or explicitly opt in to trading at min-lot anyway, in
// which case exceededRiskBudget tells the caller it happened so it can
// be logged, not silently absorbed.
double CRiskEngine::CalculateLotSize(string symbol, double riskPercent, double entry, double stopLoss,
                                     bool halveForReducedRisk, bool allowMinLotOverride, bool &exceededRiskBudget,
                                     double sizeMultiplier)
  {
   exceededRiskBudget = false;

   double slDistance = MathAbs(entry - stopLoss);
   if(slDistance <= 0) return 0.0;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (riskPercent / 100.0);
   if(halveForReducedRisk) riskAmount *= 0.5;
   riskAmount *= MathMax(0.0, MathMin(1.0, sizeMultiplier)); // RiskGuard drawdown ramp — 1.0 = no change

   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) return 0.0;

   double valuePerUnitDistance = tickValue / tickSize; // account-currency value of 1.0 price move, per lot
   double lossPerLot = slDistance * valuePerUnitDistance;
   if(lossPerLot <= 0) return 0.0;

   double rawLots = riskAmount / lossPerLot;

   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   double lots = rawLots;
   if(lotStep > 0)
      lots = MathFloor(lots / lotStep) * lotStep; // round DOWN — never risk more than requested to hit a round lot

   if(lots < minLot)
     {
      if(!allowMinLotOverride)
         return 0.0; // correctly rejected — riskPercent genuinely doesn't buy one broker-minimum lot here
      exceededRiskBudget = true; // caller opted in: this trade WILL risk more than riskPercent
      lots = minLot;
     }

   lots = MathMin(maxLot, lots);
   return lots;
  }
//+------------------------------------------------------------------+
// NEW: the Portfolio Manager needs to know "if I let this trade through,
// how many account-currency dollars does it put at risk" so it can sum
// that against every other open position under this magic number. This
// is exactly the loss-per-lot math CalculateLotSize already does,
// inverted — kept in one place so the two never drift out of sync.
double CRiskEngine::RiskAmountForLots(string symbol, double lots, double entry, double stopLoss)
  {
   double slDistance = MathAbs(entry - stopLoss);
   if(slDistance <= 0 || lots <= 0) return 0.0;

   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) return 0.0;

   double valuePerUnitDistance = tickValue / tickSize;
   return slDistance * valuePerUnitDistance * lots;
  }
//+------------------------------------------------------------------+
bool CRiskEngine::ValidateSetup(TradeSetup &setup, double minRR, double maxSLDistanceATR, double currentATR)
  {
   if(!setup.active) return false;
   // FIXED: this used to check R:R and the ATR-distance cap against
   // entry_bottom/entry_top — the *opposite*, more favorable edge of the
   // zone from what OrderManager::Submit() and OnTick()'s lot-sizing call
   // actually fill at. A setup could clear minRR/maxSLDistanceATR here on
   // paper and then execute at a real R:R below minRR / a real SL
   // distance beyond the cap, with nothing downstream catching it. Now
   // uses the same resolved entry as execution, via ResolveExecutionEntry()
   // (Core/Config.mqh) — one source of truth so this can't drift again.
   double entry = ResolveExecutionEntry(setup);
   double slDist = MathAbs(entry - setup.stop_loss);
   double tpDist = MathAbs(setup.tp1 - entry);
   if(slDist <= 0 || tpDist <= 0) return false;
   if(tpDist / slDist < minRR) return false;

   // FIX: maxSLDistanceATR was accepted as a parameter but never actually
   // checked against anything — a dead input that gave the impression of
   // risk control while doing nothing. Now it actually rejects setups
   // whose stop is unreasonably wide relative to current volatility.
   if(currentATR > 0)
     {
      double slDistATR = slDist / currentATR;
      if(slDistATR > maxSLDistanceATR) return false;
     }
   return true;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Trading/RiskEngine.mqh ----

// ---- BEGIN EA/includes/Trading/OutcomeTracker.mqh ----
//+------------------------------------------------------------------+
//|                                      Trading/OutcomeTracker.mqh   |
//+------------------------------------------------------------------+
#ifndef OUTCOMETRACKER_MQH
#define OUTCOMETRACKER_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Core/SignalLogger.mqh ----

// ---- END EA/includes/Core/SignalLogger.mqh ----


// ---- BEGIN EA/includes/Analysis/TFContext.mqh ----

// ---- END EA/includes/Analysis/TFContext.mqh ----


// ---- BEGIN EA/includes/Trading/RiskEngine.mqh ----

// ---- END EA/includes/Trading/RiskEngine.mqh ----


// ---- BEGIN EA/includes/Trading/CalibrationEngine.mqh ----
//+------------------------------------------------------------------+
//|                                    Trading/CalibrationEngine.mqh  |
//+------------------------------------------------------------------+
#ifndef CALIBRATIONENGINE_MQH
#define CALIBRATIONENGINE_MQH

// v2.9 addition — review item #1 / #9: "a confidence score isn't a
// probability until it's been checked against real outcomes." This
// bucket-tracks CScoringEngine::CalculateConfidence()'s output against
// COutcomeTracker's resolved win/loss verdicts and reports the ACTUAL
// historical win rate for each confidence range, persisted to a file so
// the sample survives restarts.
//
// HONEST LIMITATIONS — read before trusting the numbers this produces:
//  1. This does NOT change trading behavior on its own. Nothing in the
//     EA gates on calibrated probability yet — it is purely an
//     observability layer that answers "is an 80 actually an 80?" You
//     have to look at the numbers and decide what to do with them (e.g.
//     discover 90+ underperforms 80-89 and investigate why, per review
//     item #9). Wiring a live gate off this is a deliberate next step,
//     not something this file does implicitly.
//  2. Sample sizes below MIN_SAMPLE (default 30) per bucket are reported
//     but flagged low-confidence — with a live strategy this realistically
//     means MONTHS of forward/backtest data before any bucket's number
//     means anything. Don't trust a 5-trade bucket's win rate.
//  3. Buckets are fixed 5-point-wide bins from 0-100 (20 buckets). This
//     is a starting resolution, not a tuned one — too fine and you never
//     accumulate samples per bucket, too coarse and you can't see
//     structure like "90+ underperforms 80-89". Revisit once you have
//     real volume.
//  4. This tracks the RAW CalculateConfidence() output at the moment
//     AddSetup() logged the trade — if you change the scoring formula
//     (as the v2.9 sweep-grade/BOS-strength/decay changes in this same
//     release do), OLD calibration data no longer describes the NEW
//     score's meaning. Clear/reset the calibration file after any
//     scoring-formula change, or you'll be calibrating against a
//     confidence definition that no longer exists. See Reset().
//  5. Calibration is symbol-agnostic by construction (one file per
//     EA instance/symbol, same as OutcomeTracker's CSV) — a XAUUSD
//     bucket's win rate says nothing about EURUSD's. Don't share the
//     file across symbols.
class CCalibrationEngine
  {
private:
   static const int  NUM_BUCKETS = 20; // 0-5, 5-10, ..., 95-100
   int               m_wins[NUM_BUCKETS];
   int               m_losses[NUM_BUCKETS];
   int               m_scratches[NUM_BUCKETS];
   string            m_filename;
   int               m_minSample;

   int               BucketIndex(double confidence) const
     {
      int idx = (int)MathFloor(confidence / 5.0);
      return (int)MathMax(0, MathMin(idx, NUM_BUCKETS - 1));
     }

public:
                     CCalibrationEngine() : m_filename(""), m_minSample(30)
     {
      ArrayInitialize(m_wins, 0);
      ArrayInitialize(m_losses, 0);
      ArrayInitialize(m_scratches, 0);
     }

   void              Init(string symbol, int minSample = 30, bool useCommonFolder = false)
     {
      m_filename = "MedisTouch_Calibration_" + symbol + ".csv";
      m_minSample = MathMax(1, minSample);
      Load(useCommonFolder);
     }

   // Call once per resolved, sized (lots>0), non-ambiguous trade — see
   // COutcomeTracker::FinalizeExit() for the call site. netPnL > 0 counts
   // as a win, < 0 a loss, == 0 a scratch (matches OutcomeStats'
   // win/loss/scratch convention exactly, so this stays consistent with
   // the dashboard's headline win rate).
   void              Record(double confidence, double netPnL, bool useCommonFolder = false)
     {
      int b = BucketIndex(confidence);
      if(netPnL > 0.0000001)      m_wins[b]++;
      else if(netPnL < -0.0000001) m_losses[b]++;
      else                          m_scratches[b]++;
      Save(useCommonFolder); // flush every trade — this is low-frequency (one call per resolved trade), not per-tick
     }

   // Returns the empirical win rate for the bucket confidence falls
   // into, the sample size behind it, and whether that sample clears
   // m_minSample. hasEnoughData=false is not "no edge" — it's "don't
   // trust this number yet."
   double            GetCalibratedProbability(double confidence, int &sampleSizeOut, bool &hasEnoughDataOut) const
     {
      int b = BucketIndex(confidence);
      int w = m_wins[b], l = m_losses[b];
      int total = w + l; // scratches excluded from the win-rate denominator, same convention as OutcomeStats.WinRateExcludingAmbiguous()
      sampleSizeOut = total;
      hasEnoughDataOut = (total >= m_minSample);
      if(total == 0) return 0.0;
      return 100.0 * w / total;
     }

   // Whole-curve dump for the dashboard/CSV export — one row per bucket,
   // "" for the string return means "print this yourself", kept simple
   // rather than building a UI dependency into this file.
   string            BucketSummary(int bucketIdx) const
     {
      if(bucketIdx < 0 || bucketIdx >= NUM_BUCKETS) return "";
      int lo = bucketIdx * 5, hi = lo + 5;
      int w = m_wins[bucketIdx], l = m_losses[bucketIdx], s = m_scratches[bucketIdx];
      int total = w + l;
      double wr = (total > 0) ? (100.0 * w / total) : 0.0;
      return StringFormat("%d-%d: %d trades, %.1f%% win rate%s", lo, hi, total, wr,
                           (total < m_minSample) ? " (low sample)" : "");
     }
   int               NumBuckets() const { return NUM_BUCKETS; }

   // v2.9 note #4 above — call this after any scoring-formula change so
   // stale-definition data doesn't masquerade as current calibration.
   void              Reset(bool useCommonFolder = false)
     {
      ArrayInitialize(m_wins, 0);
      ArrayInitialize(m_losses, 0);
      ArrayInitialize(m_scratches, 0);
      Save(useCommonFolder);
     }

   void              Save(bool useCommonFolder = false)
     {
      if(StringLen(m_filename) == 0) return;
      int flags = FILE_CSV | FILE_WRITE | FILE_ANSI;
      if(useCommonFolder) flags |= FILE_COMMON;
      int h = FileOpen(m_filename, flags, ',');
      if(h == INVALID_HANDLE) return;
      FileWrite(h, "BucketLow", "BucketHigh", "Wins", "Losses", "Scratches");
      for(int i = 0; i < NUM_BUCKETS; i++)
         FileWrite(h, i * 5, i * 5 + 5, m_wins[i], m_losses[i], m_scratches[i]);
      FileClose(h);
     }

   bool              Load(bool useCommonFolder = false)
     {
      if(StringLen(m_filename) == 0) return false;
      int flags = FILE_CSV | FILE_READ | FILE_SHARE_READ | FILE_ANSI;
      if(useCommonFolder) flags |= FILE_COMMON;
      int h = FileOpen(m_filename, flags, ',');
      if(h == INVALID_HANDLE) return false; // no prior file — fresh start, not an error

      // header row
      for(int c = 0; c < 5 && !FileIsEnding(h); c++) FileReadString(h);

      int i = 0;
      while(!FileIsEnding(h) && i < NUM_BUCKETS)
        {
         string loS = FileReadString(h);
         if(FileIsEnding(h)) break;
         FileReadString(h); // hi, unused (derivable from index)
         string wS = FileReadString(h);
         string lS = FileReadString(h);
         string sS = FileReadString(h);
         m_wins[i] = (int)StringToInteger(wS);
         m_losses[i] = (int)StringToInteger(lS);
         m_scratches[i] = (int)StringToInteger(sS);
         i++;
        }
      FileClose(h);
      return true;
     }
  };
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Trading/CalibrationEngine.mqh ----

// v2.11 — optional publisher hook so a resolved/no-fill setup can be
// POSTed to the bridge (POST /outcome) right alongside the existing
// local-CSV LogOutcome() call. Include-guarded, so it's harmless that
// the main .mq5 also includes this later for g_publisher itself.

// ---- BEGIN EA/includes/Signals/SignalPublisher.mqh ----
//+------------------------------------------------------------------+
//|                                     Signals/SignalPublisher.mqh   |
//+------------------------------------------------------------------+
#ifndef SIGNALPUBLISHER_MQH
#define SIGNALPUBLISHER_MQH

// ---- BEGIN EA/includes/Decision/TradeDecision.mqh ----
//+------------------------------------------------------------------+
//|                                       Decision/TradeDecision.mqh |
//|  Shared record types for the analysis -> decision -> action seam. |
//+------------------------------------------------------------------+
// This header holds ONLY data types (no engines), because three layers
// need them and none of them should depend on each other:
//   * CDecisionEngine  produces a TradeDecisionRecord from a TradeSetup
//   * COrderManager / CSignalPublisher consume it
//   * CDecisionStore   persists it (and ExecutionRecord) so a restarted
//     terminal can be reconciled against broker-side truth by
//     CRecoveryEngine.
#ifndef TRADEDECISION_MQH
#define TRADEDECISION_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----

// What the router decided to DO with a validated setup. Execution and
// signalling are independent switches, so the combined case is its own
// value rather than a bitmask - every consumer compares against explicit
// values and a bitmask would silently pass `& POLICY_EXECUTE_ONLY` tests
// for the combined case in some places but not others.
enum ENUM_TRADE_POLICY
  {
   POLICY_IGNORE = 0,            // do nothing (below thresholds, or both switches off)
   POLICY_SIGNAL_ONLY,           // publish to subscribers, place no order
   POLICY_EXECUTE_ONLY,          // place the order, publish nothing
   POLICY_EXECUTE_AND_SIGNAL     // both
  };

string TradePolicyToString(ENUM_TRADE_POLICY p)
  {
   switch(p)
     {
      case POLICY_SIGNAL_ONLY:        return "SIGNAL_ONLY";
      case POLICY_EXECUTE_ONLY:       return "EXECUTE_ONLY";
      case POLICY_EXECUTE_AND_SIGNAL: return "EXECUTE_AND_SIGNAL";
      default:                        return "IGNORE";
     }
  }

// One routed decision. `setup` is copied by value on purpose: the setup
// object in the analysis layer is regenerated every bar, while a decision
// must stay immutable for the whole life of the trade it created (Recovery
// re-reads it after a restart, possibly days later).
struct TradeDecisionRecord
  {
   long              decision_id;     // matching key; also written into the order comment as "MT#<id>"
   string            symbol;
   TradeSetup        setup;           // the exact setup that was approved
   ENUM_TRADE_POLICY action;
   bool              reduce_risk;     // confidence below InpFullRiskConfidence -> size down
   bool              valid;           // false = the router rejected it; nothing downstream should act
   double            confidence;      // copy of setup.confidence at decision time (setup may be re-scored later)
   double            spread_points;   // spread observed when the decision was taken, for post-hoc analysis
   datetime          decided_time;
   string            reason;          // human-readable why, mirrored into the CSV store
  };

// Written when (and only when) an order actually reached the broker, so
// Recovery can tell "decision existed" from "decision was submitted at
// this volume on this ticket".
struct ExecutionRecord
  {
   long              decision_id;
   double            volume;
   ulong             ticket;
   datetime          submitted_time;
  };

#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Decision/TradeDecision.mqh ----


// ---- BEGIN EA/includes/Signals/SubscriberPlatform.mqh ----
//+------------------------------------------------------------------+
//|                                   Signals/SubscriberPlatform.mqh |
//+------------------------------------------------------------------+
#ifndef SUBSCRIBERPLATFORM_MQH
#define SUBSCRIBERPLATFORM_MQH

// Subscriber registry + delivery bookkeeping for the Signal Distribution
// Engine. Deliberately file-based and hand-editable rather than a UI:
// MQL5 has no admin panel to build one without a much bigger investment
// (a web dashboard talking to this over HTTP), and a flat CSV a human —
// or a future admin tool — edits directly is enough to unblock "actually
// send signals to real subscribers" today.
//
// File format, "MedisTouch_Subscribers.csv" (ACCOUNT-WIDE, not
// per-symbol — one subscriber list serves every symbol this EA runs on):
//   SubscriberID, Name, Tier, Endpoint, Active
// Tier is a free-text label (e.g. "FREE", "PRO") — CSignalPublisher
// decides what tier sees what; this class only stores and serves the
// registry, it doesn't gate content by tier itself.
struct Subscriber
  {
   string            id;
   string            name;
   string            tier;
   string            endpoint;
   bool              active;
  };

class CSubscriberPlatform
  {
private:
   string            m_subsFilename;
   string            m_deliveryFilename;
   int               m_deliveryFileHandle;
   Subscriber        m_subscribers[];

   void              LoadSubscribers();

public:
   void              Init();
   void              Deinit();
   void              Reload(); // re-read the subscriber file on demand — it's hand-edited, not written by this class
   int               GetActiveSubscribers(Subscriber &out[]);
   int               GetActiveSubscribers(string tierFilter, Subscriber &out[]); // "" = all tiers
   void              RecordDelivery(string subscriberId, long decisionId, bool success);
   int               Count() { return ArraySize(m_subscribers); }
  };
//+------------------------------------------------------------------+
void CSubscriberPlatform::Init()
  {
   m_subsFilename = "MedisTouch_Subscribers.csv";
   m_deliveryFilename = "MedisTouch_Deliveries.csv";
   LoadSubscribers();

   bool exists = FileIsExist(m_deliveryFilename);
   m_deliveryFileHandle = FileOpen(m_deliveryFilename, FILE_READ | FILE_WRITE | FILE_CSV, ',');
   if(m_deliveryFileHandle == INVALID_HANDLE)
      Print("MedisTouch SubscriberPlatform: could not open ", m_deliveryFilename);
   else if(!exists)
     {
      FileWrite(m_deliveryFileHandle, "SubscriberID", "DecisionID", "Success", "Time");
      FileFlush(m_deliveryFileHandle);
     }
  }
//+------------------------------------------------------------------+
void CSubscriberPlatform::LoadSubscribers()
  {
   ArrayResize(m_subscribers, 0);
   if(!FileIsExist(m_subsFilename))
     {
      // Ship an empty-but-present file with a header so the format is
      // discoverable without documentation. First run, zero subscribers,
      // Publish() below just has nothing to iterate — that's correct.
      int h = FileOpen(m_subsFilename, FILE_WRITE | FILE_CSV, ',');
      if(h != INVALID_HANDLE)
        {
         FileWrite(h, "SubscriberID", "Name", "Tier", "Endpoint", "Active");
         FileClose(h);
        }
      return;
     }

   int handle = FileOpen(m_subsFilename, FILE_READ | FILE_CSV, ',');
   if(handle == INVALID_HANDLE)
     {
      Print("MedisTouch SubscriberPlatform: could not open ", m_subsFilename);
      return;
     }

   if(!FileIsEnding(handle))
      for(int c = 0; c < 5 && !FileIsEnding(handle); c++)
         FileReadString(handle); // skip header row

   int n = 0;
   while(!FileIsEnding(handle))
     {
      string id = FileReadString(handle);
      if(StringLen(id) == 0 && FileIsEnding(handle)) break; // trailing blank line guard

      Subscriber s;
      s.id       = id;
      s.name     = FileReadString(handle);
      s.tier     = FileReadString(handle);
      s.endpoint = FileReadString(handle);
      string activeStr = FileReadString(handle);
      s.active = (activeStr == "1" || activeStr == "true" || activeStr == "TRUE");

      ArrayResize(m_subscribers, n + 1);
      m_subscribers[n++] = s;
     }
   FileClose(handle);
   PrintFormat("MedisTouch SubscriberPlatform: loaded %d subscriber(s) from %s.", n, m_subsFilename);
  }
//+------------------------------------------------------------------+
void CSubscriberPlatform::Reload() { LoadSubscribers(); }
//+------------------------------------------------------------------+
void CSubscriberPlatform::Deinit()
  {
   if(m_deliveryFileHandle != INVALID_HANDLE) FileClose(m_deliveryFileHandle);
  }
//+------------------------------------------------------------------+
int CSubscriberPlatform::GetActiveSubscribers(Subscriber &out[])
  {
   return GetActiveSubscribers("", out);
  }
//+------------------------------------------------------------------+
int CSubscriberPlatform::GetActiveSubscribers(string tierFilter, Subscriber &out[])
  {
   ArrayResize(out, 0);
   int n = 0;
   for(int i = 0; i < ArraySize(m_subscribers); i++)
     {
      if(!m_subscribers[i].active) continue;
      if(tierFilter != "" && m_subscribers[i].tier != tierFilter) continue;
      ArrayResize(out, n + 1);
      out[n++] = m_subscribers[i];
     }
   return n;
  }
//+------------------------------------------------------------------+
void CSubscriberPlatform::RecordDelivery(string subscriberId, long decisionId, bool success)
  {
   if(m_deliveryFileHandle == INVALID_HANDLE) return;
   FileSeek(m_deliveryFileHandle, 0, SEEK_END);
   FileWrite(m_deliveryFileHandle, subscriberId, decisionId, success ? 1 : 0,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
   FileFlush(m_deliveryFileHandle);
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Signals/SubscriberPlatform.mqh ----


// ---- BEGIN EA/includes/Core/PipCalculator.mqh ----

// ---- END EA/includes/Core/PipCalculator.mqh ----

// Publish/format/dedup/transport side of the Signal Distribution Engine.
//
// TRANSPORT IS NOW REAL: TransmitOne() calls WebRequest() against each
// active subscriber's endpoint from CSubscriberPlatform. Two things this
// genuinely cannot do for you, both one-time manual setup outside this
// file, not a code gap:
//   1. Every domain you publish to must be added under Tools > Options >
//      Expert Advisors > "Allow WebRequest for listed URL" in the
//      running terminal. WebRequest() fails immediately (returns -1,
//      GetLastError() 4060) against anything not on that list — an MT5
//      platform restriction, not something an EA can configure around
//      from inside itself.
//   2. Endpoints are whatever "MedisTouch_Subscribers.csv" defines via
//      CSubscriberPlatform — populate it with real subscriber endpoints
//      before anything gets delivered. An empty file means Publish()
//      still runs and still logs to the local feed, it just has nobody
//      to send to.
class CSignalPublisher
  {
private:
   string               m_filename;
   int                  m_fileHandle;
   long                 m_lastPublishedId;
   CSubscriberPlatform* m_platform;
   int                  m_timeoutMs;
   string               m_apiKey;    // sent as X-API-Key on every POST — must match telegram-bridge's SECRET_KEY
   // v2.11 — InpWeightSetVersion, mirrored here so BuildJsonPayload() and
   // BuildOutcomeJsonPayload() can both stamp every signal/outcome with
   // which scoring weight set produced it. Set once via SetWeightVersion()
   // after Init(); "" (default) is a valid, honest value meaning
   // "not configured" — it round-trips to the bridge as an empty string,
   // not a fabricated label.
   string               m_weightVersion;

   bool                 TransmitOne(string endpoint, const string &payload);
   bool                 TransmitOnePatch(string endpoint, const string &payload);
   string               BuildJsonPayload(const TradeDecisionRecord &dec);
   string               BuildReasonsJsonArray(const SetupReasons &r);
   string               BuildExtraJson(const TradeDecisionRecord &dec);
   string               SignalIdFor(long decisionId);
   // v2.11
   string               BuildOutcomeJsonPayload(string signalId, string symbol, string direction,
                                                 string outcome, double realizedR, double mfeR, double maeR,
                                                 int barsHeld, int barsToFill, bool filled,
                                                 string regime, string session, string sweepGrade,
                                                 bool htfObAligned, double confidenceAtSignal,
                                                 double confidenceDecayed, int decayBars);

public:
   void                 Init(string symbol, CSubscriberPlatform* platform, int timeoutMs = 5000, string apiKey = "");
   void                 Deinit();
   bool                 Publish(const TradeDecisionRecord &dec);
   // v2.9. Pushes a STALE/EXPIRED/INVALIDATED transition for a
   // previously-published decision. Fans out to the same subscriber
   // endpoints Publish() used, PATCHing "<endpoint-with-/signal-stripped>
   // /signal/<signal_id>/status" — this assumes each subscriber endpoint
   // ends in "/signal" (true for the current bridge deployment); if a
   // subscriber's endpoint doesn't follow that convention the PATCH for
   // that one subscriber is skipped (logged), not silently malformed.
   bool                 PublishStatusUpdate(long decisionId, string status, string reason);
   // v2.11. See OutcomeTracker.mqh ConfigurePublishing()/FinalizeExit()/
   // Resolve() for the call sites. Posts to "<subscriber endpoint with
   // trailing /signal stripped>/outcome" — same endpoint-shape assumption
   // PublishStatusUpdate() already makes, for the same reason (one bridge
   // deployment, one base URL). Fans out to every active subscriber
   // exactly like Publish()/PublishStatusUpdate() do; returns true if at
   // least one succeeded.
   bool                 PublishOutcome(string signalId, string symbol, string direction, string outcome,
                                        double realizedR, double mfeR, double maeR, int barsHeld,
                                        int barsToFill, bool filled, string regime, string session,
                                        string sweepGrade, bool htfObAligned, double confidenceAtSignal,
                                        double confidenceDecayed, int decayBars);
   void                 SetWeightVersion(string v) { m_weightVersion = v; }
   // v2.11. Public wrapper so callers outside this class (OutcomeTracker,
   // building the signal_id an outcome must attach to) use the exact same
   // convention as Publish() itself, rather than duplicating the "MT#"
   // format string in a second place where it could silently drift.
   string               SignalIdForDecision(long decisionId) { return SignalIdFor(decisionId); }
  };
//+------------------------------------------------------------------+
void CSignalPublisher::Init(string symbol, CSubscriberPlatform* platform, int timeoutMs, string apiKey)
  {
   m_lastPublishedId = 0;
   m_platform = platform;
   m_timeoutMs = timeoutMs;
   m_apiKey = apiKey;
   m_weightVersion = "";
   if(StringLen(m_apiKey) == 0)
      Print("MedisTouch SignalPublisher: InpBridgeApiKey is blank — every WebRequest to the bridge will be ",
            "rejected with HTTP 401 until it's set to match the backend's SECRET_KEY.");
   m_filename = "MedisTouch_SignalFeed_" + symbol + ".csv";
   bool exists = FileIsExist(m_filename);
   m_fileHandle = FileOpen(m_filename, FILE_READ | FILE_WRITE | FILE_CSV, ',');
   if(m_fileHandle == INVALID_HANDLE)
     {
      Print("MedisTouch SignalPublisher: could not open ", m_filename);
      return;
     }
   FileSeek(m_fileHandle, 0, SEEK_END);
   if(!exists)
      FileWrite(m_fileHandle, "DecisionID", "Time", "Symbol", "Direction", "Entry", "SL", "TP1", "TP2", "FinalTP",
                "Confidence", "Action", "SubscribersTargeted", "SubscribersDelivered");
  }
//+------------------------------------------------------------------+
void CSignalPublisher::Deinit()
  {
   if(m_fileHandle != INVALID_HANDLE) FileClose(m_fileHandle);
  }
//+------------------------------------------------------------------+
string CSignalPublisher::SignalIdFor(long decisionId)
  {
   // Matches the order-comment convention documented on
   // TradeDecisionRecord.decision_id ("MT#<id>") so a fill's comment and
   // its originating signal_id are trivially correlatable by eye.
   return "MT#" + IntegerToString(decisionId);
  }
//+------------------------------------------------------------------+
// v2.9. The bridge's SignalRequest schema requires signal_id (string),
// reasons (list[str], min 1 item), and timeframe — none of which the
// old payload sent. That's not a v2.9 regression; BuildJsonPayload
// never matched the schema it was posting against. Every field below is
// either newly added to close that gap (signal_id/reasons/timeframe) or
// was already correct and is unchanged (entry/sl/tp1/tp2/confidence).
string CSignalPublisher::BuildReasonsJsonArray(const SetupReasons &r)
  {
   string items[];
   int n = 0;
   #define MT_ADD_REASON(cond, txt) if(cond) { ArrayResize(items, n + 1); items[n++] = txt; }
   MT_ADD_REASON(r.trend_aligned,        "HTF trend aligned")
   MT_ADD_REASON(r.inducement_valid,     "Inducement sequence confirmed")
   MT_ADD_REASON(r.liquidity_swept,      "Liquidity swept")
   MT_ADD_REASON(r.bos_confirmed,        "BOS confirmed")
   MT_ADD_REASON(r.fresh_fvg,            "Fresh FVG in zone")
   MT_ADD_REASON(r.sr_confluence,        "S/R confluence")
   MT_ADD_REASON(r.premium_discount_ok,  "Premium/discount location OK")
   MT_ADD_REASON(r.volume_confirmed,     "Volume confirmed")
   MT_ADD_REASON(r.fib_in_zone,          "Fibonacci zone confluence")
   MT_ADD_REASON(r.value_area_ok,        "Value area location OK")
   MT_ADD_REASON(r.htf_ob_confluence,    "HTF order block confluence")
   #undef MT_ADD_REASON
   if(n == 0) { ArrayResize(items, 1); items[0] = "Confluence-based setup"; n = 1; } // schema requires min_length=1

   string json = "[";
   for(int i = 0; i < n; i++)
     {
      string esc = items[i];
      StringReplace(esc, "\"", "'");
      json += "\"" + esc + "\"";
      if(i < n - 1) json += ",";
     }
   json += "]";
   return json;
  }
//+------------------------------------------------------------------+
// v2.9. Everything from the review that's display-only diagnostic data,
// not required by the bridge schema — see routes.py:SignalRequest.extra
// and formatter.py's graceful-degradation handling if any key here is
// absent or this whole object is omitted.
string CSignalPublisher::BuildExtraJson(const TradeDecisionRecord &dec)
  {
   SetupReasons r = dec.setup.reasons;
   string symbol = dec.symbol;
   double pip = CPipCalculator::PipSize(symbol);
   bool isBuy = (dec.setup.type == ORDER_TYPE_BUY);
   double entry = isBuy ? dec.setup.entry_top : dec.setup.entry_bottom;

   double pipsSl  = (pip > 0) ? MathAbs(entry - dec.setup.stop_loss) / pip : 0.0;
   double pipsTp1 = (pip > 0) ? MathAbs(dec.setup.tp1 - entry) / pip : 0.0;
   double pipsTp2 = (pip > 0) ? MathAbs(dec.setup.tp2 - entry) / pip : 0.0;
   double rrTp1 = (pipsSl > 0) ? pipsTp1 / pipsSl : 0.0;
   double rrTp2 = (pipsSl > 0) ? pipsTp2 / pipsSl : 0.0;

   string sweepGradeStr = EnumToString(r.sweep_grade);
   string newsRiskStr = EnumToString(r.news_risk);

   return StringFormat(
      "{\"pips_sl\":%.1f,\"pips_tp1\":%.1f,\"pips_tp2\":%.1f,\"rr_tp1\":%.2f,\"rr_tp2\":%.2f,"
      "\"sweep_grade\":\"%s\",\"bos_strength\":%.1f,\"time_decay\":%.1f,"
      "\"chase_dist_atr\":%.2f,\"chase_ok\":%s,"
      "\"news_risk\":\"%s\",\"news_label\":\"%s\",\"news_minutes_to_event\":%d,"
      "\"calibrated_probability\":%.1f,\"calibration_sample\":%d,\"calibration_has_enough_data\":%s}",
      pipsSl, pipsTp1, pipsTp2, rrTp1, rrTp2,
      sweepGradeStr, r.bos_strength * 100.0, r.time_decay * 100.0,
      r.chase_dist_atr, r.chase_ok ? "true" : "false",
      newsRiskStr, r.news_label, r.news_minutes_to_event,
      dec.setup.calibrated_probability, dec.setup.calibration_sample,
      dec.setup.calibration_has_enough_data ? "true" : "false");
  }
//+------------------------------------------------------------------+
string CSignalPublisher::BuildJsonPayload(const TradeDecisionRecord &dec)
  {
   bool isBuy = (dec.setup.type == ORDER_TYPE_BUY);
   double entry = isBuy ? dec.setup.entry_top : dec.setup.entry_bottom;
   string dir = isBuy ? "BUY" : "SELL";
   string tf = EnumToString((ENUM_TIMEFRAMES)Period());
   StringReplace(tf, "PERIOD_", ""); // EnumToString gives "PERIOD_M15"; schema's VALID_TIMEFRAMES wants "M15"

   // v2.11 — promoted out of BuildExtraJson's blob into top-level fields
   // (routes.py:SignalRequest.regime/session/sweep_grade/htf_ob_aligned)
   // so they land in indexed Signal columns, not buried JSON. sweep_grade
   // is intentionally sent BOTH here (structured) and inside extra
   // (existing dashboards/formatter.py read it from extra — leaving that
   // alone avoids a second coordinated change there).
   SetupReasons r = dec.setup.reasons;
   string regimeStr = EnumToString(r.vol_regime);
   string sessionStr = EnumToString(r.session);
   string sweepGradeStr = EnumToString(r.sweep_grade);

   return StringFormat(
      "{\"signal_id\":\"%s\",\"decision_id\":%d,\"symbol\":\"%s\",\"direction\":\"%s\",\"entry\":%.5f,\"sl\":%.5f,"
      "\"tp1\":%.5f,\"tp2\":%.5f,\"final_tp\":%.5f,\"confidence\":%.1f,\"reasons\":%s,\"timeframe\":\"%s\","
      "\"time\":\"%s\",\"regime\":\"%s\",\"session\":\"%s\",\"sweep_grade\":\"%s\",\"htf_ob_aligned\":%s,"
      "\"weight_version\":\"%s\",\"extra\":%s}",
      SignalIdFor(dec.decision_id), dec.decision_id, dec.symbol, dir, entry, dec.setup.stop_loss,
      dec.setup.tp1, dec.setup.tp2, dec.setup.final_tp, dec.setup.confidence,
      BuildReasonsJsonArray(dec.setup.reasons), tf,
      TimeToString(dec.decided_time, TIME_DATE | TIME_SECONDS),
      regimeStr, sessionStr, sweepGradeStr, r.htf_ob_confluence ? "true" : "false",
      m_weightVersion, BuildExtraJson(dec));
  }
//+------------------------------------------------------------------+
bool CSignalPublisher::TransmitOne(string endpoint, const string &payload)
  {
   // StringToCharArray() fills a uchar[] array; WebRequest()'s data
   // parameter is declared char[] — these are distinct array types in
   // MQL5 and a reference parameter won't implicitly convert between
   // them, so building straight into a char[] and handing it to
   // StringToCharArray would fail to compile. Build into uchar[] first,
   // then ArrayCopy() into the char[] WebRequest actually wants —
   // ArrayCopy() performs the element-wise cast, a plain assignment
   // would not.
   uchar rawData[];
   int len = StringToCharArray(payload, rawData) - 1; // trim the trailing null StringToCharArray appends
   if(len < 0) len = 0;
   ArrayResize(rawData, len);

   char data[];
   ArrayResize(data, len);
   ArrayCopy(data, rawData);

   char result[];
   string resultHeaders;
   // X-API-Key is mandatory server-side (verify_api_key in routes.py has
   // no default) - every POST without it gets a 401 before the payload
   // is even validated. Concatenated as its own CRLF-terminated header
   // line per HTTP semantics; WebRequest() takes the whole header block
   // as one string.
   string headers = "Content-Type: application/json\r\n";
   if(StringLen(m_apiKey) > 0)
      headers += "X-API-Key: " + m_apiKey + "\r\n";

   ResetLastError();
   int status = WebRequest("POST", endpoint, headers, m_timeoutMs, data, result, resultHeaders);
   if(status == -1)
     {
      int err = GetLastError();
      if(err == 4060)
         PrintFormat("MedisTouch SignalPublisher: WebRequest blocked for %s — add it under Tools > Options > Expert Advisors > Allow WebRequest for listed URL.",
                     endpoint);
      else
         PrintFormat("MedisTouch SignalPublisher: WebRequest to %s failed, error %d.", endpoint, err);
      return false;
     }
   if(status < 200 || status >= 300)
     {
      PrintFormat("MedisTouch SignalPublisher: %s responded with HTTP %d.", endpoint, status);
      return false;
     }
   return true;
  }
//+------------------------------------------------------------------+
// v2.9. Same body as TransmitOne except the HTTP verb — WebRequest()
// takes the method as its first string argument, so this is the
// smallest correct duplication rather than a boolean flag threaded
// through the existing method (which already has enough parameters).
bool CSignalPublisher::TransmitOnePatch(string endpoint, const string &payload)
  {
   uchar rawData[];
   int len = StringToCharArray(payload, rawData) - 1;
   if(len < 0) len = 0;
   ArrayResize(rawData, len);

   char data[];
   ArrayResize(data, len);
   ArrayCopy(data, rawData);

   char result[];
   string resultHeaders;
   string headers = "Content-Type: application/json\r\n";
   if(StringLen(m_apiKey) > 0)
      headers += "X-API-Key: " + m_apiKey + "\r\n";

   ResetLastError();
   int status = WebRequest("PATCH", endpoint, headers, m_timeoutMs, data, result, resultHeaders);
   if(status == -1)
     {
      PrintFormat("MedisTouch SignalPublisher: lifecycle PATCH to %s failed, error %d.", endpoint, GetLastError());
      return false;
     }
   if(status < 200 || status >= 300)
     {
      PrintFormat("MedisTouch SignalPublisher: lifecycle PATCH %s responded with HTTP %d.", endpoint, status);
      return false;
     }
   return true;
  }
//+------------------------------------------------------------------+
bool CSignalPublisher::Publish(const TradeDecisionRecord &dec)
  {
   if(dec.action != POLICY_SIGNAL_ONLY && dec.action != POLICY_EXECUTE_AND_SIGNAL) return false;
   if(dec.decision_id == m_lastPublishedId) return false; // dedup against re-publishing the same decision
   if(m_fileHandle == INVALID_HANDLE) return false;

   bool isBuy = (dec.setup.type == ORDER_TYPE_BUY);
   double entry = isBuy ? dec.setup.entry_top : dec.setup.entry_bottom;
   string dir = isBuy ? "BUY" : "SELL";
   string payload = BuildJsonPayload(dec);

   int targeted = 0;
   int delivered = 0;

   if(m_platform != NULL)
     {
      Subscriber subs[];
      targeted = m_platform.GetActiveSubscribers(subs);
      for(int i = 0; i < targeted; i++)
        {
         bool ok = TransmitOne(subs[i].endpoint, payload);
         if(ok) delivered++;
         m_platform.RecordDelivery(subs[i].id, dec.decision_id, ok);
        }
     }

   FileWrite(m_fileHandle, dec.decision_id, TimeToString(dec.decided_time, TIME_DATE | TIME_MINUTES), dec.symbol,
             dir, entry, dec.setup.stop_loss, dec.setup.tp1, dec.setup.tp2, dec.setup.final_tp,
             dec.setup.confidence, EnumToString(dec.action), targeted, delivered);
   FileFlush(m_fileHandle);

   m_lastPublishedId = dec.decision_id;
   return true;
  }
//+------------------------------------------------------------------+
bool CSignalPublisher::PublishStatusUpdate(long decisionId, string status, string reason)
  {
   if(m_platform == NULL) return false;
   string signalId = SignalIdFor(decisionId);
   string escReason = reason;
   StringReplace(escReason, "\"", "'");
   string payload = StringFormat("{\"status\":\"%s\",\"reason\":\"%s\"}", status, escReason);

   Subscriber subs[];
   int targeted = m_platform.GetActiveSubscribers(subs);
   bool anyOk = false;
   for(int i = 0; i < targeted; i++)
     {
      string endpoint = subs[i].endpoint;
      int pos = StringFind(endpoint, "/signal");
      if(pos < 0)
        {
         PrintFormat("MedisTouch SignalPublisher: subscriber endpoint %s doesn't end in /signal — skipping lifecycle PATCH for it.", endpoint);
         continue;
        }
      string patchUrl = StringSubstr(endpoint, 0, pos) + "/signal/" + signalId + "/status";
      if(TransmitOnePatch(patchUrl, payload)) anyOk = true;
     }
   return anyOk;
  }
//+------------------------------------------------------------------+
// v2.11. Matches routes.py:OutcomeRequest exactly — field-for-field. If
// that schema ever changes, this is the other half of the contract.
string CSignalPublisher::BuildOutcomeJsonPayload(string signalId, string symbol, string direction,
                                                  string outcome, double realizedR, double mfeR, double maeR,
                                                  int barsHeld, int barsToFill, bool filled,
                                                  string regime, string session, string sweepGrade,
                                                  bool htfObAligned, double confidenceAtSignal,
                                                  double confidenceDecayed, int decayBars)
  {
   // realized_r/mfe_r/mae_r are Optional[float] server-side; "null" (not
   // 0.0) for the no_fill/ambiguous cases where they're not meaningful —
   // a real 0.0 R-multiple is a legitimate scratch outcome and must stay
   // distinguishable from "not applicable" in the expectancy metrics.
   bool hasR = (outcome != "no_fill" && outcome != "ambiguous");
   string realizedRStr = hasR ? StringFormat("%.4f", realizedR) : "null";
   string mfeRStr = hasR ? StringFormat("%.4f", mfeR) : "null";
   string maeRStr = hasR ? StringFormat("%.4f", maeR) : "null";

   return StringFormat(
      "{\"signal_id\":\"%s\",\"symbol\":\"%s\",\"direction\":\"%s\",\"outcome\":\"%s\","
      "\"realized_r\":%s,\"mfe_r\":%s,\"mae_r\":%s,\"bars_held\":%d,\"bars_to_fill\":%d,\"filled\":%s,"
      "\"regime\":\"%s\",\"session\":\"%s\",\"sweep_grade\":\"%s\",\"htf_ob_aligned\":%s,"
      "\"weight_version\":\"%s\",\"confidence_at_signal\":%.2f,\"confidence_decayed\":%.2f,\"decay_bars\":%d}",
      signalId, symbol, direction, outcome,
      realizedRStr, mfeRStr, maeRStr, barsHeld, barsToFill, filled ? "true" : "false",
      regime, session, sweepGrade, htfObAligned ? "true" : "false",
      m_weightVersion, confidenceAtSignal, confidenceDecayed, decayBars);
  }
//+------------------------------------------------------------------+
bool CSignalPublisher::PublishOutcome(string signalId, string symbol, string direction, string outcome,
                                       double realizedR, double mfeR, double maeR, int barsHeld,
                                       int barsToFill, bool filled, string regime, string session,
                                       string sweepGrade, bool htfObAligned, double confidenceAtSignal,
                                       double confidenceDecayed, int decayBars)
  {
   if(m_platform == NULL) return false;
   string payload = BuildOutcomeJsonPayload(signalId, symbol, direction, outcome, realizedR, mfeR, maeR,
                                             barsHeld, barsToFill, filled, regime, session, sweepGrade,
                                             htfObAligned, confidenceAtSignal, confidenceDecayed, decayBars);

   Subscriber subs[];
   int targeted = m_platform.GetActiveSubscribers(subs);
   bool anyOk = false;
   for(int i = 0; i < targeted; i++)
     {
      // Same endpoint-shape assumption as PublishStatusUpdate() —
      // "<base>/signal" rewritten to "<base>/outcome" — see that
      // function's comment for what happens when a subscriber's
      // endpoint doesn't follow it.
      string endpoint = subs[i].endpoint;
      int pos = StringFind(endpoint, "/signal");
      if(pos < 0)
        {
         PrintFormat("MedisTouch SignalPublisher: subscriber endpoint %s doesn't end in /signal — skipping outcome POST for it.", endpoint);
         continue;
        }
      string outcomeUrl = StringSubstr(endpoint, 0, pos) + "/outcome";
      if(TransmitOne(outcomeUrl, payload)) anyOk = true;
     }
   return anyOk;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Signals/SignalPublisher.mqh ----

// SCOPE / HONEST LIMITATIONS — read before trusting the numbers this
// produces:
//  1. Tracking is fill-confirmed: a setup sits in a "pending" state from
//     generation until price actually trades to entryRef (the near edge
//     of the entry zone — entry_bottom for buys, entry_top for sells).
//     MFE/MAE and all $ simulation only start from that touch onward. If
//     price never comes back (or blows through the SL level without ever
//     touching entry), the setup resolves as Invalidated_NoFill /
//     Timeout_NoFill and contributes nothing to stats — it was never a
//     real trade.
//  2. v2.7 — THIS IS NOW A FULL TRADE SIMULATOR, not a price-level
//     outcome tracker. It reproduces CPositionManager's actual live
//     management logic bar-by-bar (Execution/PositionManager.mqh):
//     breakeven at InpBreakEvenAtR, a single partial close at
//     InpPartialAtR (InpPartialFraction of the ORIGINAL volume — not a
//     second partial at TP2; TP1/TP2 remain informational touch-flags
//     only, exactly like they are in live trading, where the broker-side
//     order is always bounded by stop_loss/final_tp and only the STOP
//     moves), then an ATR-multiple trailing stop on the runner. Position
//     sizing uses CRiskEngine.CalculateLotSize with the same entry
//     convention (entry_top for buy / entry_bottom for sell) the live EA
//     sizes against, so simulated $ figures reflect what the same inputs
//     would actually have traded. Commission, spread, and slippage are
//     applied as real transaction costs on every fill (entry, the
//     partial, and the final close), not bolted on afterward.
//  3. SAME-BAR EVENT COLLISIONS (the "conservative bias" issue): a
//     single bar can touch the stop AND a favorable trigger (final TP,
//     the breakeven trigger, or the partial trigger) in the same bar.
//     Which happened first can't be known from OHLC alone. This is
//     resolved via InpFillPolicy, generalized from v2.1's SL-vs-TP-only
//     logic to ANY adverse-level-vs-favorable-level collision:
//       FILL_CONSERVATIVE    - assume the adverse (stop) side first (old
//                               default, never overstates results)
//       FILL_OPTIMISTIC      - assume the favorable side first (for
//                               comparison only — never understates)
//       FILL_NEAREST         - whichever level the bar's open sits closer
//                               to is assumed to have been hit first
//       FILL_INTRABAR_REPLAY - steps through InpReplayTF bars inside the
//                               ambiguous bar to find the real order;
//                               falls back to Ambiguous if unavailable
//       FILL_AMBIGUOUS        - don't guess; counted separately, excluded
//                               from every win/loss/$ statistic
//  4. TRAILING STOP UPDATES ARE DEFERRED TO THE NEXT BAR, DELIBERATELY —
//     unlike the discrete R-triggers above (breakeven/partial), a
//     trailing stop recalculates continuously. Computing a tighter trail
//     from a bar's OWN favorable extreme and then checking that SAME
//     bar's OWN adverse extreme against it would silently assume the
//     best possible trail happened before any pullback within the bar —
//     a real lookahead bias, not a defensible ambiguity. So: a bar's
//     trail tightening takes effect starting the following bar. This is
//     the standard "trail updates on bar close" convention used by most
//     bar-based backtesters, stated explicitly rather than hidden.
//  5. Timeout ("Timeout" / "Timeout_NoFill") fires after InpMaxTrackingBars
//     entry-timeframe bars — a housekeeping cutoff, not a trading rule. A
//     filled trade that times out is still closed at that bar's close and
//     fully costed/counted, same as any other resolution.
//  6. Win / loss / scratch are now decided by NET REALIZED $ (after
//     commission, spread, slippage) — see OutcomeStats in Core/Config.mqh.
//     A trade whose final price-level event is "BreakEven_Hit" can still
//     be a net winner (it banked a profitable partial first); a trade
//     labeled "FinalTP_Hit" is always a winner. Read the label as "what
//     level ended it," and the $ fields as "what it actually made."
//  7. Every $ figure assumes ONE simulated position sized independently
//     per setup — it does NOT model portfolio-level exposure caps
//     (Portfolio/PortfolioManager.mqh isn't consulted here), so these
//     numbers answer "how good is the signal + management logic," not
//     "what would my account equity curve have looked like." Feeding
//     PortfolioManager into this simulator is a reasonable next step, not
//     something this file claims to already do.
// PendingSetup is defined in Core/Config.mqh (needs to be a complete
// type in SignalLogger.mqh too, for LogOutcome's signature).
class COutcomeTracker
  {
private:
   PendingSetup      m_pending[];
   int               m_count;
   int               m_maxBars;
   CSignalLogger*    m_logger;
   string            m_symbol;
   ENUM_TIMEFRAMES   m_entryTF;
   ENUM_FILL_POLICY  m_fillPolicy;
   ENUM_TIMEFRAMES   m_replayTF;
   OutcomeStats      m_stats;

   // --- v2.7 simulation configuration ---
   CRiskEngine       m_risk;
   double            m_riskPercent;          // matches InpRiskPercentPerTrade
   bool              m_allowMinLotOverride;  // simulator default: true (see ConfigureSimulation)
   double            m_breakEvenAtR;         // matches InpBreakEvenAtR
   double            m_partialAtR;           // matches InpPartialAtR
   double            m_partialFraction;      // matches InpPartialFraction
   double            m_trailAtrMult;         // matches InpTrailATRMult
   double            m_commissionPerLot;     // round-turn $ per 1.0 lot
   double            m_spreadPoints;         // simulated spread, in points
   double            m_slippagePoints;       // simulated adverse slippage per fill, in points

   // v2.9: feeds every resolved trade's (confidence, netPnL) into the
   // calibration bucket engine — see CalibrationEngine.mqh for scope/limits.
   CCalibrationEngine m_calibration;
   bool              m_calibrationEnabled;
   // v2.10 - DIAGNOSTIC-ONLY confidence decay. Half-life in unfilled bars;
   // <= 0 disables decay (confidenceDecayed stays == confidenceAtSignal).
   double            m_decayHalfLifeBars;
   // v2.11 — optional bridge publishing. NULL publisher = fully
   // backward compatible no-op (see ConfigurePublishing).
   CSignalPublisher* m_publisher;
   string            m_weightVersion;

   void              RemoveAt(int idx);
   // Pre-fill resolutions only (Invalidated_NoFill / Timeout_NoFill) —
   // never a real trade, so no $ accounting applies. Post-fill
   // resolutions go through FinalizeExit() instead.
   void              Resolve(int idx, string outcome, double exitPrice);

   double            PointSize() const;
   double            ValuePerUnitDistance() const;
   double            ApplyEntryCosts(double rawPrice, bool isBuy) const;
   double            ApplyExitCosts(double rawPrice, bool isBuy) const;
   string            SLHitLabel(const PendingSetup &p) const;

   // Closes `closeLots` of p's position at rawExitPrice (cost-adjusted
   // internally), updating p's running $ fields and remainingLots.
   void              CloseSlice(PendingSetup &p, double closeLots, double rawExitPrice, bool isBuy);
   void              ApplyPartial(PendingSetup &p, double triggerPrice, bool isBuy);

   // Which of two price levels was touched first within bar0, per
   // m_fillPolicy. adverseLevel is always the stop-side level (below
   // price for a buy, above for a sell); favorableLevel is always a
   // target/trigger level (above for a buy, below for a sell). Only
   // meaningful — and only called — when the caller has already
   // confirmed BOTH levels were touched this bar.
   bool              ResolveOrder(bool isBuy, CandleData &bar0, double adverseLevel, double favorableLevel, bool &ambiguous);
   bool              IntrabarReplayGeneric(bool isBuy, CandleData &bar0, double adverseLevel, double favorableLevel, bool &favorableFirst);
   // Full-close collision between the current stop and the final TP —
   // thin wrapper over ResolveOrder producing the outcome label/price.
   string            ResolveCollision(bool isBuy, CandleData &bar0, double adverseLevel, double favorableLevel,
                                      double &outExitPrice, bool &ambiguous);

   // Post-fill bar processing: the breakeven -> partial -> trailing
   // cascade described in the file header. May resolve (and remove) the
   // trade; if not, leaves it pending for the next bar.
   void              ProcessFilledBar(int idx, CandleData &bar0);
   // v2.10. Recomputes p.confidenceDecayed from p.decayBars. Pure
   // bookkeeping: no caller reads the result to cancel, re-rank or re-size
   // anything - see the PendingSetup v2.10 block in Config.mqh.
   void              ApplyDecay(PendingSetup &p) const;
   // v2.11. Shared by FinalizeExit() and Resolve() — no-ops silently if
   // m_publisher is NULL (publishing not configured) or p.decisionId < 0
   // (this setup was never routed through a decision, so there is no
   // valid signal_id to attach an outcome to — see Config.mqh
   // PendingSetup.decisionId). `coarseOutcome` is the already-normalized
   // "win"/"loss"/"scratch"/"no_fill"/"ambiguous" label — callers compute
   // this, not this function, so the win/loss/scratch epsilon logic lives
   // in exactly one place (FinalizeExit's existing m_stats classification).
   void              PublishIfConfigured(const PendingSetup &p, string coarseOutcome, bool ambiguous);
   // Closes the trade's remaining lots (if any), logs it, updates
   // m_stats, and removes it from the pending array.
   void              FinalizeExit(int idx, PendingSetup &p, string outcome, double rawExitPrice,
                                  bool sameBarCollision, bool ambiguous);

public:
                     COutcomeTracker();
   void              Init(CSignalLogger* logger, string symbol, ENUM_TIMEFRAMES entryTF, int maxBars,
                          ENUM_FILL_POLICY fillPolicy = FILL_CONSERVATIVE, ENUM_TIMEFRAMES replayTF = PERIOD_M1);
   // v2.7 — separated from Init() so the fill-policy/tracking-window
   // config and the simulation-economics config can each default
   // independently. Call once, right after Init(). Pass the SAME
   // InpBreakEvenAtR/InpPartialAtR/InpPartialFraction/InpTrailATRMult/
   // InpRiskPercentPerTrade values driving CPositionManager /
   // CRiskEngine live, so simulated results actually predict live
   // behavior instead of quietly drifting from it.
   void              ConfigureSimulation(double riskPercent, bool allowMinLotOverride,
                                         double breakEvenAtR, double partialAtR, double partialFraction,
                                         double trailAtrMult, double commissionPerLot,
                                         double spreadPoints, double slippagePoints);
   void              AddSetup(TradeSetup &setup, long decisionId = -1);
   void              Update(CTFContext* fvgCtx);
   int               ActiveCount() const { return m_count; }
   OutcomeStats      GetStats() const { return m_stats; }
   bool              GetFillState(datetime creation_time, bool &filled, double &fillPrice, datetime &fillTime, int &barsToFill);
   // v2.9. Call once after Init(), same pattern as ConfigureSimulation().
   // OFF by default — calibration data is only meaningful once you've
   // deliberately decided to start collecting it (see CalibrationEngine.mqh
   // limitation #4 re: resetting after scoring-formula changes).
   // v2.10. Half-life, in unfilled bars, of the diagnostic confidence
   // decay. 12 bars is the spec's starting point, not a fitted value.
   void              ConfigureConfidenceDecay(double halfLifeBars = 12.0) { m_decayHalfLifeBars = halfLifeBars; }
   void              ConfigureCalibration(bool enabled, int minSample = 30) { m_calibrationEnabled = enabled; m_calibration.Init(m_symbol, minSample); }
   // v2.11. OFF by default (NULL publisher) — call once after Init(),
   // same pattern as ConfigureSimulation/ConfigureCalibration. When set,
   // FinalizeExit() and Resolve() push every outcome to the bridge in
   // addition to the existing local-CSV LogOutcome() call.
   void              ConfigurePublishing(CSignalPublisher* publisher, string weightVersion)
     { m_publisher = publisher; m_weightVersion = weightVersion; }
   double            GetCalibratedProbability(double confidence, int &sampleSizeOut, bool &hasEnoughDataOut) const
     { return m_calibration.GetCalibratedProbability(confidence, sampleSizeOut, hasEnoughDataOut); }
   const CCalibrationEngine* CalibrationEngine() const { return GetPointer(m_calibration); }
  };
//+------------------------------------------------------------------+
COutcomeTracker::COutcomeTracker() : m_count(0), m_maxBars(100), m_logger(NULL),
                                      m_fillPolicy(FILL_CONSERVATIVE), m_replayTF(PERIOD_M1),
                                      m_riskPercent(0.5), m_allowMinLotOverride(true),
                                      m_breakEvenAtR(1.0), m_partialAtR(2.0), m_partialFraction(0.5),
                                      m_trailAtrMult(1.5), m_commissionPerLot(7.0),
                                      m_spreadPoints(10.0), m_slippagePoints(2.0), m_calibrationEnabled(false),
                                      m_decayHalfLifeBars(12.0), m_publisher(NULL), m_weightVersion("")
  {
   ZeroMemory(m_stats);
  }
//+------------------------------------------------------------------+
void COutcomeTracker::Init(CSignalLogger* logger, string symbol, ENUM_TIMEFRAMES entryTF, int maxBars,
                           ENUM_FILL_POLICY fillPolicy, ENUM_TIMEFRAMES replayTF)
  {
   m_logger = logger;
   m_symbol = symbol;
   m_entryTF = entryTF;
   m_maxBars = MathMax(5, maxBars);
   m_fillPolicy = fillPolicy;
   m_replayTF = replayTF;
   m_count = 0;
   ZeroMemory(m_stats);
   ArrayFree(m_pending);
  }
//+------------------------------------------------------------------+
void COutcomeTracker::ConfigureSimulation(double riskPercent, bool allowMinLotOverride,
                                          double breakEvenAtR, double partialAtR, double partialFraction,
                                          double trailAtrMult, double commissionPerLot,
                                          double spreadPoints, double slippagePoints)
  {
   m_riskPercent = (riskPercent > 0) ? riskPercent : 0.5;
   m_allowMinLotOverride = allowMinLotOverride;
   m_breakEvenAtR = breakEvenAtR;
   m_partialAtR = partialAtR;
   m_partialFraction = MathMax(0.0, MathMin(1.0, partialFraction));
   m_trailAtrMult = trailAtrMult;
   m_commissionPerLot = MathMax(0.0, commissionPerLot);
   m_spreadPoints = MathMax(0.0, spreadPoints);
   m_slippagePoints = MathMax(0.0, slippagePoints);
  }
//+------------------------------------------------------------------+
double COutcomeTracker::PointSize() const
  {
   return SymbolInfoDouble(m_symbol, SYMBOL_POINT);
  }
//+------------------------------------------------------------------+
double COutcomeTracker::ValuePerUnitDistance() const
  {
   double tickSize = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) return 0.0;
   return tickValue / tickSize;
  }
//+------------------------------------------------------------------+
// Opening a buy = buying = the adverse fill is a HIGHER price (you pay
// the ask, plus slippage). Opening a sell = selling = adverse is LOWER.
double COutcomeTracker::ApplyEntryCosts(double rawPrice, bool isBuy) const
  {
   double costPoints = (m_spreadPoints / 2.0 + m_slippagePoints) * PointSize();
   return isBuy ? rawPrice + costPoints : rawPrice - costPoints;
  }
//+------------------------------------------------------------------+
// Closing a buy = selling = adverse is LOWER. Closing a sell = buying =
// adverse is HIGHER. Applied identically to the partial close and the
// final close — both are real fills that cross the spread and can slip.
double COutcomeTracker::ApplyExitCosts(double rawPrice, bool isBuy) const
  {
   double costPoints = (m_spreadPoints / 2.0 + m_slippagePoints) * PointSize();
   return isBuy ? rawPrice - costPoints : rawPrice + costPoints;
  }
//+------------------------------------------------------------------+
string COutcomeTracker::SLHitLabel(const PendingSetup &p) const
  {
   if(!p.beDone) return "SL_Hit";
   if(!p.partialDone) return "BreakEven_Hit";
   return "Trail_Hit";
  }
//+------------------------------------------------------------------+
void COutcomeTracker::CloseSlice(PendingSetup &p, double closeLots, double rawExitPrice, bool isBuy)
  {
   if(closeLots <= 0 || p.lots <= 0) return;
   double exitPrice = ApplyExitCosts(rawExitPrice, isBuy);
   double valuePerUnit = ValuePerUnitDistance();
   double direction = isBuy ? 1.0 : -1.0;
   double grossPnL = direction * (exitPrice - p.entryFillPrice) * closeLots * valuePerUnit;
   double commission = m_commissionPerLot * closeLots;

   p.realizedPnL += (grossPnL - commission);
   p.totalCommission += commission;
   p.totalSpreadCost += (m_spreadPoints / 2.0) * PointSize() * closeLots * valuePerUnit;
   p.totalSlippageCost += m_slippagePoints * PointSize() * closeLots * valuePerUnit;
   p.remainingLots -= closeLots;
   if(p.remainingLots < 0) p.remainingLots = 0;
  }
//+------------------------------------------------------------------+
void COutcomeTracker::ApplyPartial(PendingSetup &p, double triggerPrice, bool isBuy)
  {
   if(p.lots > 0)
     {
      double closeLots = p.lots * m_partialFraction;
      CloseSlice(p, closeLots, triggerPrice, isBuy);
     }
   p.partialDone = true;
  }
//+------------------------------------------------------------------+
bool COutcomeTracker::IntrabarReplayGeneric(bool isBuy, CandleData &bar0, double adverseLevel, double favorableLevel, bool &favorableFirst)
  {
   // NOTE: ENUM_TIMEFRAMES values are bit-encoded, NOT a simple ordering
   // by duration — comparing them directly with >=/<= is a classic MQL5
   // bug. PeriodSeconds() gives the actual bar duration.
   int replaySecs = PeriodSeconds(m_replayTF);
   int entrySecs  = PeriodSeconds(m_entryTF);
   if(replaySecs <= 0 || entrySecs <= 0 || replaySecs >= entrySecs) return false;
   datetime barEnd = bar0.time + entrySecs;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(m_symbol, m_replayTF, bar0.time, barEnd - 1, rates);
   if(copied <= 0) return false;
   for(int i = copied - 1; i >= 0; i--) // oldest-to-newest, real chronological order
     {
      bool adverseHere = isBuy ? (rates[i].low <= adverseLevel) : (rates[i].high >= adverseLevel);
      bool favorableHere = isBuy ? (rates[i].high >= favorableLevel) : (rates[i].low <= favorableLevel);
      if(adverseHere && !favorableHere) { favorableFirst = false; return true; }
      if(favorableHere && !adverseHere) { favorableFirst = true;  return true; }
      if(adverseHere && favorableHere)  { favorableFirst = false; return true; } // gap-through even the replay bar — conservative within the replay itself
     }
   return false; // replay never actually confirmed either level
  }
//+------------------------------------------------------------------+
bool COutcomeTracker::ResolveOrder(bool isBuy, CandleData &bar0, double adverseLevel, double favorableLevel, bool &ambiguous)
  {
   ambiguous = false;
   switch(m_fillPolicy)
     {
      case FILL_OPTIMISTIC:
         return true;

      case FILL_NEAREST:
        {
         double distAdverse = MathAbs(bar0.open - adverseLevel);
         double distFavorable = MathAbs(bar0.open - favorableLevel);
         return (distFavorable < distAdverse);
        }

      case FILL_INTRABAR_REPLAY:
        {
         bool favorableFirst;
         if(IntrabarReplayGeneric(isBuy, bar0, adverseLevel, favorableLevel, favorableFirst))
            return favorableFirst;
         ambiguous = true;
         return false;
        }

      case FILL_AMBIGUOUS:
         ambiguous = true;
         return false;

      case FILL_CONSERVATIVE:
      default:
         return false;
     }
  }
//+------------------------------------------------------------------+
string COutcomeTracker::ResolveCollision(bool isBuy, CandleData &bar0, double adverseLevel, double favorableLevel,
                                         double &outExitPrice, bool &ambiguous)
  {
   bool favorableFirst = ResolveOrder(isBuy, bar0, adverseLevel, favorableLevel, ambiguous);
   if(ambiguous) { outExitPrice = bar0.close; return "Ambiguous_SLandTP"; }
   if(favorableFirst) { outExitPrice = favorableLevel; return "FinalTP_Hit"; }
   outExitPrice = adverseLevel; return "SL_Hit";
  }
//+------------------------------------------------------------------+
void COutcomeTracker::FinalizeExit(int idx, PendingSetup &p, string outcome, double rawExitPrice,
                                   bool sameBarCollision, bool ambiguous)
  {
   bool isBuy = (p.setup.type == ORDER_TYPE_BUY);
   if(p.remainingLots > 0)
      CloseSlice(p, p.remainingLots, rawExitPrice, isBuy); // ambiguous or not, bar0.close/the level itself is a real known price — only the LABEL stays ambiguous
   p.sameBarCollision = sameBarCollision;

   if(p.lots > 0)
     {
      if(ambiguous)
         m_stats.ambiguous++;
      else
        {
         if(p.realizedPnL > 0.0000001)      m_stats.wins++;
         else if(p.realizedPnL < -0.0000001) m_stats.losses++;
         else                                m_stats.scratches++;
         m_stats.resolvedCount++;
         m_stats.netPnL += p.realizedPnL;
         if(p.realizedPnL > 0) m_stats.grossProfit += p.realizedPnL;
         else                  m_stats.grossLoss += (-p.realizedPnL);
         m_stats.totalCommission += p.totalCommission;
         m_stats.totalSpreadCost += p.totalSpreadCost;
         m_stats.totalSlippageCost += p.totalSlippageCost;

         double oneRDollar = p.mgmtRiskDist * ValuePerUnitDistance() * p.lots;
         if(oneRDollar > 0) m_stats.sumRMultiple += p.realizedPnL / oneRDollar;

         // v2.9: feed this resolved, sized, non-ambiguous trade into the
         // calibration engine. p.setup.confidence is the RAW score at
         // signal time — see CalibrationEngine.mqh limitation #4 about
         // what happens to this data across a scoring-formula change.
         if(m_calibrationEnabled)
            m_calibration.Record(p.setup.confidence, p.realizedPnL);
        }
     }

   m_pending[idx] = p;
   if(m_logger != NULL)
      m_logger.LogOutcome(m_pending[idx], m_symbol, m_entryTF, outcome, rawExitPrice, m_fillPolicy);
   // v2.11 — same classification epsilons as the m_stats block above,
   // kept in exactly one place logically (this block feeds both); lots<=0
   // mirrors the doc comment at the top of this file: "excluded from
   // every $ stat" because sizing was impossible, so it's reported as
   // scratch (no informative PnL) rather than a fabricated win/loss.
   string coarseOutcome;
   if(ambiguous)                              coarseOutcome = "ambiguous";
   else if(p.lots <= 0)                       coarseOutcome = "scratch";
   else if(p.realizedPnL > 0.0000001)         coarseOutcome = "win";
   else if(p.realizedPnL < -0.0000001)        coarseOutcome = "loss";
   else                                        coarseOutcome = "scratch";
   PublishIfConfigured(m_pending[idx], coarseOutcome, ambiguous);
   RemoveAt(idx);
  }
void COutcomeTracker::PublishIfConfigured(const PendingSetup &p, string coarseOutcome, bool ambiguous)
  {
   if(m_publisher == NULL) return;
   if(p.decisionId < 0) return; // no decision was ever minted for this setup — no valid signal_id to attach to

   bool isBuy = (p.setup.type == ORDER_TYPE_BUY);
   double realizedR = 0.0, mfeR = 0.0, maeR = 0.0;
   if(coarseOutcome != "no_fill" && coarseOutcome != "ambiguous" && p.mgmtRiskDist > 0)
     {
      double oneRDollar = p.mgmtRiskDist * ValuePerUnitDistance() * p.lots;
      if(oneRDollar > 0) realizedR = p.realizedPnL / oneRDollar;
      mfeR = isBuy ? (p.mfePrice - p.sizingEntryPrice) / p.mgmtRiskDist
                   : (p.sizingEntryPrice - p.mfePrice) / p.mgmtRiskDist;
      maeR = isBuy ? (p.sizingEntryPrice - p.maePrice) / p.mgmtRiskDist
                   : (p.maePrice - p.sizingEntryPrice) / p.mgmtRiskDist;
     }

   string signalId = m_publisher.SignalIdForDecision(p.decisionId);
   string direction = isBuy ? "BUY" : "SELL";
   SetupReasons r = p.setup.reasons;

   m_publisher.PublishOutcome(signalId, m_symbol, direction, coarseOutcome, realizedR, mfeR, maeR,
                              p.barsElapsed, p.barsToFill, p.filled,
                              EnumToString(r.vol_regime), EnumToString(r.session), EnumToString(r.sweep_grade),
                              r.htf_ob_confluence, p.confidenceAtSignal, p.confidenceDecayed, p.decayBars);
  }
//+------------------------------------------------------------------+
  {
   PendingSetup p;
   ZeroMemory(p);
   p.setup = setup;
   p.decisionId = decisionId; // -1 unless the caller passed the real one post-Decide() — see Config.mqh
   bool isBuy = (setup.type == ORDER_TYPE_BUY);
   p.entryRef = isBuy ? setup.entry_bottom : setup.entry_top;
   p.riskDist = MathAbs(p.entryRef - setup.stop_loss);
   p.mfePrice = p.entryRef;
   p.maePrice = p.entryRef;
   p.tp1Hit = false;
   p.tp2Hit = false;
   p.barsElapsed = 0;
   p.lastBarTime = 0; // set on first Update() call
   p.filled = false;
   p.fillTime = 0;
   p.barsToFill = 0;
   p.sameBarCollision = false;
   p.confidenceAtSignal = setup.confidence;
   p.confidenceDecayed = setup.confidence;
   p.decayBars = 0;

   // --- v2.7: sizing at signal time, matching the live EA exactly (it
   // sizes and submits at decision time too — a pending order's volume
   // doesn't get re-evaluated when it eventually fills bars later). ---
   p.sizingEntryPrice = isBuy ? setup.entry_top : setup.entry_bottom;
   p.mgmtRiskDist = MathAbs(p.sizingEntryPrice - setup.stop_loss);
   bool exceededBudget = false;
   p.lots = (p.mgmtRiskDist > 0)
            ? m_risk.CalculateLotSize(m_symbol, m_riskPercent, p.sizingEntryPrice, setup.stop_loss,
                                      false, m_allowMinLotOverride, exceededBudget)
            : 0.0;
   p.currentSL = setup.stop_loss;
   p.beDone = false;
   p.partialDone = false;
   p.remainingLots = p.lots;
   p.entryFillPrice = 0.0;
   p.realizedPnL = 0.0;
   p.totalCommission = 0.0;
   p.totalSpreadCost = 0.0;
   p.totalSlippageCost = 0.0;

   int n = m_count++;
   ArrayResize(m_pending, m_count);
   m_pending[n] = p;
  }
//+------------------------------------------------------------------+
void COutcomeTracker::RemoveAt(int idx)
  {
   for(int i = idx; i < m_count - 1; i++)
      m_pending[i] = m_pending[i + 1];
   m_count--;
   ArrayResize(m_pending, m_count);
  }
//+------------------------------------------------------------------+
void COutcomeTracker::Resolve(int idx, string outcome, double exitPrice)
  {
   if(m_logger != NULL)
      m_logger.LogOutcome(m_pending[idx], m_symbol, m_entryTF, outcome, exitPrice, m_fillPolicy);
   // v2.11 — Resolve() is exclusively the pre-fill NoFill path (see class
   // header point 1); always "no_fill" regardless of the specific label
   // (Invalidated_NoFill/Timeout_NoFill) passed in, since neither
   // contributes anything the outcome schema's win/loss/scratch/no_fill/
   // ambiguous set needs to distinguish further.
   PublishIfConfigured(m_pending[idx], "no_fill", false);
   RemoveAt(idx);
  }
//+------------------------------------------------------------------+
// The breakeven -> partial -> trailing cascade. See the file header for
// the full reasoning; this loop can advance more than one stage within a
// single bar (a big enough bar can plausibly cross breakeven AND the
// partial trigger AND still get stopped, all in one candle) but is
// bounded so a malformed state can never spin forever.
void COutcomeTracker::ProcessFilledBar(int idx, CandleData &bar0)
  {
   PendingSetup p = m_pending[idx];
   bool isBuy = (p.setup.type == ORDER_TYPE_BUY);
   double finalTP = p.setup.final_tp;

   int guard = 0;
   while(guard++ < 6)
     {
      double adverseLevel = p.currentSL;
      bool adverseTouched = isBuy ? (bar0.low <= adverseLevel) : (bar0.high >= adverseLevel);
      bool tpTouched = isBuy ? (bar0.high >= finalTP) : (bar0.low <= finalTP);

      // 1. Final TP vs the current stop — a full close either way,
      // highest priority regardless of what stage we're in.
      if(adverseTouched && tpTouched)
        {
         double exitPrice; bool ambiguous;
         string outcome = ResolveCollision(isBuy, bar0, adverseLevel, finalTP, exitPrice, ambiguous);
         if(outcome == "SL_Hit") outcome = SLHitLabel(p);
         FinalizeExit(idx, p, outcome, exitPrice, true, ambiguous);
         return;
        }
      if(tpTouched)
        {
         FinalizeExit(idx, p, "FinalTP_Hit", finalTP, false, false);
         return;
        }

      // 2a. Breakeven stage.
      if(!p.beDone)
        {
         double beTrigger = isBuy ? p.sizingEntryPrice + m_breakEvenAtR * p.mgmtRiskDist
                                   : p.sizingEntryPrice - m_breakEvenAtR * p.mgmtRiskDist;
         bool beTouched = isBuy ? (bar0.high >= beTrigger) : (bar0.low <= beTrigger);

         if(adverseTouched && beTouched)
           {
            bool ambiguous;
            bool favorableFirst = ResolveOrder(isBuy, bar0, adverseLevel, beTrigger, ambiguous);
            if(ambiguous) { FinalizeExit(idx, p, "Ambiguous_SLandBE", bar0.close, true, true); return; }
            if(!favorableFirst) { FinalizeExit(idx, p, SLHitLabel(p), adverseLevel, false, false); return; }
            p.currentSL = p.sizingEntryPrice;
            p.beDone = true;
            m_pending[idx] = p;
            continue; // keep cascading — this same bar might reach further
           }
         if(adverseTouched) { FinalizeExit(idx, p, SLHitLabel(p), adverseLevel, false, false); return; }
         if(beTouched)
           {
            p.currentSL = p.sizingEntryPrice;
            p.beDone = true;
            m_pending[idx] = p;
            continue;
           }
         break; // nothing happened this bar
        }

      // 2b. Partial stage (only reachable once breakeven is done, same
      // order CPositionManager enforces).
      if(!p.partialDone)
        {
         double partialTrigger = isBuy ? p.sizingEntryPrice + m_partialAtR * p.mgmtRiskDist
                                        : p.sizingEntryPrice - m_partialAtR * p.mgmtRiskDist;
         bool partialTouched = isBuy ? (bar0.high >= partialTrigger) : (bar0.low <= partialTrigger);

         if(adverseTouched && partialTouched)
           {
            bool ambiguous;
            bool favorableFirst = ResolveOrder(isBuy, bar0, adverseLevel, partialTrigger, ambiguous);
            if(ambiguous) { FinalizeExit(idx, p, "Ambiguous_SLandPartial", bar0.close, true, true); return; }
            if(!favorableFirst) { FinalizeExit(idx, p, SLHitLabel(p), adverseLevel, false, false); return; }
            ApplyPartial(p, partialTrigger, isBuy);
            m_pending[idx] = p;
            continue;
           }
         if(adverseTouched) { FinalizeExit(idx, p, SLHitLabel(p), adverseLevel, false, false); return; }
         if(partialTouched)
           {
            ApplyPartial(p, partialTrigger, isBuy);
            m_pending[idx] = p;
            continue;
           }
         break;
        }

      // 3. Pure runner — the stop only trails (never widens). A hit on
      // the CURRENT stop (set going into this bar) still ends the trade;
      // any tightening computed from THIS bar's own favorable extreme is
      // deferred to the next bar (see file header, point 4).
      if(adverseTouched) { FinalizeExit(idx, p, SLHitLabel(p), adverseLevel, false, false); return; }

      if(bar0.atr > 0)
        {
         double favPrice = isBuy ? bar0.high : bar0.low;
         double newTrail = isBuy ? favPrice - m_trailAtrMult * bar0.atr : favPrice + m_trailAtrMult * bar0.atr;
         bool improved = isBuy ? (newTrail > p.currentSL) : (newTrail < p.currentSL);
         if(improved) p.currentSL = newTrail;
        }
      break;
     }

   if(p.barsElapsed >= m_maxBars)
     {
      FinalizeExit(idx, p, "Timeout", bar0.close, false, false);
      return;
     }
   m_pending[idx] = p;
  }
//+------------------------------------------------------------------+
void COutcomeTracker::ApplyDecay(PendingSetup &p) const
  {
   if(m_decayHalfLifeBars <= 0.0 || p.decayBars <= 0)
     {
      p.confidenceDecayed = p.confidenceAtSignal;
      return;
     }
   double factor = MathPow(0.5, (double)p.decayBars / m_decayHalfLifeBars);
   p.confidenceDecayed = p.confidenceAtSignal * factor;
  }
//+------------------------------------------------------------------+
void COutcomeTracker::Update(CTFContext* fvgCtx)
  {
   if(fvgCtx == NULL || fvgCtx.candles.Total() == 0) return;
   CandleData bar0 = fvgCtx.candles.GetCandle(0);

   for(int i = m_count - 1; i >= 0; i--)
     {
      PendingSetup p = m_pending[i];
      bool isBuy = (p.setup.type == ORDER_TYPE_BUY);

      if(p.lastBarTime == 0)
         p.lastBarTime = bar0.time;
      else if(bar0.time != p.lastBarTime)
        {
         p.barsElapsed++;
         p.lastBarTime = bar0.time;
         // v2.10: only UNFILLED bars decay. Once price has traded the
         // zone, the evidence was either right or wrong on its own terms;
         // staleness stops being the question.
         if(!p.filled)
           {
            p.decayBars++;
            ApplyDecay(p);
           }
        }
      m_pending[i] = p;

      // --- Fill confirmation gate ---
      if(!p.filled)
        {
         bool touchedEntry = isBuy ? (bar0.low <= p.entryRef) : (bar0.high >= p.entryRef);
         if(touchedEntry)
           {
            p.filled = true;
            p.fillTime = bar0.time;
            p.barsToFill = p.barsElapsed;
            p.mfePrice = p.entryRef;
            p.maePrice = p.entryRef;
            p.currentSL = p.setup.stop_loss;
            p.remainingLots = p.lots;
            if(p.lots > 0)
              {
               p.entryFillPrice = ApplyEntryCosts(p.sizingEntryPrice, isBuy);
               double valuePerUnit = ValuePerUnitDistance();
               p.totalSpreadCost = (m_spreadPoints / 2.0) * PointSize() * p.lots * valuePerUnit;
               p.totalSlippageCost = m_slippagePoints * PointSize() * p.lots * valuePerUnit;
              }
            m_pending[i] = p;
           }
         else
           {
            bool invalidated = isBuy ? (bar0.low <= p.setup.stop_loss) : (bar0.high >= p.setup.stop_loss);
            if(invalidated)
              {
               Resolve(i, "Invalidated_NoFill", bar0.close);
               continue;
              }
            if(p.barsElapsed >= m_maxBars)
              {
               Resolve(i, "Timeout_NoFill", bar0.close);
               continue;
              }
            continue;
           }
        }

      // Update MFE/MAE using this bar's full range (unchanged from v2.1 —
      // still measured against the original entryRef/riskDist, independent
      // of where the simulated stop has since moved to).
      if(isBuy)
        {
         if(bar0.high > p.mfePrice) p.mfePrice = bar0.high;
         if(bar0.low  < p.maePrice) p.maePrice = bar0.low;
        }
      else
        {
         if(bar0.low  < p.mfePrice) p.mfePrice = bar0.low;
         if(bar0.high > p.maePrice) p.maePrice = bar0.high;
        }
      m_pending[i] = p;

      // TP1/TP2 stay informational touch-flags only — see file header
      // point 2 on why they don't drive any $ event.
      if(isBuy)
        {
         if(!p.tp1Hit && bar0.high >= p.setup.tp1) m_pending[i].tp1Hit = true;
         if(!p.tp2Hit && bar0.high >= p.setup.tp2) m_pending[i].tp2Hit = true;
        }
      else
        {
         if(!p.tp1Hit && bar0.low <= p.setup.tp1) m_pending[i].tp1Hit = true;
         if(!p.tp2Hit && bar0.low <= p.setup.tp2) m_pending[i].tp2Hit = true;
        }

      ProcessFilledBar(i, bar0); // may resolve and remove index i
     }
  }
//+------------------------------------------------------------------+
bool COutcomeTracker::GetFillState(datetime creation_time, bool &filled, double &fillPrice, datetime &fillTime, int &barsToFill)
  {
   for(int i = 0; i < m_count; i++)
     {
      if(m_pending[i].setup.creation_time != creation_time) continue;
      filled     = m_pending[i].filled;
      fillPrice  = m_pending[i].entryRef;
      fillTime   = m_pending[i].fillTime;
      barsToFill = m_pending[i].barsToFill;
      return true;
     }
   return false;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Trading/OutcomeTracker.mqh ----

// ---- BEGIN EA/includes/Decision/DecisionEngine.mqh ----
//+------------------------------------------------------------------+
//|                                      Decision/DecisionEngine.mqh |
//|  The analysis -> action router: turns a validated TradeSetup into  |
//|  an explicit, ID'd, auditable TradeDecisionRecord.                |
//+------------------------------------------------------------------+
// Why this exists as its own layer instead of the EA calling
// COrderManager directly: "should we act on this setup at all, and how"
// is policy, not execution. Keeping it here means execution, signalling
// and persistence all receive the SAME immutable record, so the order
// that gets placed, the message subscribers receive, and the row Recovery
// later reads can never disagree about entry/SL/TP/confidence.
#ifndef DECISIONENGINE_MQH
#define DECISIONENGINE_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Decision/TradeDecision.mqh ----

// ---- END EA/includes/Decision/TradeDecision.mqh ----

class CDecisionEngine
  {
private:
   string            m_symbol;
   bool              m_enableExecution;
   bool              m_enableSignals;
   double            m_minConfidenceExecute;
   double            m_minConfidenceSignal;
   double            m_fullRiskConfidence;
   int               m_maxSpreadPoints;      // 0 = no spread gate
   long              m_nextId;

   double            CurrentSpreadPoints() const;

public:
                     CDecisionEngine();
   void              Init(const string symbol, bool enableExecution, bool enableSignals,
                          double minConfidenceExecute, double minConfidenceSignal,
                          double fullRiskConfidence, int maxSpreadPoints);
   // Recovery/restart safety: decision IDs are the matching key baked into
   // broker order comments, so a fresh instance must never reissue one.
   void              SeedNextId(long nextId);
   long              PeekNextId() const { return m_nextId; }
   TradeDecisionRecord Decide(const TradeSetup &setup);
  };
//+------------------------------------------------------------------+
CDecisionEngine::CDecisionEngine() : m_symbol(""), m_enableExecution(false), m_enableSignals(false),
                                     m_minConfidenceExecute(0.0), m_minConfidenceSignal(0.0),
                                     m_fullRiskConfidence(0.0), m_maxSpreadPoints(0), m_nextId(1) {}
//+------------------------------------------------------------------+
void CDecisionEngine::Init(const string symbol, bool enableExecution, bool enableSignals,
                           double minConfidenceExecute, double minConfidenceSignal,
                           double fullRiskConfidence, int maxSpreadPoints)
  {
   m_symbol = (symbol == "") ? _Symbol : symbol;
   m_enableExecution = enableExecution;
   m_enableSignals = enableSignals;
   m_minConfidenceExecute = minConfidenceExecute;
   m_minConfidenceSignal = minConfidenceSignal;
   m_fullRiskConfidence = fullRiskConfidence;
   m_maxSpreadPoints = MathMax(0, maxSpreadPoints);
  }
//+------------------------------------------------------------------+
void CDecisionEngine::SeedNextId(long nextId)
  {
   if(nextId > m_nextId) m_nextId = nextId;
  }
//+------------------------------------------------------------------+
double CDecisionEngine::CurrentSpreadPoints() const
  {
   // SYMBOL_SPREAD is already in points. It can legitimately be 0 on a
   // symbol the broker quotes with a floating spread while the market is
   // closed - fall back to the raw ask/bid difference in that case so the
   // gate isn't silently bypassed at weekend/rollover.
   long spread = SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
   if(spread > 0) return (double)spread;

   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   if(point <= 0) return 0.0;
   double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return 0.0;
   return (ask - bid) / point;
  }
//+------------------------------------------------------------------+
// Returns a record with valid=false / POLICY_IGNORE for anything that
// should not be acted on. It never throws away the reason - the caller
// (and the CSV store) keeps it, because "why did the EA not take that
// setup" is the single most common question in production.
TradeDecisionRecord CDecisionEngine::Decide(const TradeSetup &setup)
  {
   TradeDecisionRecord rec;
   ZeroMemory(rec);
   rec.symbol = m_symbol;
   rec.setup = setup;
   rec.confidence = setup.confidence;
   rec.decided_time = TimeCurrent();
   rec.action = POLICY_IGNORE;
   rec.valid = false;
   rec.spread_points = CurrentSpreadPoints();

   if(!setup.active)
     {
      rec.reason = "setup inactive";
      return rec;
     }
   if(!m_enableExecution && !m_enableSignals)
     {
      rec.reason = "execution and signals both disabled";
      return rec;
     }

   bool canExecute = m_enableExecution && setup.confidence >= m_minConfidenceExecute;
   bool canSignal  = m_enableSignals  && setup.confidence >= m_minConfidenceSignal;

   // Spread gate applies to EXECUTION only. A wide spread makes the fill
   // bad; it does not make the analysis wrong, so subscribers still get
   // the signal (they may be on a different broker entirely).
   if(canExecute && m_maxSpreadPoints > 0 && rec.spread_points > (double)m_maxSpreadPoints)
     {
      canExecute = false;
      rec.reason = StringFormat("execution skipped: spread %.0f pts > max %d pts; ",
                                rec.spread_points, m_maxSpreadPoints);
     }

   if(canExecute && canSignal)      rec.action = POLICY_EXECUTE_AND_SIGNAL;
   else if(canExecute)              rec.action = POLICY_EXECUTE_ONLY;
   else if(canSignal)               rec.action = POLICY_SIGNAL_ONLY;

   if(rec.action == POLICY_IGNORE)
     {
      rec.reason += StringFormat("confidence %.1f below thresholds (execute %.1f / signal %.1f)",
                                 setup.confidence, m_minConfidenceExecute, m_minConfidenceSignal);
      return rec;
     }

   // Below the "full risk" confidence the setup is still tradable, just
   // not at full size - CRiskEngine::CalculateLotSize() halves it when
   // reduce_risk is set.
   rec.reduce_risk = (setup.confidence < m_fullRiskConfidence);
   rec.valid = true;
   rec.decision_id = m_nextId++;
   rec.reason += StringFormat("%s at confidence %.1f%s", TradePolicyToString(rec.action),
                              setup.confidence, rec.reduce_risk ? " (reduced risk)" : "");
   return rec;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Decision/DecisionEngine.mqh ----

// ---- BEGIN EA/includes/Decision/DecisionStore.mqh ----
//+------------------------------------------------------------------+
//|                                       Decision/DecisionStore.mqh |
//|  Crash-safe CSV persistence for decisions and their executions.   |
//+------------------------------------------------------------------+
// Recovery cannot reconstruct a live trade from broker data alone: the
// broker knows the ticket, volume, SL and TP, but not the setup that
// produced them (entry zone, TP1/TP2 ladder, confidence). This store is
// the missing half. It writes append-only CSV in the terminal's Files
// folder, one pair of files per symbol, and keeps an in-memory mirror so
// FindById()/LoadAll() never touch the disk on the hot path.
//
// Durability choice: every Save() opens, appends, flushes and CLOSES the
// file rather than holding a handle open across ticks. That costs a file
// open per decision (a few per day, not per tick) and buys the guarantee
// the EA depends on - if the terminal is killed the instant after an
// order fills, the decision row is already on disk.
#ifndef DECISIONSTORE_MQH
#define DECISIONSTORE_MQH

// ---- BEGIN EA/includes/Core/Config.mqh ----

// ---- END EA/includes/Core/Config.mqh ----


// ---- BEGIN EA/includes/Decision/TradeDecision.mqh ----

// ---- END EA/includes/Decision/TradeDecision.mqh ----

#define DECISION_CSV_SEP ";"

class CDecisionStore
  {
private:
   string               m_symbol;
   string               m_decisionsFile;
   string               m_executionsFile;
   TradeDecisionRecord  m_decisions[];
   ExecutionRecord      m_executions[];

   string               SanitizeSymbol(const string s);
   bool                 AppendLine(const string filename, const string line);
   int                  ReadLines(const string filename, string &lines[]);
   string               SerializeDecision(const TradeDecisionRecord &rec);
   bool                 ParseDecision(const string line, TradeDecisionRecord &rec);
   string               SerializeExecution(const ExecutionRecord &rec);
   bool                 ParseExecution(const string line, ExecutionRecord &rec);
   void                 LoadFromDisk();

public:
                        CDecisionStore();
   void                 Init(const string symbol);
   void                 Deinit();

   bool                 Save(const TradeDecisionRecord &rec);
   bool                 SaveExecution(long decisionId, double volume, ulong ticket);

   int                  LoadAll(TradeDecisionRecord &out[]);
   int                  LoadAllExecutions(ExecutionRecord &out[]);
   bool                 FindById(long decisionId, TradeDecisionRecord &out);
   int                  Count() const { return ArraySize(m_decisions); }
  };
//+------------------------------------------------------------------+
CDecisionStore::CDecisionStore() : m_symbol(""), m_decisionsFile(""), m_executionsFile("") {}
//+------------------------------------------------------------------+
// Symbols can contain characters that are illegal in filenames on some
// brokers ("EURUSD.pro", "XAU/USD", "US30-cash"), so normalise rather
// than letting FileOpen fail silently at runtime.
string CDecisionStore::SanitizeSymbol(const string s)
  {
   string out = "";
   for(int i = 0; i < StringLen(s); i++)
     {
      ushort c = StringGetCharacter(s, i);
      bool ok = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
      out += ok ? ShortToString(c) : "_";
     }
   return (out == "") ? "SYMBOL" : out;
  }
//+------------------------------------------------------------------+
void CDecisionStore::Init(const string symbol)
  {
   m_symbol = (symbol == "") ? _Symbol : symbol;
   string tag = SanitizeSymbol(m_symbol);
   m_decisionsFile  = "MedisTouch_Decisions_" + tag + ".csv";
   m_executionsFile = "MedisTouch_Executions_" + tag + ".csv";
   ArrayFree(m_decisions);
   ArrayFree(m_executions);
   LoadFromDisk();
  }
//+------------------------------------------------------------------+
// Nothing is buffered between calls, so there is no flush to perform.
// Kept as an explicit no-op hook so OnDeinit's contract stays stable if
// batching is ever introduced.
void CDecisionStore::Deinit()
  {
   ArrayFree(m_decisions);
   ArrayFree(m_executions);
  }
//+------------------------------------------------------------------+
bool CDecisionStore::AppendLine(const string filename, const string line)
  {
   int handle = FileOpen(filename, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   if(handle == INVALID_HANDLE)
     {
      PrintFormat("MedisTouch DecisionStore: cannot open %s for append (error %d) — this session's decisions will NOT survive a restart.",
                  filename, GetLastError());
      return false;
     }
   FileSeek(handle, 0, SEEK_END);
   FileWriteString(handle, line + "\r\n");
   FileFlush(handle);
   FileClose(handle);
   return true;
  }
//+------------------------------------------------------------------+
int CDecisionStore::ReadLines(const string filename, string &lines[])
  {
   ArrayFree(lines);
   if(!FileIsExist(filename)) return 0;
   int handle = FileOpen(filename, FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE)
     {
      PrintFormat("MedisTouch DecisionStore: cannot read %s (error %d).", filename, GetLastError());
      return 0;
     }
   int count = 0;
   while(!FileIsEnding(handle))
     {
      string line = FileReadString(handle);
      if(StringLen(line) == 0) continue;
      ArrayResize(lines, count + 1);
      lines[count++] = line;
     }
   FileClose(handle);
   return count;
  }
//+------------------------------------------------------------------+
// Field order is frozen: appending new fields at the END keeps old files
// readable (ParseDecision tolerates a short row), while reordering would
// silently corrupt recovery after an upgrade.
string CDecisionStore::SerializeDecision(const TradeDecisionRecord &rec)
  {
   string parts[13];
   parts[0]  = IntegerToString(rec.decision_id);
   parts[1]  = rec.symbol;
   parts[2]  = IntegerToString((int)rec.setup.type);
   parts[3]  = DoubleToString(rec.setup.entry_top, _Digits);
   parts[4]  = DoubleToString(rec.setup.entry_bottom, _Digits);
   parts[5]  = DoubleToString(rec.setup.stop_loss, _Digits);
   parts[6]  = DoubleToString(rec.setup.tp1, _Digits);
   parts[7]  = DoubleToString(rec.setup.tp2, _Digits);
   parts[8]  = DoubleToString(rec.setup.final_tp, _Digits);
   parts[9]  = DoubleToString(rec.setup.confidence, 2);
   parts[10] = IntegerToString((long)rec.decided_time);
   parts[11] = IntegerToString((int)rec.action);
   parts[12] = rec.reduce_risk ? "1" : "0";

   string line = parts[0];
   for(int i = 1; i < 13; i++) line += DECISION_CSV_SEP + parts[i];
   return line;
  }
//+------------------------------------------------------------------+
bool CDecisionStore::ParseDecision(const string line, TradeDecisionRecord &rec)
  {
   string f[];
   int n = StringSplit(line, StringGetCharacter(DECISION_CSV_SEP, 0), f);
   if(n < 11) return false;   // too short to rebuild a trade from — skip, don't guess

   ZeroMemory(rec);
   rec.decision_id        = (long)StringToInteger(f[0]);
   rec.symbol             = f[1];
   rec.setup.type         = (ENUM_ORDER_TYPE)(int)StringToInteger(f[2]);
   rec.setup.entry_top    = StringToDouble(f[3]);
   rec.setup.entry_bottom = StringToDouble(f[4]);
   rec.setup.stop_loss    = StringToDouble(f[5]);
   rec.setup.tp1          = StringToDouble(f[6]);
   rec.setup.tp2          = StringToDouble(f[7]);
   rec.setup.final_tp     = StringToDouble(f[8]);
   rec.setup.confidence   = StringToDouble(f[9]);
   rec.setup.creation_time = (datetime)StringToInteger(f[10]);
   rec.setup.active       = true;
   rec.confidence         = rec.setup.confidence;
   rec.decided_time       = (datetime)StringToInteger(f[10]);
   rec.action             = (n > 11) ? (ENUM_TRADE_POLICY)(int)StringToInteger(f[11]) : POLICY_EXECUTE_ONLY;
   rec.reduce_risk        = (n > 12) ? (f[12] == "1") : false;
   rec.valid              = true;
   rec.reason             = "restored from " + m_decisionsFile;
   return true;
  }
//+------------------------------------------------------------------+
string CDecisionStore::SerializeExecution(const ExecutionRecord &rec)
  {
   return IntegerToString(rec.decision_id) + DECISION_CSV_SEP +
          DoubleToString(rec.volume, 2) + DECISION_CSV_SEP +
          IntegerToString((long)rec.ticket) + DECISION_CSV_SEP +
          IntegerToString((long)rec.submitted_time);
  }
//+------------------------------------------------------------------+
bool CDecisionStore::ParseExecution(const string line, ExecutionRecord &rec)
  {
   string f[];
   int n = StringSplit(line, StringGetCharacter(DECISION_CSV_SEP, 0), f);
   if(n < 3) return false;
   ZeroMemory(rec);
   rec.decision_id    = (long)StringToInteger(f[0]);
   rec.volume         = StringToDouble(f[1]);
   rec.ticket         = (ulong)StringToInteger(f[2]);
   rec.submitted_time = (n > 3) ? (datetime)StringToInteger(f[3]) : 0;
   return true;
  }
//+------------------------------------------------------------------+
void CDecisionStore::LoadFromDisk()
  {
   string lines[];
   int n = ReadLines(m_decisionsFile, lines);
   for(int i = 0; i < n; i++)
     {
      TradeDecisionRecord rec;
      if(!ParseDecision(lines[i], rec)) continue;
      int idx = ArraySize(m_decisions);
      ArrayResize(m_decisions, idx + 1);
      m_decisions[idx] = rec;
     }

   string elines[];
   int m = ReadLines(m_executionsFile, elines);
   for(int i = 0; i < m; i++)
     {
      ExecutionRecord rec;
      if(!ParseExecution(elines[i], rec)) continue;
      int idx = ArraySize(m_executions);
      ArrayResize(m_executions, idx + 1);
      m_executions[idx] = rec;
     }

   if(n > 0 || m > 0)
      PrintFormat("MedisTouch DecisionStore: loaded %d decision(s) and %d execution(s) for %s.",
                  ArraySize(m_decisions), ArraySize(m_executions), m_symbol);
  }
//+------------------------------------------------------------------+
bool CDecisionStore::Save(const TradeDecisionRecord &rec)
  {
   if(!rec.valid) return false;

   // Idempotent: re-saving the same decision (e.g. after a retry path)
   // must not create a second row Recovery could match twice.
   for(int i = 0; i < ArraySize(m_decisions); i++)
      if(m_decisions[i].decision_id == rec.decision_id) return true;

   int idx = ArraySize(m_decisions);
   ArrayResize(m_decisions, idx + 1);
   m_decisions[idx] = rec;
   return AppendLine(m_decisionsFile, SerializeDecision(rec));
  }
//+------------------------------------------------------------------+
bool CDecisionStore::SaveExecution(long decisionId, double volume, ulong ticket)
  {
   ExecutionRecord rec;
   ZeroMemory(rec);
   rec.decision_id    = decisionId;
   rec.volume         = volume;
   rec.ticket         = ticket;
   rec.submitted_time = TimeCurrent();

   for(int i = 0; i < ArraySize(m_executions); i++)
      if(m_executions[i].decision_id == decisionId && m_executions[i].ticket == ticket) return true;

   int idx = ArraySize(m_executions);
   ArrayResize(m_executions, idx + 1);
   m_executions[idx] = rec;
   return AppendLine(m_executionsFile, SerializeExecution(rec));
  }
//+------------------------------------------------------------------+
int CDecisionStore::LoadAll(TradeDecisionRecord &out[])
  {
   int n = ArraySize(m_decisions);
   ArrayResize(out, n);
   for(int i = 0; i < n; i++) out[i] = m_decisions[i];
   return n;
  }
//+------------------------------------------------------------------+
int CDecisionStore::LoadAllExecutions(ExecutionRecord &out[])
  {
   int n = ArraySize(m_executions);
   ArrayResize(out, n);
   for(int i = 0; i < n; i++) out[i] = m_executions[i];
   return n;
  }
//+------------------------------------------------------------------+
bool CDecisionStore::FindById(long decisionId, TradeDecisionRecord &out)
  {
   for(int i = ArraySize(m_decisions) - 1; i >= 0; i--)
      if(m_decisions[i].decision_id == decisionId)
        {
         out = m_decisions[i];
         return true;
        }
   return false;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Decision/DecisionStore.mqh ----

// ---- BEGIN EA/includes/Execution/BrokerAdapter.mqh ----
//+------------------------------------------------------------------+
//|                                       Execution/BrokerAdapter.mqh |
//+------------------------------------------------------------------+
#ifndef BROKERADAPTER_MQH
#define BROKERADAPTER_MQH
#include <Trade/Trade.mqh>

// Thin wrapper around the standard CTrade class. OrderManager and
// PositionManager never touch the trade API directly — everything routes
// through here, which centralizes retry/error logging and gives one seam
// to swap execution backends later (e.g. a copier API) without touching
// the rest of Execution.
//
// FIXED: market fills used to hand back CTrade::ResultOrder() (the order
// ticket) as the position ticket. That happens to work on a netting
// account, where MT5 keeps one position per symbol, but it is not
// guaranteed to equal the position ticket in general and breaks outright
// on a hedging account with multiple concurrent positions on the same
// symbol. Every deal MT5 executes records which position it belongs to
// (DEAL_POSITION_ID), and that ID is exactly what
// PositionSelectByTicket()/POSITION_TICKET expect — on both account
// modes. MarketBuy/MarketSell now resolve the real position ticket via
// the deal, with the old order-ticket behavior kept only as a logged
// fallback if history lookup ever fails.
class CBrokerAdapter
  {
private:
   CTrade            m_trade;
   int               m_maxRetries;
   int               m_retryDelayMs;
   ulong             m_lastLatencyUs;   // LATENCY: wall time spent inside the most recent broker call, including any retry sleeps

   bool              LastRequestOk(string action);
   ulong             ResolvePositionTicket();
   // LATENCY: not every rejection deserves the same treatment. A requote
   // or a stale price just needs a fresh quote — sleeping the full
   // m_retryDelayMs before asking again is wasted time on something that
   // clears in milliseconds. A connection/timeout issue genuinely needs
   // the network a moment to recover. A terminal rejection (bad stops,
   // no money, trading disabled, market closed) will not change no
   // matter how many times or how fast you retry it — burning the
   // remaining attempts and their delays on it is pure latency with no
   // chance of success. Classify once, act accordingly, in both retry
   // loops below.
   bool              IsRetryable(uint retcode);
   int               DelayForRetcode(uint retcode);

   // G6 FIX: audit of Execution/Portfolio/Trading found magic-number
   // order attribution here, but ZERO checks anywhere for broker
   // stop-distance/freeze-level, connection loss, or market-closed —
   // all three mandatory for a live-trading EA. Before this, the only
   // defense against any of the three was reacting to whatever retcode
   // the broker happened to send back AFTER a doomed request round-trip
   // — no local pre-check ever stopped one from being sent in the
   // first place. Centralized here since every execution call already
   // routes through this class.
   bool              IsConnected();
   bool              IsMarketOpenForTrading(string symbol, bool requireFullOpen);
   bool              ValidateStopDistance(string symbol, double refPrice, double sl, double tp, bool isBuy, string action);

public:
   void              Init(ulong magic, int maxRetries = 3, int retryDelayMs = 300);
   // LATENCY: milliseconds spent inside the most recently completed
   // MarketBuy/MarketSell/PlaceLimit call (success or final failure),
   // including every retry sleep. This is the "execution" half of
   // confirmation+execution latency — call right after any of those
   // three return, before making another broker call.
   double            LastLatencyMs() { return (double)m_lastLatencyUs / 1000.0; }
   // FIX (audit #25): fillPriceOut returns the REAL price CTrade filled at
   // (ResultPrice()), not the theoretical FVG-edge entry the signal was
   // built around. Market execution uses price=0.0 (fill at whatever the
   // market gives), so the two can differ. Everything downstream that
   // assumed "filled at the decision's entry price" (break-even trigger,
   // R-multiple, partial-close trigger) needs this real number instead.
   bool              MarketBuy(string symbol, double volume, double sl, double tp, ulong &ticketOut, double &fillPriceOut, string comment = "");
   bool              MarketSell(string symbol, double volume, double sl, double tp, ulong &ticketOut, double &fillPriceOut, string comment = "");
   bool              PlaceLimit(string symbol, ENUM_ORDER_TYPE type, double volume, double price,
                                double sl, double tp, ulong &ticketOut, string comment = "");
   bool              CancelOrder(ulong ticket);
   bool              ModifySLTP(ulong ticket, double sl, double tp);
   bool              ClosePartial(ulong ticket, double volume);
   bool              CloseFull(ulong ticket);
  };
//+------------------------------------------------------------------+
void CBrokerAdapter::Init(ulong magic, int maxRetries, int retryDelayMs)
  {
   m_trade.SetExpertMagicNumber(magic);
   m_trade.SetDeviationInPoints(20);
   m_trade.SetTypeFillingBySymbol(_Symbol);
   m_maxRetries = maxRetries;
   m_retryDelayMs = retryDelayMs;
   m_lastLatencyUs = 0;
  }
//+------------------------------------------------------------------+
// LATENCY: unlisted/unrecognized codes default to retryable at the
// normal delay — conservative on purpose, since treating an unknown
// code as terminal risks silently giving up on something that was
// actually transient, and this list can't claim to be exhaustive across
// every broker's retcode usage.
bool CBrokerAdapter::IsRetryable(uint retcode)
  {
   switch(retcode)
     {
      // Terminal — retrying changes nothing about these.
      case TRADE_RETCODE_INVALID_STOPS:
      case TRADE_RETCODE_TRADE_DISABLED:
      case TRADE_RETCODE_MARKET_CLOSED:
      case TRADE_RETCODE_NO_MONEY:
      case TRADE_RETCODE_INVALID_EXPIRATION:
      case TRADE_RETCODE_LOCKED:
      case TRADE_RETCODE_INVALID_FILL:
      case TRADE_RETCODE_ONLY_REAL:
      case TRADE_RETCODE_LIMIT_ORDERS:
      case TRADE_RETCODE_LIMIT_VOLUME:
      case TRADE_RETCODE_INVALID_ORDER:
      case TRADE_RETCODE_LIMIT_POSITIONS:
      case TRADE_RETCODE_LONG_ONLY:
      case TRADE_RETCODE_SHORT_ONLY:
      case TRADE_RETCODE_CLOSE_ONLY:
      case TRADE_RETCODE_FIFO_CLOSE:
      case TRADE_RETCODE_HEDGE_PROHIBITED:
      case TRADE_RETCODE_SERVER_DISABLES_AT:
      case TRADE_RETCODE_CLIENT_DISABLES_AT:
         return false;
      default:
         return true;
     }
  }
//+------------------------------------------------------------------+
// LATENCY: requote/price-changed/off-quotes just need a fresh tick, not
// a network recovery window — retry almost immediately. Timeout/
// connection/too-many-requests genuinely need the full configured delay
// to have a chance of clearing.
int CBrokerAdapter::DelayForRetcode(uint retcode)
  {
   switch(retcode)
     {
      case TRADE_RETCODE_REQUOTE:
      case TRADE_RETCODE_PRICE_CHANGED:
      case TRADE_RETCODE_PRICE_OFF:
         return MathMin(m_retryDelayMs, 50);
      default:
         return m_retryDelayMs;
     }
  }
//+------------------------------------------------------------------+
// G6 FIX. TERMINAL_CONNECTED is the local terminal's link to the trade
// server — separate from, and checked BEFORE, the retry loop's own
// TRADE_RETCODE_CONNECTION handling (that one reacts to a request that
// WAS sent and failed server-side; this one avoids sending a request at
// all when the terminal already knows it has nothing to send it to). Not
// looped into the retry logic on purpose: a retry loop spinning for a
// few hundred ms within one tick cannot fix a genuinely dead connection
// — OnTick() will get another chance on the next tick regardless.
bool CBrokerAdapter::IsConnected()
  {
   if(TerminalInfoInteger(TERMINAL_CONNECTED)) return true;
   Print("MedisTouch BrokerAdapter: terminal not connected to the trade server — refusing to submit, not retrying (a retry loop can't fix a dead connection within one tick).");
   return false;
  }
//+------------------------------------------------------------------+
// G6 FIX. SYMBOL_TRADE_MODE_DISABLED means no trading at all on this
// symbol right now (exchange holiday, broker maintenance, delisting).
// SYMBOL_TRADE_MODE_CLOSEONLY means new positions/orders are refused
// but existing ones can still be closed or modified — requireFullOpen
// lets closes/modifies past a close-only market while still blocking
// new opens. This is a distinct condition from TRADE_RETCODE_MARKET_CLOSED
// (which is a broker's post-hoc rejection of a request already sent);
// this check catches it beforehand instead of spending a round-trip to
// learn what SymbolInfoInteger already knows locally.
bool CBrokerAdapter::IsMarketOpenForTrading(string symbol, bool requireFullOpen)
  {
   long mode = (long)SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED)
     {
      PrintFormat("MedisTouch BrokerAdapter: %s trading is disabled on this symbol right now (SYMBOL_TRADE_MODE_DISABLED) — refusing.", symbol);
      return false;
     }
   if(requireFullOpen && mode == SYMBOL_TRADE_MODE_CLOSEONLY)
     {
      PrintFormat("MedisTouch BrokerAdapter: %s is close-only right now (SYMBOL_TRADE_MODE_CLOSEONLY) — refusing to open a new position/order.", symbol);
      return false;
     }
   return true;
  }
//+------------------------------------------------------------------+
// G6 FIX. Two separate broker-imposed minimums, both expressed in
// points and both meaning "SL/TP must sit at least this far from the
// reference price or the broker will reject it": SYMBOL_TRADE_STOPS_LEVEL
// (minimum distance for placing/modifying a stop) and
// SYMBOL_TRADE_FREEZE_LEVEL (minimum distance within which an order/
// position can't be touched at all, on brokers that impose one).
// MathMax of the two, since either can independently cause a broker
// rejection — some brokers set STOPS_LEVEL, others FREEZE_LEVEL, some
// both, some (real ECN accounts) neither, which is why 0 is left as 0
// rather than defaulted to something nonzero: genuinely means "no
// broker-imposed minimum," not "not configured."
// Also checks SL/TP land on the correct side of the reference price —
// catches a wiring bug elsewhere in this codebase before it reaches the
// broker as a confusing generic rejection, not just a broker-limit
// violation.
bool CBrokerAdapter::ValidateStopDistance(string symbol, double refPrice, double sl, double tp, bool isBuy, string action)
  {
   if(refPrice <= 0.0)
     {
      PrintFormat("MedisTouch BrokerAdapter: %s refused — reference price is %.5f (stale/zero quote), can't validate stop distance against it.", action, refPrice);
      return false;
     }
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0) return true; // can't validate without a point size -- a symbol-info failure unrelated to stops shouldn't block the trade

   long stopsLevelPts  = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevelPts = SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = MathMax(stopsLevelPts, freezeLevelPts) * point;

   if(sl > 0.0)
     {
      bool wrongSide = isBuy ? (sl >= refPrice) : (sl <= refPrice);
      if(wrongSide)
        {
         PrintFormat("MedisTouch BrokerAdapter: %s refused — SL %.5f is on the wrong side of reference %.5f for a %s.",
                     action, sl, refPrice, isBuy ? "buy" : "sell");
         return false;
        }
      if(minDist > 0.0 && MathAbs(refPrice - sl) < minDist)
        {
         PrintFormat("MedisTouch BrokerAdapter: %s refused — SL %.5f is %.1f points from reference %.5f, broker requires >= %.1f (stops level %d, freeze level %d).",
                     action, sl, MathAbs(refPrice - sl) / point, refPrice, minDist / point, stopsLevelPts, freezeLevelPts);
         return false;
        }
     }
   if(tp > 0.0)
     {
      bool wrongSide = isBuy ? (tp <= refPrice) : (tp >= refPrice);
      if(wrongSide)
        {
         PrintFormat("MedisTouch BrokerAdapter: %s refused — TP %.5f is on the wrong side of reference %.5f for a %s.",
                     action, tp, refPrice, isBuy ? "buy" : "sell");
         return false;
        }
      if(minDist > 0.0 && MathAbs(refPrice - tp) < minDist)
        {
         PrintFormat("MedisTouch BrokerAdapter: %s refused — TP %.5f is %.1f points from reference %.5f, broker requires >= %.1f (stops level %d, freeze level %d).",
                     action, tp, MathAbs(refPrice - tp) / point, refPrice, minDist / point, stopsLevelPts, freezeLevelPts);
         return false;
        }
     }
   return true;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::LastRequestOk(string action)
  {
   uint code = m_trade.ResultRetcode();
   if(code == TRADE_RETCODE_DONE || code == TRADE_RETCODE_PLACED)
      return true;
   PrintFormat("MedisTouch BrokerAdapter: %s failed, retcode=%d (%s)",
               action, code, m_trade.ResultRetcodeDescription());
   return false;
  }
//+------------------------------------------------------------------+
ulong CBrokerAdapter::ResolvePositionTicket()
  {
   ulong dealTicket = m_trade.ResultDeal();
   if(dealTicket == 0)
     {
      Print("MedisTouch BrokerAdapter: fill had no deal ticket in the trade result, ",
            "falling back to order ticket — verify this position manually.");
      return m_trade.ResultOrder();
     }
   if(!HistoryDealSelect(dealTicket))
     {
      // FIX: this was two separate string-literal arguments after the
      // format string, with only one %d specifier to consume them and
      // dealTicket left as a trailing unmatched argument — a malformed
      // PrintFormat call, not a working one. Concatenated into a single
      // format string with its one real argument.
      PrintFormat("MedisTouch BrokerAdapter: could not select deal #%d from history, falling back to order ticket — verify this position manually.",
                  dealTicket);
      return m_trade.ResultOrder();
     }
   ulong positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   if(positionId == 0)
     {
      // FIX: same malformed-call shape as above.
      PrintFormat("MedisTouch BrokerAdapter: deal #%d carried no DEAL_POSITION_ID, falling back to order ticket — verify this position manually.",
                  dealTicket);
      return m_trade.ResultOrder();
     }
   return positionId;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::MarketBuy(string symbol, double volume, double sl, double tp, ulong &ticketOut, double &fillPriceOut, string comment)
  {
   fillPriceOut = 0.0;
   // G6 FIX: zero out m_lastLatencyUs on every early refusal below —
   // otherwise LastLatencyMs() would report whatever the PREVIOUS
   // successful/failed broker call took, misleadingly attributed to
   // this call, which never actually reached the broker.
   if(!IsConnected()) { m_lastLatencyUs = 0; return false; }
   if(!IsMarketOpenForTrading(symbol, true)) { m_lastLatencyUs = 0; return false; }
   double refPrice = SymbolInfoDouble(symbol, SYMBOL_ASK); // a market buy fills near the ask
   if(!ValidateStopDistance(symbol, refPrice, sl, tp, true, "MarketBuy")) { m_lastLatencyUs = 0; return false; }

   ulong t0 = GetMicrosecondCount();
   for(int i = 0; i < m_maxRetries; i++)
     {
      if(m_trade.Buy(volume, symbol, 0.0, sl, tp, comment) && LastRequestOk("MarketBuy"))
        {
         ticketOut = ResolvePositionTicket();
         fillPriceOut = m_trade.ResultPrice();
         m_lastLatencyUs = GetMicrosecondCount() - t0;
         return true;
        }
      uint code = m_trade.ResultRetcode();
      if(!IsRetryable(code)) break; // LATENCY: terminal rejection — stop burning time on retries that can't succeed
      Sleep(DelayForRetcode(code));
     }
   m_lastLatencyUs = GetMicrosecondCount() - t0;
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::MarketSell(string symbol, double volume, double sl, double tp, ulong &ticketOut, double &fillPriceOut, string comment)
  {
   fillPriceOut = 0.0;
   if(!IsConnected()) { m_lastLatencyUs = 0; return false; }
   if(!IsMarketOpenForTrading(symbol, true)) { m_lastLatencyUs = 0; return false; }
   double refPrice = SymbolInfoDouble(symbol, SYMBOL_BID); // a market sell fills near the bid
   if(!ValidateStopDistance(symbol, refPrice, sl, tp, false, "MarketSell")) { m_lastLatencyUs = 0; return false; }

   ulong t0 = GetMicrosecondCount();
   for(int i = 0; i < m_maxRetries; i++)
     {
      if(m_trade.Sell(volume, symbol, 0.0, sl, tp, comment) && LastRequestOk("MarketSell"))
        {
         ticketOut = ResolvePositionTicket();
         fillPriceOut = m_trade.ResultPrice();
         m_lastLatencyUs = GetMicrosecondCount() - t0;
         return true;
        }
      uint code = m_trade.ResultRetcode();
      if(!IsRetryable(code)) break;
      Sleep(DelayForRetcode(code));
     }
   m_lastLatencyUs = GetMicrosecondCount() - t0;
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::PlaceLimit(string symbol, ENUM_ORDER_TYPE type, double volume, double price,
                                double sl, double tp, ulong &ticketOut, string comment)
  {
   if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT)
     {
      Print("MedisTouch BrokerAdapter: PlaceLimit called with a non-limit order type");
      return false;
     }
   bool isBuy = (type == ORDER_TYPE_BUY_LIMIT);
   if(!IsConnected()) { m_lastLatencyUs = 0; return false; }
   if(!IsMarketOpenForTrading(symbol, true)) { m_lastLatencyUs = 0; return false; }
   // Distance validated against the resting order's OWN price, not the
   // current market price — that's what the broker measures a pending
   // order's stop distance from.
   if(!ValidateStopDistance(symbol, price, sl, tp, isBuy, "PlaceLimit")) { m_lastLatencyUs = 0; return false; }

   ulong t0 = GetMicrosecondCount();
   for(int i = 0; i < m_maxRetries; i++)
     {
      bool ok = (type == ORDER_TYPE_BUY_LIMIT)
                  ? m_trade.BuyLimit(volume, price, symbol, sl, tp, ORDER_TIME_GTC, 0, comment)
                  : m_trade.SellLimit(volume, price, symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
      if(ok && LastRequestOk("PlaceLimit"))
        {
         ticketOut = m_trade.ResultOrder();
         m_lastLatencyUs = GetMicrosecondCount() - t0;
         return true;
        }
      uint code = m_trade.ResultRetcode();
      if(!IsRetryable(code)) break;
      Sleep(DelayForRetcode(code));
     }
   m_lastLatencyUs = GetMicrosecondCount() - t0;
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::CancelOrder(ulong ticket)
  {
   if(!IsConnected()) return false; // G6 FIX
   if(m_trade.OrderDelete(ticket)) return true;
   LastRequestOk("CancelOrder");
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::ModifySLTP(ulong ticket, double sl, double tp)
  {
   if(!IsConnected()) return false; // G6 FIX
   // G6 FIX: this is exactly where SYMBOL_TRADE_FREEZE_LEVEL bites
   // hardest in practice — moving a stop while price sits inside the
   // freeze zone around it is the single most common cause of a
   // real-money break-even/trailing-stop rejection. Needs the
   // position's own symbol and direction to validate against, which
   // this call didn't previously look up at all.
   if(!PositionSelectByTicket(ticket))
     {
      PrintFormat("MedisTouch BrokerAdapter: ModifySLTP refused — position #%d not found/selectable.", ticket);
      return false;
     }
   string symbol = PositionGetString(POSITION_SYMBOL);
   bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double refPrice = isBuy ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK); // the price a close would fill at
   if(!ValidateStopDistance(symbol, refPrice, sl, tp, isBuy, "ModifySLTP")) return false;

   if(m_trade.PositionModify(ticket, sl, tp)) return true;
   LastRequestOk("ModifySLTP");
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::ClosePartial(ulong ticket, double volume)
  {
   if(!IsConnected()) return false; // G6 FIX
   if(!PositionSelectByTicket(ticket))
     {
      PrintFormat("MedisTouch BrokerAdapter: ClosePartial refused — position #%d not found/selectable.", ticket);
      return false;
     }
   if(!IsMarketOpenForTrading(PositionGetString(POSITION_SYMBOL), false)) return false; // requireFullOpen=false -- CLOSEONLY is fine for a close, DISABLED still isn't
   if(m_trade.PositionClosePartial(ticket, volume)) return true;
   LastRequestOk("ClosePartial");
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::CloseFull(ulong ticket)
  {
   if(!IsConnected()) return false; // G6 FIX
   if(!PositionSelectByTicket(ticket))
     {
      PrintFormat("MedisTouch BrokerAdapter: CloseFull refused — position #%d not found/selectable.", ticket);
      return false;
     }
   if(!IsMarketOpenForTrading(PositionGetString(POSITION_SYMBOL), false)) return false;
   if(m_trade.PositionClose(ticket)) return true;
   LastRequestOk("CloseFull");
   return false;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Execution/BrokerAdapter.mqh ----

// ---- BEGIN EA/includes/Execution/OrderManager.mqh ----
//+------------------------------------------------------------------+
//|                                        Execution/OrderManager.mqh |
//+------------------------------------------------------------------+
#ifndef ORDERMANAGER_MQH
#define ORDERMANAGER_MQH

// ---- BEGIN EA/includes/Decision/TradeDecision.mqh ----

// ---- END EA/includes/Decision/TradeDecision.mqh ----


// ---- BEGIN EA/includes/Execution/TradeStateMachine.mqh ----
//+------------------------------------------------------------------+
//|                                  Execution/TradeStateMachine.mqh |
//+------------------------------------------------------------------+
#ifndef TRADESTATEMACHINE_MQH
#define TRADESTATEMACHINE_MQH

// ---- BEGIN EA/includes/Monitoring/ProductionMonitor.mqh ----
//+------------------------------------------------------------------+
//|                                 Monitoring/ProductionMonitor.mqh |
//+------------------------------------------------------------------+
#ifndef PRODUCTIONMONITOR_MQH
#define PRODUCTIONMONITOR_MQH

// Lightweight health surface for running unattended. This is NOT a
// dashboard — it has no UI of its own. It writes a heartbeat file an
// external watchdog (cron job, VPS monitor, whatever you already use)
// can tail to detect the EA going silent, and logs terminal warnings
// when the account itself starts showing signs of trouble. Deliberately
// simple: no alerting integrations (email/Telegram/etc.), since those
// each need their own credentials and are a natural layer ON TOP of
// this, not inside it — same anti-complexity rule as the rest of this
// codebase.
class CProductionMonitor
  {
private:
   string            m_heartbeatFile;
   string            m_symbol;
   datetime          m_startTime;
   datetime          m_lastHeartbeat;
   int               m_heartbeatIntervalSec;

   int               m_brokerRejectCount;
   int               m_illegalTransitionCount;
   double            m_peakEquity;
   double            m_maxDrawdownAlertPercent;
   bool              m_drawdownAlertFired;

   // LATENCY: running stats over every TS_DETECTED->TS_FILLED trade this
   // session. Running sum/count instead of storing every sample — this
   // runs unattended for weeks, an unbounded array of latency samples is
   // exactly the kind of thing that quietly bloats memory on a VPS.
   // "last" is what you want when something feels slow right now;
   // "avg"/"max" are what you want for a trend.
   int               m_latencySamples;
   double            m_latencyTotalSumMs;
   double            m_latencyTotalMaxMs;
   double            m_latencyLastTotalMs;
   double            m_latencyBrokerSumMs;
   double            m_latencyBrokerMaxMs;
   double            m_latencyLastBrokerMs;

public:
   void              Init(string symbol, int heartbeatIntervalSec, double maxDrawdownAlertPercent);
   void              OnTickCheck();             // call once per OnTick — cheap, cadence-gated internally
   void              NotifyBrokerReject();       // call when Submit()/BrokerAdapter reports a failed order
   void              NotifyIllegalTransition();  // hook for CTradeStateMachine's illegal-transition log — see note below
   // LATENCY: call once per fill from COrderManager::Submit(), right
   // after TS_FILLED. totalMs is TS_DETECTED->TS_FILLED (the number that
   // matters to you); brokerMs is CBrokerAdapter::LastLatencyMs() (the
   // slice of totalMs that was actually the broker round-trip, as
   // opposed to our own code between DETECTED and the order being sent).
   void              NotifyTradeLatency(double totalMs, double brokerMs);
   string            StatusSummary();
  };
//+------------------------------------------------------------------+
void CProductionMonitor::Init(string symbol, int heartbeatIntervalSec, double maxDrawdownAlertPercent)
  {
   m_symbol = symbol;
   m_heartbeatFile = "MedisTouch_Heartbeat_" + symbol + ".txt";
   m_startTime = TimeCurrent();
   m_lastHeartbeat = 0;
   m_heartbeatIntervalSec = heartbeatIntervalSec;
   m_brokerRejectCount = 0;
   m_illegalTransitionCount = 0;
   m_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   m_maxDrawdownAlertPercent = maxDrawdownAlertPercent;
   m_drawdownAlertFired = false;
   m_latencySamples = 0;
   m_latencyTotalSumMs = 0.0;
   m_latencyTotalMaxMs = 0.0;
   m_latencyLastTotalMs = -1.0;
   m_latencyBrokerSumMs = 0.0;
   m_latencyBrokerMaxMs = 0.0;
   m_latencyLastBrokerMs = -1.0;
  }
//+------------------------------------------------------------------+
void CProductionMonitor::NotifyBrokerReject() { m_brokerRejectCount++; }
//+------------------------------------------------------------------+
void CProductionMonitor::NotifyTradeLatency(double totalMs, double brokerMs)
  {
   m_latencySamples++;
   m_latencyLastTotalMs = totalMs;
   m_latencyTotalSumMs += totalMs;
   if(totalMs > m_latencyTotalMaxMs) m_latencyTotalMaxMs = totalMs;

   m_latencyLastBrokerMs = brokerMs;
   m_latencyBrokerSumMs += brokerMs;
   if(brokerMs > m_latencyBrokerMaxMs) m_latencyBrokerMaxMs = brokerMs;

   // Flag it immediately rather than waiting for the next heartbeat tick
   // — a single outlier fill is worth knowing about the moment it
   // happens, not up to m_heartbeatIntervalSec later.
   if(m_latencySamples > 0)
     {
      double avgMs = m_latencyTotalSumMs / m_latencySamples;
      if(totalMs > avgMs * 3.0 && m_latencySamples > 5)
         PrintFormat("MedisTouch Monitor: latency outlier — this fill took %.0fms (broker: %.0fms) vs a %.0fms running average.",
                     totalMs, brokerMs, avgMs);
     }
  }
//+------------------------------------------------------------------+
// C004 FIX: previously dead — nothing called this. CTradeStateMachine now
// holds a CProductionMonitor* (bound via BindMonitor(), see
// Execution/TradeStateMachine.mqh) and calls this from Transition() itself
// whenever IsLegal() rejects a move, instead of only Print()-ing it where
// no external watchdog can see. COrderManager binds every ManagedTrade's
// fsm to this monitor right after construction, in both Submit() and
// RestoreTrade().
void CProductionMonitor::NotifyIllegalTransition() { m_illegalTransitionCount++; }
//+------------------------------------------------------------------+
void CProductionMonitor::OnTickCheck()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > m_peakEquity) m_peakEquity = equity;

   double drawdownPercent = (m_peakEquity > 0) ? (m_peakEquity - equity) / m_peakEquity * 100.0 : 0.0;
   if(drawdownPercent >= m_maxDrawdownAlertPercent && !m_drawdownAlertFired)
     {
      PrintFormat("MedisTouch Monitor: ALERT — drawdown from peak equity is %.2f%%, at or past the %.2f%% alert threshold.",
                  drawdownPercent, m_maxDrawdownAlertPercent);
      m_drawdownAlertFired = true;
     }
   else if(drawdownPercent < m_maxDrawdownAlertPercent * 0.5 && m_drawdownAlertFired)
      m_drawdownAlertFired = false; // recovered well clear of the threshold — allow the alert to fire again if it recurs

   datetime now = TimeCurrent();
   if(now - m_lastHeartbeat < m_heartbeatIntervalSec) return;
   m_lastHeartbeat = now;

   double avgTotalMs = (m_latencySamples > 0) ? m_latencyTotalSumMs / m_latencySamples : 0.0;
   double avgBrokerMs = (m_latencySamples > 0) ? m_latencyBrokerSumMs / m_latencySamples : 0.0;

   int handle = FileOpen(m_heartbeatFile, FILE_WRITE | FILE_TXT);
   if(handle == INVALID_HANDLE) return;
   FileWriteString(handle, StringFormat(
      "symbol=%s\nlast_heartbeat=%s\nuptime_sec=%d\nequity=%.2f\npeak_equity=%.2f\ndrawdown_pct=%.2f\n"
      "broker_rejects=%d\nillegal_transitions=%d\n"
      "latency_samples=%d\nlatency_last_total_ms=%.0f\nlatency_avg_total_ms=%.0f\nlatency_max_total_ms=%.0f\n"
      "latency_last_broker_ms=%.0f\nlatency_avg_broker_ms=%.0f\nlatency_max_broker_ms=%.0f\n",
      m_symbol, TimeToString(now, TIME_DATE | TIME_SECONDS), (int)(now - m_startTime),
      equity, m_peakEquity, drawdownPercent, m_brokerRejectCount, m_illegalTransitionCount,
      m_latencySamples, m_latencyLastTotalMs, avgTotalMs, m_latencyTotalMaxMs,
      m_latencyLastBrokerMs, avgBrokerMs, m_latencyBrokerMaxMs));
   FileClose(handle);
  }
//+------------------------------------------------------------------+
string CProductionMonitor::StatusSummary()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double drawdownPercent = (m_peakEquity > 0) ? (m_peakEquity - equity) / m_peakEquity * 100.0 : 0.0;
   double avgTotalMs = (m_latencySamples > 0) ? m_latencyTotalSumMs / m_latencySamples : 0.0;
   return StringFormat("MedisTouch [%s] uptime=%ds equity=%.2f drawdown=%.2f%% rejects=%d illegalTransitions=%d avgFillLatencyMs=%.0f (n=%d)",
                       m_symbol, (int)(TimeCurrent() - m_startTime), equity, drawdownPercent,
                       m_brokerRejectCount, m_illegalTransitionCount, avgTotalMs, m_latencySamples);
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Monitoring/ProductionMonitor.mqh ----

enum ENUM_TRADE_STATE
  {
   TS_DETECTED,   // setup produced by analysis, not yet routed through the Decision Engine
   TS_VALIDATED,  // Policy Engine approved execution
   TS_WAITING,    // approved, waiting for price to reach the entry zone (pending-order path)
   TS_PENDING,    // order sent to the broker, not yet filled
   TS_FILLED,     // position open, still at original SL/TP
   TS_PROTECTED,  // stop moved to break-even
   TS_PARTIAL,    // partial close taken at TP1
   TS_RUNNER,     // remainder trailing toward final_tp
   TS_CLOSED,     // position fully closed (SL, TP, trail, or manual)
   TS_ARCHIVED,   // closed trade written to the journal, no longer polled
   TS_CANCELLED,  // pending order cancelled or setup invalidated before fill
   TS_REJECTED    // broker rejected the order
  };
//+------------------------------------------------------------------+
string TradeStateToString(ENUM_TRADE_STATE s)
  {
   switch(s)
     {
      case TS_DETECTED:  return "Detected";
      case TS_VALIDATED: return "Validated";
      case TS_WAITING:   return "Waiting";
      case TS_PENDING:   return "Pending";
      case TS_FILLED:    return "Filled";
      case TS_PROTECTED: return "Protected";
      case TS_PARTIAL:   return "Partial";
      case TS_RUNNER:    return "Runner";
      case TS_CLOSED:    return "Closed";
      case TS_ARCHIVED:  return "Archived";
      case TS_CANCELLED: return "Cancelled";
      case TS_REJECTED:  return "Rejected";
     }
   return "Unknown";
  }
//+------------------------------------------------------------------+
// One instance per live trade, from decision through archive. Every state
// change goes through Transition(), which enforces the legal-move table
// below instead of six different call sites setting a flag directly and
// silently drifting out of sync with each other.
class CTradeStateMachine
  {
private:
   ENUM_TRADE_STATE  m_state;
   long              m_decisionId;
   ulong             m_ticket;      // order/position ticket, once one exists
   datetime          m_lastChange;
   CProductionMonitor* m_monitor;   // C004 FIX: was permanently NULL — nothing ever bound one. See BindMonitor().

   // LATENCY: datetime (m_lastChange) is second-resolution — useless for
   // measuring anything inside a single tick. GetMicrosecondCount() gives
   // a monotonic microsecond counter (wraps at ~71 minutes on a 32-bit
   // wrap of the underlying uint, which MQL5 handles by returning a
   // ulong that keeps counting — safe to subtract across a live trade's
   // lifetime, which is always far shorter than that). Only the four
   // stage transitions on the confirmation->execution path are stamped;
   // everything past TS_FILLED (break-even, partials, trailing) isn't
   // part of "trade confirmation and execution" latency and stays on
   // m_lastChange only, same as before.
   ulong             m_usDetected;
   ulong             m_usValidated;
   ulong             m_usPending;
   ulong             m_usFilled;

   bool              IsLegal(ENUM_TRADE_STATE from, ENUM_TRADE_STATE to);
   void              StampStage(ENUM_TRADE_STATE to);

public:
                     CTradeStateMachine();
   void              Start(long decisionId);
   // C004 FIX: this used to be a dead hook — CProductionMonitor::NotifyIllegalTransition()
   // existed and worked, but no CTradeStateMachine instance ever held a reference to call
   // it with, since each one is default-constructed inside the ManagedTrade array (Submit()/
   // RestoreTrade() in OrderManager.mqh) with no monitor available at construction time.
   // BindMonitor() is the mechanical fix the audit called out: call it once right after
   // Start(), from every place a ManagedTrade is created, and illegal transitions start
   // actually incrementing the monitor's counter and showing up in the heartbeat file
   // instead of only ever reaching a Print() no external watchdog can see.
   void              BindMonitor(CProductionMonitor *monitor) { m_monitor = monitor; }
   bool              Transition(ENUM_TRADE_STATE to);
   void              ForceState(ENUM_TRADE_STATE to); // RECOVERY ONLY — bypasses IsLegal(). Recovery reconstructs
                                                        // state from broker-side evidence (position SL vs entry,
                                                        // current volume vs submitted volume), not from a live
                                                        // decision walking through its normal sequence — so there is
                                                        // no "from" state to validate a transition against. Anything
                                                        // other than Recovery calling this defeats the entire point
                                                        // of the legal-transition table above.
   ENUM_TRADE_STATE  State() const { return m_state; }
   long              DecisionId() const { return m_decisionId; }
   void              SetTicket(ulong ticket) { m_ticket = ticket; }
   ulong             Ticket() const { return m_ticket; }
   datetime          LastChange() const { return m_lastChange; }

   // LATENCY: millisecond breakdowns of the confirmation->execution path.
   // Returns -1.0 when the relevant stage(s) haven't happened yet (e.g.
   // querying ConfirmationLatencyMs() before TS_VALIDATED is reached, or
   // any of these on a signal-only decision that never reaches
   // TS_PENDING/TS_FILLED) instead of a misleading 0.0 or a huge
   // underflowed ulong from subtracting an unset (zero) timestamp.
   //   ConfirmationLatencyMs: TS_DETECTED -> TS_VALIDATED (policy engine's own decision time)
   //   SubmitLatencyMs:       TS_VALIDATED -> TS_PENDING  (our code, between approval and sending the order)
   //   ExecutionLatencyMs:    TS_PENDING -> TS_FILLED     (broker round-trip, includes any retries)
   //   TotalLatencyMs:        TS_DETECTED -> TS_FILLED    (the end-to-end number that actually matters)
   double            ConfirmationLatencyMs() const
     { return (m_usDetected > 0 && m_usValidated > 0) ? (double)(m_usValidated - m_usDetected) / 1000.0 : -1.0; }
   double            SubmitLatencyMs() const
     { return (m_usValidated > 0 && m_usPending > 0) ? (double)(m_usPending - m_usValidated) / 1000.0 : -1.0; }
   double            ExecutionLatencyMs() const
     { return (m_usPending > 0 && m_usFilled > 0) ? (double)(m_usFilled - m_usPending) / 1000.0 : -1.0; }
   double            TotalLatencyMs() const
     { return (m_usDetected > 0 && m_usFilled > 0) ? (double)(m_usFilled - m_usDetected) / 1000.0 : -1.0; }
  };
//+------------------------------------------------------------------+
CTradeStateMachine::CTradeStateMachine()
  {
   m_state = TS_DETECTED;
   m_decisionId = 0;
   m_ticket = 0;
   m_lastChange = 0;
   m_monitor = NULL;
   m_usDetected = 0;
   m_usValidated = 0;
   m_usPending = 0;
   m_usFilled = 0;
  }
//+------------------------------------------------------------------+
void CTradeStateMachine::Start(long decisionId)
  {
   m_decisionId = decisionId;
   m_state = TS_DETECTED;
   m_ticket = 0;
   m_lastChange = TimeCurrent();
   m_usDetected = GetMicrosecondCount();
   m_usValidated = 0;
   m_usPending = 0;
   m_usFilled = 0;
  }
//+------------------------------------------------------------------+
// Stamps only the four states latency actually tracks. Deliberately a
// separate step from the legality check in Transition() — ForceState()
// (recovery) calls this too, but recovery timestamps are meaningless
// (the trade didn't just pass through that state, it's being
// reconstructed from broker-side evidence possibly days later), so
// ForceState() does NOT call this — see its body below.
void CTradeStateMachine::StampStage(ENUM_TRADE_STATE to)
  {
   ulong now = GetMicrosecondCount();
   switch(to)
     {
      case TS_VALIDATED: m_usValidated = now; break;
      case TS_PENDING:    m_usPending = now;  break;
      case TS_FILLED:     m_usFilled = now;   break;
      default: break; // every other state is outside the latency path
     }
  }
//+------------------------------------------------------------------+
bool CTradeStateMachine::IsLegal(ENUM_TRADE_STATE from, ENUM_TRADE_STATE to)
  {
   switch(from)
     {
      case TS_DETECTED:  return (to == TS_VALIDATED || to == TS_CANCELLED);
      case TS_VALIDATED: return (to == TS_WAITING || to == TS_PENDING || to == TS_CANCELLED);
      case TS_WAITING:   return (to == TS_PENDING || to == TS_CANCELLED);
      case TS_PENDING:   return (to == TS_FILLED || to == TS_CANCELLED || to == TS_REJECTED);
      case TS_FILLED:    return (to == TS_PROTECTED || to == TS_PARTIAL || to == TS_CLOSED);
      case TS_PROTECTED: return (to == TS_PARTIAL || to == TS_CLOSED);
      case TS_PARTIAL:   return (to == TS_RUNNER || to == TS_CLOSED);
      case TS_RUNNER:    return (to == TS_CLOSED);
      case TS_CLOSED:    return (to == TS_ARCHIVED);
      default:           return false; // ARCHIVED / CANCELLED / REJECTED are terminal
     }
  }
//+------------------------------------------------------------------+
bool CTradeStateMachine::Transition(ENUM_TRADE_STATE to)
  {
   if(!IsLegal(m_state, to))
     {
      PrintFormat("MedisTouch StateMachine: illegal transition %s -> %s (decision #%d)",
                  TradeStateToString(m_state), TradeStateToString(to), m_decisionId);
      if(m_monitor != NULL) m_monitor.NotifyIllegalTransition();
      return false;
     }
   m_state = to;
   m_lastChange = TimeCurrent();
   StampStage(to);
   return true;
  }
//+------------------------------------------------------------------+
void CTradeStateMachine::ForceState(ENUM_TRADE_STATE to)
  {
   PrintFormat("MedisTouch StateMachine: recovery force-state %s -> %s (decision #%d) — bypassing legality check",
               TradeStateToString(m_state), TradeStateToString(to), m_decisionId);
   m_state = to;
   m_lastChange = TimeCurrent();
   // No StampStage() here on purpose — see the comment on StampStage().
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Execution/TradeStateMachine.mqh ----


// ---- BEGIN EA/includes/Execution/BrokerAdapter.mqh ----

// ---- END EA/includes/Execution/BrokerAdapter.mqh ----

// One decision's full order lifecycle: the immutable decision it came
// from, its state machine, and the volume actually sized for it.
struct ManagedTrade
  {
   TradeDecisionRecord  decision;
   CTradeStateMachine   fsm;
   double               volume;
   double               fillPrice; // FIX (#25): actual broker fill, 0 until known / for restored trades
  };
//+------------------------------------------------------------------+
// Owns every ManagedTrade from Submit() through FILLED/REJECTED/
// CANCELLED. Everything past FILLED (break-even, partials, trailing) is
// CPositionManager's job — this class exposes read/mutate accessors
// instead of the raw array so PositionManager never needs its own copy of
// the trade list.
class COrderManager
  {
private:
   CBrokerAdapter*     m_broker;
   ManagedTrade        m_trades[];
   int                 m_maxOpen;
   CProductionMonitor* m_monitor; // C004 FIX: threaded through so every fsm gets bound — see BindMonitor() call sites below

   int               FindByDecisionId(long id);

public:
   void              Init(CBrokerAdapter* broker, int maxOpenTrades, CProductionMonitor* monitor);
   // FIX (audit #25): maxEntryDeviation is a PRICE distance (caller
   // converts from ATR). Submit() rejects a market order outright if the
   // current market price has already moved further than this from the
   // theoretical entry the setup/risk math was built on -- a pre-trade
   // guard against filling a stale signal at a materially worse price.
   bool              Submit(const TradeDecisionRecord &decision, double volume, bool useMarket, double maxEntryDeviation, ulong &ticketOut);
   bool              RestoreTrade(const TradeDecisionRecord &decision, double volume, ulong ticket, ENUM_TRADE_STATE state);
   int               OpenCount();
   int               Total() { return ArraySize(m_trades); }
   void              Prune();  // drop ARCHIVED/CANCELLED/REJECTED rows to keep the array bounded
   bool              MarkFilledFromPending(ulong orderTicket, ulong positionTicket, double fillPrice = 0.0);

   // Accessors used by PositionManager instead of direct array access.
   ENUM_TRADE_STATE     StateAt(int idx)              { return m_trades[idx].fsm.State(); }
   ulong                TicketAt(int idx)              { return m_trades[idx].fsm.Ticket(); }
   TradeDecisionRecord  DecisionAt(int idx)            { return m_trades[idx].decision; }
   double               VolumeAt(int idx)              { return m_trades[idx].volume; }
   bool                 TransitionAt(int idx, ENUM_TRADE_STATE to) { return m_trades[idx].fsm.Transition(to); }
   // FIX (#25): real fill for R-multiple/break-even math -- falls back to
   // the theoretical entry only if a fill somehow left this at 0 (e.g. a
   // restored trade from before this field existed).
   double               FillPriceAt(int idx)
     {
      if(m_trades[idx].fillPrice > 0.0) return m_trades[idx].fillPrice;
      bool isBuy = (m_trades[idx].decision.setup.type == ORDER_TYPE_BUY);
      return isBuy ? m_trades[idx].decision.setup.entry_top : m_trades[idx].decision.setup.entry_bottom;
     }
  };
//+------------------------------------------------------------------+
void COrderManager::Init(CBrokerAdapter* broker, int maxOpenTrades, CProductionMonitor* monitor)
  {
   m_broker = broker;
   m_maxOpen = maxOpenTrades;
   m_monitor = monitor;
   ArrayResize(m_trades, 0);
  }
//+------------------------------------------------------------------+
int COrderManager::FindByDecisionId(long id)
  {
   for(int i = 0; i < ArraySize(m_trades); i++)
      if(m_trades[i].decision.decision_id == id) return i;
   return -1;
  }
//+------------------------------------------------------------------+
int COrderManager::OpenCount()
  {
   int c = 0;
   for(int i = 0; i < ArraySize(m_trades); i++)
     {
      ENUM_TRADE_STATE s = m_trades[i].fsm.State();
      if(s == TS_PENDING || s == TS_FILLED || s == TS_PROTECTED || s == TS_PARTIAL || s == TS_RUNNER)
         c++;
     }
   return c;
  }
//+------------------------------------------------------------------+
void COrderManager::Prune()
  {
   ManagedTrade kept[];
   int n = 0;
   ArrayResize(kept, ArraySize(m_trades));
   for(int i = 0; i < ArraySize(m_trades); i++)
     {
      ENUM_TRADE_STATE s = m_trades[i].fsm.State();
      if(s == TS_ARCHIVED || s == TS_CANCELLED || s == TS_REJECTED) continue;
      kept[n++] = m_trades[i];
     }
   ArrayResize(kept, n);
   ArrayResize(m_trades, n);
   for(int i = 0; i < n; i++) m_trades[i] = kept[i];
  }
//+------------------------------------------------------------------+
// C003 FIX: closes the gap the audit flagged — a resting limit order
// (TS_PENDING, ticket = the ORDER ticket from PlaceLimit) that fills
// while the EA is running was previously invisible to PositionManager
// until the next Recovery() at restart, because nothing ever moved it to
// TS_FILLED or swapped its ticket over to the real POSITION ticket.
// Called from OnTradeTransaction() on TRADE_TRANSACTION_DEAL_ADD, the
// instant MT5 reports the fill — not polled, not deferred to restart.
// Market fills are unaffected: Submit() already transitions those to
// TS_FILLED synchronously in the same call that sends the order.
bool COrderManager::MarkFilledFromPending(ulong orderTicket, ulong positionTicket, double fillPrice)
  {
   for(int i = 0; i < ArraySize(m_trades); i++)
     {
      if(m_trades[i].fsm.State() != TS_PENDING) continue;
      if(m_trades[i].fsm.Ticket() != orderTicket) continue;

      m_trades[i].fsm.SetTicket(positionTicket); // pending-order ticket -> live position ticket
      if(fillPrice > 0.0) m_trades[i].fillPrice = fillPrice; // FIX (#25): capture the real fill for a limit order too, not just market orders
      bool filled = m_trades[i].fsm.Transition(TS_FILLED);
      // LATENCY: same reporting Submit() does for market fills, for the
      // limit-order fill path. No BrokerAdapter round-trip happened here
      // (MT5 filled the resting order server-side, this call is just us
      // finding out about it), so there's no broker-latency component to
      // pass — 0.0 makes that explicit rather than reusing whatever
      // CBrokerAdapter::LastLatencyMs() happens to hold from an
      // unrelated, possibly much earlier, call.
      if(filled && m_monitor != NULL)
        {
         double totalMs = m_trades[i].fsm.TotalLatencyMs();
         if(totalMs >= 0.0) m_monitor.NotifyTradeLatency(totalMs, 0.0);
        }
      return filled;
     }
   return false; // no matching pending trade — not ours, or already handled
  }
//+------------------------------------------------------------------+
bool COrderManager::Submit(const TradeDecisionRecord &decision, double volume, bool useMarket, double maxEntryDeviation, ulong &ticketOut)
  {
   ticketOut = 0;
   if(decision.action != POLICY_EXECUTE_ONLY && decision.action != POLICY_EXECUTE_AND_SIGNAL)
      return false;
   if(volume <= 0)
     {
      PrintFormat("MedisTouch OrderManager: decision #%d has non-positive volume, skipped", decision.decision_id);
      return false;
     }
   if(OpenCount() >= m_maxOpen)
     {
      PrintFormat("MedisTouch OrderManager: max open trades (%d) reached, decision #%d skipped",
                  m_maxOpen, decision.decision_id);
      return false;
     }
   if(FindByDecisionId(decision.decision_id) >= 0) return false; // already submitted, don't double-fire

   double entry = ResolveExecutionEntry(decision.setup); // Core/Config.mqh — same price ValidateSetup() gated against

   // FIX (#25): pre-trade staleness guard. A signal can sit for several
   // ticks between "setup generated" and "order submitted" (scoring,
   // portfolio gate, lot sizing all run in between). If the market has
   // already moved past this decision's entry by more than the caller's
   // tolerance, reject rather than filling at an unknown, unbounded worse
   // price. useMarket only -- a limit order at `entry` either fills at
   // that price or doesn't fill at all, so it doesn't need this guard.
   if(useMarket && maxEntryDeviation > 0.0)
     {
      MqlTick tick;
      if(SymbolInfoTick(decision.symbol, tick))
        {
         double marketPrice = (decision.setup.type == ORDER_TYPE_BUY) ? tick.ask : tick.bid;
         double deviation = MathAbs(marketPrice - entry);
         if(deviation > maxEntryDeviation)
           {
            PrintFormat("MedisTouch OrderManager: decision #%d rejected — market price %.5f has drifted %.5f from decision entry %.5f (max allowed %.5f). Signal is stale.",
                        decision.decision_id, marketPrice, deviation, entry, maxEntryDeviation);
            return false;
           }
        }
     }

   // Tag every order with its decision ID so a restarted terminal can
   // match a live position/pending order straight back to the exact
   // TradeDecisionRecord that created it, via CDecisionStore. This is
   // the entire matching key Recovery depends on.
   string tag = "MT#" + IntegerToString(decision.decision_id);

   int idx = ArraySize(m_trades);
   ArrayResize(m_trades, idx + 1);
   m_trades[idx].decision = decision;
   m_trades[idx].volume = volume;
   m_trades[idx].fillPrice = 0.0;
   m_trades[idx].fsm.Start(decision.decision_id);
   m_trades[idx].fsm.BindMonitor(m_monitor);
   m_trades[idx].fsm.Transition(TS_VALIDATED);

   double sl = decision.setup.stop_loss;
   double tp = decision.setup.final_tp;
   ulong ticket = 0;
   double fillPrice = 0.0;
   bool ok = false;

   if(useMarket)
     {
      m_trades[idx].fsm.Transition(TS_PENDING);
      if(decision.setup.type == ORDER_TYPE_BUY)
         ok = m_broker.MarketBuy(decision.symbol, volume, sl, tp, ticket, fillPrice, tag);
      else
         ok = m_broker.MarketSell(decision.symbol, volume, sl, tp, ticket, fillPrice, tag);

      if(ok)
        {
         m_trades[idx].fsm.SetTicket(ticket);
         m_trades[idx].fsm.Transition(TS_FILLED);
         m_trades[idx].fillPrice = fillPrice;
         double slippage = fillPrice - entry;
         if(MathAbs(slippage) > 0.0)
            PrintFormat("MedisTouch OrderManager: decision #%d filled at %.5f (theoretical entry %.5f, slippage %.5f).",
                        decision.decision_id, fillPrice, entry, slippage);
         // LATENCY: report the end-to-end DETECTED->FILLED time and the
         // broker-only slice of it. TotalLatencyMs() can come back -1.0
         // if TS_DETECTED's stamp was somehow never set (shouldn't
         // happen — Start() always sets it — but NotifyTradeLatency()
         // isn't worth calling with a nonsense negative number).
         double totalMs = m_trades[idx].fsm.TotalLatencyMs();
         if(m_monitor != NULL && totalMs >= 0.0)
            m_monitor.NotifyTradeLatency(totalMs, m_broker.LastLatencyMs());
        }
      else
         m_trades[idx].fsm.Transition(TS_REJECTED);
     }
   else
     {
      m_trades[idx].fsm.Transition(TS_WAITING);
      m_trades[idx].fsm.Transition(TS_PENDING);
      ENUM_ORDER_TYPE limitType = (decision.setup.type == ORDER_TYPE_BUY) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
      ok = m_broker.PlaceLimit(decision.symbol, limitType, volume, entry, sl, tp, ticket, tag);
      if(ok)
         m_trades[idx].fsm.SetTicket(ticket);
      else
         m_trades[idx].fsm.Transition(TS_REJECTED);
     }

   if(ok) ticketOut = ticket;
   return ok;
  }
//+------------------------------------------------------------------+
// RECOVERY ONLY — rebuilds a ManagedTrade from broker-side truth (an
// already-live position or pending order) instead of creating one via
// Submit()'s normal decide-then-execute path. No broker call happens
// here; the trade already exists at the broker, this just makes
// OrderManager's in-memory bookkeeping match it again after a restart.
bool COrderManager::RestoreTrade(const TradeDecisionRecord &decision, double volume, ulong ticket, ENUM_TRADE_STATE state)
  {
   if(FindByDecisionId(decision.decision_id) >= 0)
      return false; // already tracked this run — don't create a duplicate row

   int idx = ArraySize(m_trades);
   ArrayResize(m_trades, idx + 1);
   m_trades[idx].decision = decision;
   m_trades[idx].volume = volume;
   m_trades[idx].fillPrice = 0.0; // unknown for a restored trade -- FillPriceAt() falls back to theoretical entry
   m_trades[idx].fsm.Start(decision.decision_id);
   m_trades[idx].fsm.BindMonitor(m_monitor);
   m_trades[idx].fsm.SetTicket(ticket);
   m_trades[idx].fsm.ForceState(state);
   return true;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Execution/OrderManager.mqh ----

// ---- BEGIN EA/includes/Execution/PositionManager.mqh ----
//+------------------------------------------------------------------+
//|                                     Execution/PositionManager.mqh |
//+------------------------------------------------------------------+
#ifndef POSITIONMANAGER_MQH
#define POSITIONMANAGER_MQH

// ---- BEGIN EA/includes/Execution/OrderManager.mqh ----

// ---- END EA/includes/Execution/OrderManager.mqh ----


// ---- BEGIN EA/includes/Execution/BrokerAdapter.mqh ----

// ---- END EA/includes/Execution/BrokerAdapter.mqh ----

// Everything that happens to a trade AFTER OrderManager gets it to
// FILLED: break-even, partial close at TP1, trailing the runner, and
// detecting closure. State order matches the documented lifecycle:
// Filled -> Protected -> Partial -> Runner -> Closed -> Archived.
class CPositionManager
  {
private:
   COrderManager*    m_orders;
   CBrokerAdapter*   m_broker;
   double            m_breakEvenAtR;      // move SL to entry once price is this many R in favor
   double            m_partialAtR;        // take TP1 partial once price is this many R in favor
   double            m_partialFraction;   // fraction of volume closed at TP1 (e.g. 0.5)
   double            m_trailAtrMult;      // runner trail distance, as an ATR multiple

   double            CurrentExitPrice(string symbol, bool isBuy);
   // FIX (#25): now takes the actual entry price explicitly (real fill,
   // via COrderManager::FillPriceAt) instead of deriving it from
   // dec.setup -- the theoretical FVG-edge entry is not what the
   // position is actually sitting on.
   double            RMultiple(const TradeDecisionRecord &dec, double entry, double price);

public:
   void              Init(COrderManager* orders, CBrokerAdapter* broker,
                          double breakEvenAtR, double partialAtR, double partialFraction, double trailAtrMult);
   void              OnTick(double currentAtr);
  };
//+------------------------------------------------------------------+
void CPositionManager::Init(COrderManager* orders, CBrokerAdapter* broker,
                            double breakEvenAtR, double partialAtR, double partialFraction, double trailAtrMult)
  {
   m_orders = orders;
   m_broker = broker;
   m_breakEvenAtR = breakEvenAtR;
   m_partialAtR = partialAtR;
   m_partialFraction = partialFraction;
   m_trailAtrMult = trailAtrMult;
  }
//+------------------------------------------------------------------+
double CPositionManager::CurrentExitPrice(string symbol, bool isBuy)
  {
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick)) return 0.0;
   // Closing a long sells at bid; closing a short buys at ask.
   return isBuy ? tick.bid : tick.ask;
  }
//+------------------------------------------------------------------+
double CPositionManager::RMultiple(const TradeDecisionRecord &dec, double entry, double price)
  {
   bool isBuy = (dec.setup.type == ORDER_TYPE_BUY);
   double riskDist = MathAbs(entry - dec.setup.stop_loss);
   if(riskDist <= 0) return 0.0;
   double moveInFavor = isBuy ? (price - entry) : (entry - price);
   return moveInFavor / riskDist;
  }
//+------------------------------------------------------------------+
void CPositionManager::OnTick(double currentAtr)
  {
   for(int i = 0; i < m_orders.Total(); i++)
     {
      ENUM_TRADE_STATE state = m_orders.StateAt(i);
      if(state != TS_FILLED && state != TS_PROTECTED && state != TS_PARTIAL && state != TS_RUNNER)
         continue;

      ulong ticket = m_orders.TicketAt(i);
      if(!PositionSelectByTicket(ticket))
        {
         // Position is gone (SL/TP/manual close) — archive it and move on.
         m_orders.TransitionAt(i, TS_CLOSED);
         m_orders.TransitionAt(i, TS_ARCHIVED);
         continue;
        }

      TradeDecisionRecord dec = m_orders.DecisionAt(i);
      bool isBuy = (dec.setup.type == ORDER_TYPE_BUY);
      double entry = m_orders.FillPriceAt(i); // FIX (#25): actual fill, not the theoretical FVG edge
      double price = CurrentExitPrice(dec.symbol, isBuy);
      if(price <= 0) continue;
      double r = RMultiple(dec, entry, price);

      // 1. Break-even -- moves SL to the price this position ACTUALLY
      // entered at. Moving it to the theoretical entry instead (the old
      // behavior) could leave a "protected" trade still sitting at a
      // real loss if the fill was worse than the signal's theoretical
      // price.
      if(state == TS_FILLED && r >= m_breakEvenAtR)
        {
         if(m_broker.ModifySLTP(ticket, entry, dec.setup.final_tp))
            m_orders.TransitionAt(i, TS_PROTECTED);
        }

      // 2. Partial (only after break-even, matching the documented order).
      // NOTE (#26, flagged not "fixed"): this fires at m_partialAtR (e.g.
      // 2R), a fixed R-multiple -- not at dec.setup.tp1. TP1/TP2 are
      // liquidity-derived DISPLAY targets for the dashboard/signal feed;
      // they were never the live partial-close trigger, and a liquidity
      // level isn't guaranteed to be a good partial-exit point on every
      // setup. Real distinction, not a bug to silently paper over.
      if(state == TS_PROTECTED && r >= m_partialAtR)
        {
         double vol = m_orders.VolumeAt(i) * m_partialFraction;
         double minVol = SymbolInfoDouble(dec.symbol, SYMBOL_VOLUME_MIN);
         if(vol >= minVol && m_broker.ClosePartial(ticket, vol))
            m_orders.TransitionAt(i, TS_PARTIAL);
        }

      // 3. Hand the remainder off as a trailing runner
      if(state == TS_PARTIAL)
         m_orders.TransitionAt(i, TS_RUNNER);

      // 4. Trail the runner — only ever tighten, never widen, the stop
      if(state == TS_RUNNER && currentAtr > 0)
        {
         double newSL = isBuy ? price - m_trailAtrMult * currentAtr : price + m_trailAtrMult * currentAtr;
         double curSL = PositionGetDouble(POSITION_SL);
         bool improved = isBuy ? (newSL > curSL) : (newSL < curSL);
         if(improved)
            m_broker.ModifySLTP(ticket, newSL, dec.setup.final_tp);
        }
     }
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Execution/PositionManager.mqh ----

// ---- BEGIN EA/includes/Recovery/RecoveryEngine.mqh ----
//+------------------------------------------------------------------+
//|                                        Recovery/RecoveryEngine.mqh |
//+------------------------------------------------------------------+
#ifndef RECOVERYENGINE_MQH
#define RECOVERYENGINE_MQH

// ---- BEGIN EA/includes/Decision/DecisionStore.mqh ----

// ---- END EA/includes/Decision/DecisionStore.mqh ----


// ---- BEGIN EA/includes/Execution/OrderManager.mqh ----

// ---- END EA/includes/Execution/OrderManager.mqh ----


// ---- BEGIN EA/includes/Execution/TradeStateMachine.mqh ----

// ---- END EA/includes/Execution/TradeStateMachine.mqh ----

// Runs once, at OnInit, after every other manager is constructed. An MT5
// restart (terminal crash, VPS reboot, manual restart, a broker server
// bounce) does not touch open positions or pending orders at the broker
// — only this EA's in-memory bookkeeping (COrderManager's array, each
// trade's state machine) is lost. Without this, a restarted EA either
// treats a live position as unknown and never manages it again (no
// break-even, no partial, no trailing — it just sits there), or worse,
// re-decides the same setup and doubles up.
//
// Matching key: the order comment set at submission time, "MT#<decision
// id>" (see OrderManager::Submit / BrokerAdapter). Every live position
// and pending order under this EA's magic number+symbol is inspected;
// its comment is parsed back to a decision ID, looked up in
// CDecisionStore for the full original setup, cross-referenced against
// the executions log for the volume actually submitted, and pushed back
// into COrderManager via RestoreTrade().
//
// State inference on restore is deliberately conservative. Which of
// FILLED / PROTECTED / PARTIAL / RUNNER a position currently sits in
// isn't recorded anywhere broker-side, so this infers it from what the
// broker DOES expose:
//   - current SL vs. the recorded entry price -> break-even taken or not
//   - current position volume vs. the originally submitted volume ->
//     partial taken or not
// This can't distinguish every edge case perfectly (e.g. a manually
// moved SL that happens to sit at breakeven), but it never invents a
// MORE advanced state than the evidence supports — PositionManager's own
// per-tick logic then just continues driving the trade forward from
// wherever it actually is. That's the safe direction to be wrong in.
class CRecoveryEngine
  {
private:
   CDecisionStore*   m_store;
   COrderManager*    m_orders;
   ulong             m_magic;
   string            m_symbol;

   bool              ParseDecisionId(string comment, long &idOut);
   ENUM_TRADE_STATE  InferPositionState(double submittedVolume, double currentVolume,
                                        double entryPrice, double currentSL, bool isBuy);

public:
   void              Init(CDecisionStore* store, COrderManager* orders, ulong magic, string symbol);
   int               Recover(); // returns count of trades restored
  };
//+------------------------------------------------------------------+
void CRecoveryEngine::Init(CDecisionStore* store, COrderManager* orders, ulong magic, string symbol)
  {
   m_store = store;
   m_orders = orders;
   m_magic = magic;
   m_symbol = symbol;
  }
//+------------------------------------------------------------------+
bool CRecoveryEngine::ParseDecisionId(string comment, long &idOut)
  {
   idOut = 0;
   if(StringSubstr(comment, 0, 3) != "MT#") return false;
   string numPart = StringSubstr(comment, 3);
   if(StringLen(numPart) == 0) return false;
   idOut = (long)StringToInteger(numPart);
   return idOut > 0;
  }
//+------------------------------------------------------------------+
ENUM_TRADE_STATE CRecoveryEngine::InferPositionState(double submittedVolume, double currentVolume,
                                                     double entryPrice, double currentSL, bool isBuy)
  {
   bool partialTaken = (submittedVolume > 0 && currentVolume < submittedVolume - 0.0000001);

   bool atOrPastBreakEven = isBuy ? (currentSL >= entryPrice - 0.0000001)
                                  : (currentSL <= entryPrice + 0.0000001);
   if(currentSL == 0) atOrPastBreakEven = false; // no stop set at all — don't misread that as "at break-even"

   if(partialTaken) return TS_RUNNER;       // partial only ever fires from PROTECTED in this EA's own flow
   if(atOrPastBreakEven) return TS_PROTECTED;
   return TS_FILLED;
  }
//+------------------------------------------------------------------+
int CRecoveryEngine::Recover()
  {
   int restored = 0;

   // --- Open positions ---
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != m_symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != m_magic) continue;

      long decisionId;
      if(!ParseDecisionId(PositionGetString(POSITION_COMMENT), decisionId))
        {
         PrintFormat("MedisTouch Recovery: open position #%I64u under our magic number has no MT# comment — not ours to manage, skipping.",
                     ticket);
         continue;
        }

      TradeDecisionRecord dec;
      if(!m_store.FindById(decisionId, dec))
        {
         PrintFormat("MedisTouch Recovery: position #%I64u references decision #%d, not found in the decision store — cannot restore, skipping.",
                     ticket, decisionId);
         continue;
        }

      ExecutionRecord execs[];
      int execCount = m_store.LoadAllExecutions(execs);
      double currentVolume = PositionGetDouble(POSITION_VOLUME);
      double submittedVolume = currentVolume; // fallback if no execution row was ever written
      for(int e = 0; e < execCount; e++)
         if(execs[e].decision_id == decisionId)
           {
            submittedVolume = execs[e].volume;
            break;
           }

      bool isBuy = (dec.setup.type == ORDER_TYPE_BUY);
      double entry = isBuy ? dec.setup.entry_top : dec.setup.entry_bottom;
      double currentSL = PositionGetDouble(POSITION_SL);

      ENUM_TRADE_STATE state = InferPositionState(submittedVolume, currentVolume, entry, currentSL, isBuy);

      if(m_orders.RestoreTrade(dec, currentVolume, ticket, state))
        {
         restored++;
         PrintFormat("MedisTouch Recovery: restored decision #%d as ticket #%I64u in state %s.",
                     decisionId, ticket, TradeStateToString(state));
        }
     }

   // --- Pending (resting limit) orders ---
   for(int i = 0; i < OrdersTotal(); i++)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != m_symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != m_magic) continue;

      long decisionId;
      if(!ParseDecisionId(OrderGetString(ORDER_COMMENT), decisionId)) continue;

      TradeDecisionRecord dec;
      if(!m_store.FindById(decisionId, dec))
        {
         PrintFormat("MedisTouch Recovery: pending order #%I64u references decision #%d, not found in the decision store — cannot restore, skipping.",
                     ticket, decisionId);
         continue;
        }

      double vol = OrderGetDouble(ORDER_VOLUME_CURRENT);
      if(m_orders.RestoreTrade(dec, vol, ticket, TS_PENDING))
        {
         restored++;
         PrintFormat("MedisTouch Recovery: restored decision #%d as pending order #%I64u.", decisionId, ticket);
        }
     }

   return restored;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Recovery/RecoveryEngine.mqh ----

// ---- BEGIN EA/includes/Portfolio/PortfolioManager.mqh ----
//+------------------------------------------------------------------+
//|                                     Portfolio/PortfolioManager.mqh |
//+------------------------------------------------------------------+
#ifndef PORTFOLIOMANAGER_MQH
#define PORTFOLIOMANAGER_MQH

// ---- BEGIN EA/includes/Trading/RiskEngine.mqh ----

// ---- END EA/includes/Trading/RiskEngine.mqh ----


// ---- BEGIN EA/includes/Portfolio/PortfolioRiskEngine.mqh ----
//+------------------------------------------------------------------+
//| Portfolio/PortfolioRiskEngine.mqh                                |
//| Account-wide rolling-correlation and factor-exposure gate.        |
//| Expensive market-data reads are cached per M15 bar.               |
//+------------------------------------------------------------------+
#ifndef PORTFOLIORISKENGINE_MQH
#define PORTFOLIORISKENGINE_MQH

// ---- BEGIN EA/includes/Trading/RiskEngine.mqh ----

// ---- END EA/includes/Trading/RiskEngine.mqh ----

struct PortfolioRiskSnapshot
  {
   double totalRiskAmount;
   double correlatedRiskAmount;
   double factorRiskAmount;
   int    correlatedPositions;
   bool   valid;
  };

struct CorrelationCacheEntry
  {
   string   symbolA;
   string   symbolB;
   datetime barTime;
   double   value;
  };

class CPortfolioRiskEngine
  {
private:
   int    m_correlationLookback;
   double m_correlationThreshold;
   double m_maxCorrelatedRiskPercent;
   double m_maxFactorRiskPercent;
   CorrelationCacheEntry m_cache[];

   bool GetReturns(string symbol, int count, double &returns[]);
   double CalculateCorrelation(string symbolA, string symbolB);
   double Correlation(string symbolA, string symbolB);
   double OpenRisk(ulong ticket, CRiskEngine &risk);
   string FactorGroup(string symbol);
   datetime CorrelationBarTime();

public:
   void Init(int correlationLookback = 50, double correlationThreshold = 0.70,
             double maxCorrelatedRiskPercent = 1.50, double maxFactorRiskPercent = 2.00);
   bool BuildSnapshot(string proposedSymbol, double proposedRiskAmount, ulong magic,
                      CRiskEngine &risk, PortfolioRiskSnapshot &snapshot, string &reasonOut);
  };

void CPortfolioRiskEngine::Init(int correlationLookback, double correlationThreshold,
                                double maxCorrelatedRiskPercent, double maxFactorRiskPercent)
  {
   m_correlationLookback = MathMax(20, correlationLookback);
   m_correlationThreshold = MathMax(0.50, MathMin(0.95, correlationThreshold));
   m_maxCorrelatedRiskPercent = MathMax(0.0, maxCorrelatedRiskPercent);
   m_maxFactorRiskPercent = MathMax(0.0, maxFactorRiskPercent);
   ArrayResize(m_cache, 0);
  }

datetime CPortfolioRiskEngine::CorrelationBarTime()
  {
   return iTime(_Symbol, PERIOD_M15, 0);
  }

bool CPortfolioRiskEngine::GetReturns(string symbol, int count, double &returns[])
  {
   double closes[];
   int copied = CopyClose(symbol, PERIOD_M15, 1, count + 1, closes);
   if(copied < count + 1) return false;
   ArrayResize(returns, count);
   for(int i = 1; i < copied; i++)
     {
      if(closes[i - 1] <= 0 || closes[i] <= 0) return false;
      returns[i - 1] = MathLog(closes[i] / closes[i - 1]);
     }
   return true;
  }

double CPortfolioRiskEngine::CalculateCorrelation(string symbolA, string symbolB)
  {
   if(symbolA == symbolB) return 1.0;
   double a[], b[];
   if(!GetReturns(symbolA, m_correlationLookback, a)) return 0.0;
   if(!GetReturns(symbolB, m_correlationLookback, b)) return 0.0;
   int n = MathMin(ArraySize(a), ArraySize(b));
   if(n < 20) return 0.0;

   double ma = 0.0, mb = 0.0;
   for(int i = 0; i < n; i++) { ma += a[i]; mb += b[i]; }
   ma /= n;
   mb /= n;
   double cov = 0.0, va = 0.0, vb = 0.0;
   for(int i = 0; i < n; i++)
     {
      double da = a[i] - ma;
      double db = b[i] - mb;
      cov += da * db;
      va += da * da;
      vb += db * db;
     }
   if(va <= 0 || vb <= 0) return 0.0;
   return cov / MathSqrt(va * vb);
  }

double CPortfolioRiskEngine::Correlation(string symbolA, string symbolB)
  {
   datetime barTime = CorrelationBarTime();
   for(int i = 0; i < ArraySize(m_cache); i++)
     {
      bool samePair = (m_cache[i].symbolA == symbolA && m_cache[i].symbolB == symbolB) ||
                      (m_cache[i].symbolA == symbolB && m_cache[i].symbolB == symbolA);
      if(samePair && m_cache[i].barTime == barTime)
         return m_cache[i].value;
     }

   double value = CalculateCorrelation(symbolA, symbolB);
   int n = ArraySize(m_cache);
   ArrayResize(m_cache, n + 1);
   m_cache[n].symbolA = symbolA;
   m_cache[n].symbolB = symbolB;
   m_cache[n].barTime = barTime;
   m_cache[n].value = value;

   // Keep the cache bounded. A normal portfolio has only a handful of pairs;
   // old-bar entries have no value once a new M15 bar is available.
   if(ArraySize(m_cache) > 64)
     {
      CorrelationCacheEntry fresh[];
      int kept = 0;
      ArrayResize(fresh, ArraySize(m_cache));
      for(int i = 0; i < ArraySize(m_cache); i++)
        {
         if(m_cache[i].barTime == barTime)
            fresh[kept++] = m_cache[i];
        }
      ArrayResize(fresh, kept);
      ArrayResize(m_cache, kept);
      for(int i = 0; i < kept; i++) m_cache[i] = fresh[i];
     }
   return value;
  }

double CPortfolioRiskEngine::OpenRisk(ulong ticket, CRiskEngine &risk)
  {
   if(!PositionSelectByTicket(ticket)) return 0.0;
   double sl = PositionGetDouble(POSITION_SL);
   if(sl <= 0) return 0.0;
   string symbol = PositionGetString(POSITION_SYMBOL);
   return risk.RiskAmountForLots(symbol,
                                 PositionGetDouble(POSITION_VOLUME),
                                 PositionGetDouble(POSITION_PRICE_OPEN), sl);
  }

string CPortfolioRiskEngine::FactorGroup(string symbol)
  {
   if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "XAG") >= 0) return "METALS";
   if(StringFind(symbol, "US30") >= 0 || StringFind(symbol, "NAS100") >= 0 || StringFind(symbol, "SPX") >= 0 ||
      StringFind(symbol, "GER40") >= 0 || StringFind(symbol, "UK100") >= 0 || StringFind(symbol, "JPN225") >= 0) return "RISK_ASSETS";
   if(StringFind(symbol, "BTC") >= 0 || StringFind(symbol, "ETH") >= 0 || StringFind(symbol, "XRP") >= 0) return "CRYPTO";
   return "FX";
  }

bool CPortfolioRiskEngine::BuildSnapshot(string proposedSymbol, double proposedRiskAmount, ulong magic,
                                         CRiskEngine &risk, PortfolioRiskSnapshot &snapshot, string &reasonOut)
  {
   snapshot.totalRiskAmount = proposedRiskAmount;
   snapshot.correlatedRiskAmount = proposedRiskAmount;
   snapshot.factorRiskAmount = proposedRiskAmount;
   snapshot.correlatedPositions = 0;
   snapshot.valid = true;
   reasonOut = "";

   string proposedFactor = FactorGroup(proposedSymbol);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0)
     {
      snapshot.valid = false;
      reasonOut = "invalid account equity";
      return false;
     }

   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != magic) continue;

      double r = OpenRisk(ticket, risk);
      if(r <= 0)
        {
         if(PositionGetDouble(POSITION_SL) <= 0)
           {
            snapshot.valid = false;
            reasonOut = "existing position has no stop loss; portfolio risk is unknown";
            return false;
           }
         continue;
        }

      string posSymbol = PositionGetString(POSITION_SYMBOL);
      snapshot.totalRiskAmount += r;
      if(FactorGroup(posSymbol) == proposedFactor)
         snapshot.factorRiskAmount += r;

      double corr = Correlation(proposedSymbol, posSymbol);
      if(MathAbs(corr) >= m_correlationThreshold)
        {
         snapshot.correlatedPositions++;
         snapshot.correlatedRiskAmount += r;
        }
     }

   if(m_maxCorrelatedRiskPercent > 0 &&
      snapshot.correlatedRiskAmount > equity * m_maxCorrelatedRiskPercent / 100.0)
     {
      snapshot.valid = false;
      reasonOut = StringFormat("correlated portfolio risk %.2f exceeds %.2f%% limit",
                               snapshot.correlatedRiskAmount, m_maxCorrelatedRiskPercent);
      return false;
     }
   if(m_maxFactorRiskPercent > 0 &&
      snapshot.factorRiskAmount > equity * m_maxFactorRiskPercent / 100.0)
     {
      snapshot.valid = false;
      reasonOut = StringFormat("factor exposure %s risk %.2f exceeds %.2f%% limit",
                               proposedFactor, snapshot.factorRiskAmount, m_maxFactorRiskPercent);
      return false;
     }
   return true;
  }

#endif // PORTFOLIORISKENGINE_MQH
//+------------------------------------------------------------------+


// ---- END EA/includes/Portfolio/PortfolioRiskEngine.mqh ----

// Account-wide pre-order portfolio gate. Simple hard limits remain here;
// rolling correlation and factor exposure are delegated to the dedicated
// risk engine. No HTTP, database or optimizer work is permitted here.
class CPortfolioManager
  {
private:
   double               m_maxPortfolioRiskPercent;
   int                  m_maxPositionsPerSymbol;
   int                  m_maxPositionsPerGroup;
   ulong                m_magic;
   CRiskEngine*         m_risk;
   CPortfolioRiskEngine m_riskEngine;

   string CorrelationGroup(string symbol);
   double OpenRiskAmount(ulong ticket);

public:
   void Init(double maxPortfolioRiskPercent, int maxPositionsPerSymbol,
             int maxPositionsPerGroup, ulong magic, CRiskEngine* risk,
             int correlationLookback = 50, double correlationThreshold = 0.70,
             double maxCorrelatedRiskPercent = 1.50, double maxFactorRiskPercent = 2.00);
   bool AllowNewTrade(string symbol, double proposedRiskAmount, string &reasonOut);
  };

void CPortfolioManager::Init(double maxPortfolioRiskPercent, int maxPositionsPerSymbol,
                             int maxPositionsPerGroup, ulong magic, CRiskEngine* risk,
                             int correlationLookback, double correlationThreshold,
                             double maxCorrelatedRiskPercent, double maxFactorRiskPercent)
  {
   m_maxPortfolioRiskPercent = MathMax(0.0, maxPortfolioRiskPercent);
   m_maxPositionsPerSymbol = MathMax(0, maxPositionsPerSymbol);
   m_maxPositionsPerGroup = MathMax(0, maxPositionsPerGroup);
   m_magic = magic;
   m_risk = risk;
   m_riskEngine.Init(correlationLookback, correlationThreshold,
                     maxCorrelatedRiskPercent, maxFactorRiskPercent);
  }

string CPortfolioManager::CorrelationGroup(string symbol)
  {
   if(StringFind(symbol, "BTC") >= 0 || StringFind(symbol, "ETH") >= 0 || StringFind(symbol, "XRP") >= 0)
      return "CRYPTO";
   if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "XAG") >= 0)
      return "METALS";
   if(StringFind(symbol, "US30") >= 0 || StringFind(symbol, "NAS100") >= 0 || StringFind(symbol, "SPX") >= 0 ||
      StringFind(symbol, "GER40") >= 0 || StringFind(symbol, "UK100") >= 0 || StringFind(symbol, "JPN225") >= 0)
      return "INDICES";
   return "FX";
  }

double CPortfolioManager::OpenRiskAmount(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return 0.0;
   string symbol = PositionGetString(POSITION_SYMBOL);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);
   double volume = PositionGetDouble(POSITION_VOLUME);
   if(sl == 0) return 0.0;
   return m_risk.RiskAmountForLots(symbol, volume, entry, sl);
  }

bool CPortfolioManager::AllowNewTrade(string symbol, double proposedRiskAmount, string &reasonOut)
  {
   reasonOut = "";
   string group = CorrelationGroup(symbol);
   double totalRisk = proposedRiskAmount;
   int symbolCount = 0;
   int groupCount = 0;
   bool anyUnknownRiskPosition = false;

   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != m_magic) continue;

      string posSymbol = PositionGetString(POSITION_SYMBOL);
      if(posSymbol == symbol) symbolCount++;
      if(CorrelationGroup(posSymbol) == group) groupCount++;

      double risk = OpenRiskAmount(ticket);
      if(risk <= 0 && PositionGetDouble(POSITION_SL) == 0) anyUnknownRiskPosition = true;
      totalRisk += risk;
     }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double maxRiskAmount = equity * (m_maxPortfolioRiskPercent / 100.0);

   if(symbolCount >= m_maxPositionsPerSymbol)
     {
      reasonOut = StringFormat("%s already has %d open position(s) under this magic number (limit %d)",
                               symbol, symbolCount, m_maxPositionsPerSymbol);
      return false;
     }
   if(groupCount >= m_maxPositionsPerGroup)
     {
      reasonOut = StringFormat("correlation group %s already has %d open position(s) (limit %d)",
                               group, groupCount, m_maxPositionsPerGroup);
      return false;
     }
   if(anyUnknownRiskPosition)
     {
      reasonOut = "an existing open position under this magic number has no stop loss set — portfolio risk can't be verified, refusing new trades until it's resolved";
      return false;
     }
   if(m_maxPortfolioRiskPercent > 0 && totalRisk > maxRiskAmount)
     {
      reasonOut = StringFormat("adding this trade would bring total open risk to %.2f, above the %.2f%% portfolio cap (%.2f)",
                               totalRisk, m_maxPortfolioRiskPercent, maxRiskAmount);
      return false;
     }

   PortfolioRiskSnapshot snapshot;
   string advancedReason;
   if(!m_riskEngine.BuildSnapshot(symbol, proposedRiskAmount, m_magic, m_risk, snapshot, advancedReason))
     {
      reasonOut = advancedReason;
      return false;
     }
   return true;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Portfolio/PortfolioManager.mqh ----

// ---- BEGIN EA/includes/Portfolio/RiskGuard.mqh ----
//+------------------------------------------------------------------+
//|                                        Portfolio/RiskGuard.mqh    |
//+------------------------------------------------------------------+
#ifndef RISKGUARD_MQH
#define RISKGUARD_MQH

// Account-level circuit breaker, evaluated once per tick (cheap — just
// reads AccountInfoDouble) BEFORE any new decision is even generated.
// This is the honest version of "consistency tuning": it does not
// suppress winning days to flatten an equity curve for a prop-firm
// evaluator, and it does not hide anything from anyone. It does two
// things, both disclosed in the terminal log when they trigger:
//
//   1. DAILY LOSS CAP — once today's realized+floating loss from the
//      day's starting equity exceeds InpMaxDailyLossPercent, no new
//      trades until the next trading day (broker/server time). Existing
//      open positions are left alone — this blocks NEW risk, it does not
//      panic-close what's already open (that's a separate, deliberate
//      decision your position management already owns via SL/trailing).
//   2. DRAWDOWN DE-RISK RAMP — as floating drawdown from the account's
//      peak equity grows past a soft threshold, position size for any
//      NEW trade is linearly reduced (down to a floor, never to zero via
//      this mechanism alone — the hard drawdown cap below does that).
//      This is ordinary risk-of-ruin management: size down when you're
//      already underwater, same as a fixed-fractional system does
//      naturally, just made explicit and configurable instead of
//      implicit in equity-based position sizing alone.
//   3. HARD DRAWDOWN CAP — beyond InpMaxDrawdownPercent from peak
//      equity, trading halts entirely until you manually clear it
//      (IsHalted() stays true across restarts — see Persist()/Restore()
//      — a real drawdown breach shouldn't quietly clear itself just
//      because the terminal restarted).
class CRiskGuard
  {
private:
   double   m_maxDailyLossPercent;
   double   m_maxDrawdownPercent;
   double   m_deriskStartPercent;   // drawdown %, from peak, where size reduction begins
   double   m_deriskFloor;          // minimum size multiplier the ramp can reach (e.g. 0.25 = never below 25%)

   double   m_dayStartEquity;
   int      m_dayStartDayOfYear;
   int      m_dayStartYear;

   double   m_peakEquity;
   bool     m_hardHalted;

   string   m_gvPeakKey;
   string   m_gvHaltedKey;

   void     RolloverIfNewDay();

public:
   void     Init(string symbol, double maxDailyLossPercent, double maxDrawdownPercent,
                  double deriskStartPercent, double deriskFloor);
   void     OnTick(); // cheap — call every tick, same cadence as CProductionMonitor::OnTickCheck()

   bool     IsDailyLossLimitHit(string &reasonOut);
   bool     IsHardHalted(string &reasonOut);
   double   SizeMultiplier(); // 1.0 normal, ramps down between m_deriskStartPercent and m_maxDrawdownPercent
   double   CurrentDrawdownPercent();

   void     ManualReset(); // explicit operator action to clear a hard halt — never automatic
  };
//+------------------------------------------------------------------+
void CRiskGuard::Init(string symbol, double maxDailyLossPercent, double maxDrawdownPercent,
                       double deriskStartPercent, double deriskFloor)
  {
   m_maxDailyLossPercent = maxDailyLossPercent;
   m_maxDrawdownPercent = maxDrawdownPercent;
   m_deriskStartPercent = deriskStartPercent;
   m_deriskFloor = MathMax(0.05, MathMin(1.0, deriskFloor));

   m_gvPeakKey = "MedisTouch_PeakEquity_" + symbol;
   m_gvHaltedKey = "MedisTouch_HardHalted_" + symbol;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   // Persisted peak survives terminal restarts (GlobalVariables live in
   // the terminal, not this EA instance) — a restart should never quietly
   // reset "how far underwater are we from the real high-water mark".
   if(GlobalVariableCheck(m_gvPeakKey))
      m_peakEquity = MathMax(GlobalVariableGet(m_gvPeakKey), equity);
   else
      m_peakEquity = equity;
   GlobalVariableSet(m_gvPeakKey, m_peakEquity);

   m_hardHalted = GlobalVariableCheck(m_gvHaltedKey) && (GlobalVariableGet(m_gvHaltedKey) > 0.5);

   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   m_dayStartYear = t.year;
   m_dayStartDayOfYear = t.day_of_year;
   m_dayStartEquity = equity;
  }
//+------------------------------------------------------------------+
void CRiskGuard::RolloverIfNewDay()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(t.year != m_dayStartYear || t.day_of_year != m_dayStartDayOfYear)
     {
      m_dayStartYear = t.year;
      m_dayStartDayOfYear = t.day_of_year;
      m_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      PrintFormat("MedisTouch RiskGuard: new trading day, daily loss cap reset (start equity %.2f)", m_dayStartEquity);
     }
  }
//+------------------------------------------------------------------+
void CRiskGuard::OnTick()
  {
   RolloverIfNewDay();
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > m_peakEquity)
     {
      m_peakEquity = equity;
      GlobalVariableSet(m_gvPeakKey, m_peakEquity);
     }

   if(!m_hardHalted && m_maxDrawdownPercent > 0 && CurrentDrawdownPercent() >= m_maxDrawdownPercent)
     {
      m_hardHalted = true;
      GlobalVariableSet(m_gvHaltedKey, 1.0);
      PrintFormat("MedisTouch RiskGuard: HARD HALT — drawdown from peak equity (%.2f) reached %.2f%%, at/above the %.2f%% cap. No new trades until ManualReset().",
                  m_peakEquity, CurrentDrawdownPercent(), m_maxDrawdownPercent);
     }
  }
//+------------------------------------------------------------------+
double CRiskGuard::CurrentDrawdownPercent()
  {
   if(m_peakEquity <= 0) return 0.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   return MathMax(0.0, (m_peakEquity - equity) / m_peakEquity * 100.0);
  }
//+------------------------------------------------------------------+
bool CRiskGuard::IsDailyLossLimitHit(string &reasonOut)
  {
   reasonOut = "";
   if(m_maxDailyLossPercent <= 0 || m_dayStartEquity <= 0) return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = MathMax(0.0, (m_dayStartEquity - equity) / m_dayStartEquity * 100.0);
   if(lossPercent >= m_maxDailyLossPercent)
     {
      reasonOut = StringFormat("daily loss cap hit: down %.2f%% from today's start equity %.2f (cap %.2f%%)",
                                lossPercent, m_dayStartEquity, m_maxDailyLossPercent);
      return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
bool CRiskGuard::IsHardHalted(string &reasonOut)
  {
   reasonOut = "";
   if(!m_hardHalted) return false;
   reasonOut = StringFormat("hard drawdown halt active — %.2f%% below peak equity %.2f (cap %.2f%%). Call ManualReset() to clear after reviewing why.",
                             CurrentDrawdownPercent(), m_peakEquity, m_maxDrawdownPercent);
   return true;
  }
//+------------------------------------------------------------------+
// Linear ramp: 1.0 at/below m_deriskStartPercent drawdown, down to
// m_deriskFloor at m_maxDrawdownPercent drawdown (where the hard halt
// takes over anyway). Sizing down while already underwater is standard
// risk-of-ruin discipline — smaller bets while you're proving the
// strategy still works, not smaller REPORTED profit to fool anyone.
double CRiskGuard::SizeMultiplier()
  {
   if(m_maxDrawdownPercent <= m_deriskStartPercent) return 1.0; // misconfigured — fail to "no reduction" rather than divide by ~0
   double dd = CurrentDrawdownPercent();
   if(dd <= m_deriskStartPercent) return 1.0;
   if(dd >= m_maxDrawdownPercent) return m_deriskFloor;
   double span = m_maxDrawdownPercent - m_deriskStartPercent;
   double progress = (dd - m_deriskStartPercent) / span;
   return 1.0 - progress * (1.0 - m_deriskFloor);
  }
//+------------------------------------------------------------------+
void CRiskGuard::ManualReset()
  {
   m_hardHalted = false;
   GlobalVariableSet(m_gvHaltedKey, 0.0);
   PrintFormat("MedisTouch RiskGuard: hard halt manually cleared by operator.");
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Portfolio/RiskGuard.mqh ----

// ---- BEGIN EA/includes/Core/NewsFilter.mqh ----
//+------------------------------------------------------------------+
//|                                            Core/NewsFilter.mqh    |
//+------------------------------------------------------------------+
#ifndef NEWSFILTER_MQH
#define NEWSFILTER_MQH

// v2.9: soft-risk tier, in addition to the existing hard-block IsLocked()
// gate. NEWS_NONE = no high-impact event within the warning window at
// all. NEWS_WARNING = inside the (wider) warning window but outside the
// (narrower) block window — CScoringEngine can use this to soft-discount
// confidence rather than the EA hard-blocking every entry, matching the
// review's "don't just block, let news context feed the probability
// model" idea. NEWS_BLOCKED = inside the existing hard-block window;
// IsLocked() already fully prevents new entries in this case at the EA
// level, this enum value exists so a single call can report which tier
// applied, for the dashboard/signal card.
enum ENUM_NEWS_RISK { NEWS_NONE, NEWS_WARNING, NEWS_BLOCKED };

// Blocks NEW trade entries in a window around high-impact economic
// events, read from a CSV the operator maintains themselves — this does
// NOT scrape ForexFactory or anything else at runtime (MT5's WebRequest
// is allow-listed per-domain by the terminal and scraping a site that
// doesn't offer a real feed is fragile and liable to break silently).
// Expected file format, one event per line, in the terminal's
// MQL5/Files directory (or Files/Common if opened with FILE_COMMON):
//   2026.08.15,12:30,HIGH,US Nonfarm Payrolls
//   2026.08.20,18:00,HIGH,FOMC Rate Decision
// Only rows with impact == "HIGH" (case-sensitive, by design — don't
// silently widen the block window by loosely matching "medium" too)
// are loaded. Malformed rows are skipped, not fatal.
//
// FAILS OPEN: a missing or empty file disables the filter (logs once,
// trading continues) rather than blocking every trade because a CSV
// wasn't found — the same fail-safe posture SessionFilter and
// PortfolioManager use elsewhere in this codebase for "gate not
// configured".
class CNewsFilter
  {
private:
   datetime   m_times[];
   string     m_labels[];
   int        m_count;
   int        m_minutesBefore;
   int        m_minutesAfter;
   bool       m_enabled;
   // v2.9 — warning window, wider than the block window by definition
   // (if it were narrower/equal, WARNING would never be reachable).
   int        m_warnMinutesBefore;
   int        m_warnMinutesAfter;

public:
              CNewsFilter() : m_count(0), m_minutesBefore(15), m_minutesAfter(5), m_enabled(false),
                              m_warnMinutesBefore(60), m_warnMinutesAfter(30) {}
   bool       Load(string filename, int minutesBefore, int minutesAfter, bool useCommonFolder = false);
   bool       IsLocked(string &reasonOut);
   int        Count() const { return m_count; }
   // v2.9. Call after Load(). Values below the existing block window are
   // clamped up to it, so WARNING is always a superset of BLOCKED, never
   // a gap next to it.
   void       ConfigureWarningWindow(int warnMinutesBefore, int warnMinutesAfter)
     {
      m_warnMinutesBefore = MathMax(warnMinutesBefore, m_minutesBefore);
      m_warnMinutesAfter = MathMax(warnMinutesAfter, m_minutesAfter);
     }
   // v2.9. Returns the risk tier for "now", the label of the nearest
   // event driving that tier (if any), and minutes until/since it
   // (negative = already passed, still inside the after-window).
   ENUM_NEWS_RISK GetRiskTier(string &labelOut, int &minutesToEventOut);
  };
//+------------------------------------------------------------------+
bool CNewsFilter::Load(string filename, int minutesBefore, int minutesAfter, bool useCommonFolder)
  {
   m_count = 0;
   m_enabled = false;
   m_minutesBefore = MathMax(0, minutesBefore);
   m_minutesAfter = MathMax(0, minutesAfter);

   int flags = FILE_CSV | FILE_READ | FILE_SHARE_READ | FILE_ANSI;
   if(useCommonFolder) flags |= FILE_COMMON;
   int handle = FileOpen(filename, flags, ',');
   if(handle == INVALID_HANDLE)
     {
      PrintFormat("MedisTouch NewsFilter: %s not found — news filter disabled (this is not an error; create the file to enable it).", filename);
      return false;
     }

   ArrayResize(m_times, 0);
   ArrayResize(m_labels, 0);
   int loaded = 0, skipped = 0;

   while(!FileIsEnding(handle))
     {
      string dateStr = FileReadString(handle);
      if(FileIsEnding(handle)) break; // trailing blank line at EOF
      string timeStr = FileReadString(handle);
      string impact  = FileReadString(handle);
      string label   = FileReadString(handle);

      if(impact != "HIGH") { skipped++; continue; }
      datetime dt = StringToTime(dateStr + " " + timeStr);
      if(dt <= 0) { skipped++; continue; } // unparseable row — skip, don't crash the load

      int n = ArraySize(m_times);
      ArrayResize(m_times, n + 1);
      ArrayResize(m_labels, n + 1);
      m_times[n] = dt;
      m_labels[n] = label;
      loaded++;
     }
   FileClose(handle);

   m_count = loaded;
   m_enabled = (loaded > 0);
   PrintFormat("MedisTouch NewsFilter: loaded %d high-impact event(s) from %s (%d row(s) skipped/malformed).",
               loaded, filename, skipped);
   return m_enabled;
  }
//+------------------------------------------------------------------+
bool CNewsFilter::IsLocked(string &reasonOut)
  {
   reasonOut = "";
   if(!m_enabled) return false;
   datetime now = TimeCurrent();
   for(int i = 0; i < m_count; i++)
     {
      datetime windowStart = m_times[i] - m_minutesBefore * 60;
      datetime windowEnd   = m_times[i] + m_minutesAfter * 60;
      if(now >= windowStart && now <= windowEnd)
        {
         reasonOut = StringFormat("news lock — \"%s\" at %s (blocking %d min before / %d min after)",
                                   m_labels[i], TimeToString(m_times[i], TIME_DATE | TIME_MINUTES),
                                   m_minutesBefore, m_minutesAfter);
         return true;
        }
     }
   return false;
  }
//+------------------------------------------------------------------+
ENUM_NEWS_RISK CNewsFilter::GetRiskTier(string &labelOut, int &minutesToEventOut)
  {
   labelOut = "";
   minutesToEventOut = 0;
   if(!m_enabled) return NEWS_NONE;
   datetime now = TimeCurrent();
   ENUM_NEWS_RISK best = NEWS_NONE;
   int bestAbsMinutes = INT_MAX;

   for(int i = 0; i < m_count; i++)
     {
      datetime blockStart = m_times[i] - m_minutesBefore * 60;
      datetime blockEnd   = m_times[i] + m_minutesAfter * 60;
      datetime warnStart  = m_times[i] - m_warnMinutesBefore * 60;
      datetime warnEnd    = m_times[i] + m_warnMinutesAfter * 60;

      ENUM_NEWS_RISK tier = NEWS_NONE;
      if(now >= blockStart && now <= blockEnd) tier = NEWS_BLOCKED;
      else if(now >= warnStart && now <= warnEnd) tier = NEWS_WARNING;
      if(tier == NEWS_NONE) continue;

      int minutesToEvent = (int)((m_times[i] - now) / 60);
      int absMinutes = (int)MathAbs(minutesToEvent);
      // prefer BLOCKED over WARNING regardless of distance, then nearest event
      if(tier > best || (tier == best && absMinutes < bestAbsMinutes))
        {
         best = tier;
         bestAbsMinutes = absMinutes;
         labelOut = m_labels[i];
         minutesToEventOut = minutesToEvent;
        }
     }
   return best;
  }
#endif
//+------------------------------------------------------------------+


// ---- END EA/includes/Core/NewsFilter.mqh ----

// ---- BEGIN EA/includes/Signals/SubscriberPlatform.mqh ----

// ---- END EA/includes/Signals/SubscriberPlatform.mqh ----

// ---- BEGIN EA/includes/Signals/SignalPublisher.mqh ----

// ---- END EA/includes/Signals/SignalPublisher.mqh ----

// ---- BEGIN EA/includes/Signals/ConfigSync.mqh ----
//+------------------------------------------------------------------+
//| ConfigSync.mqh                                                    |
//| Secure runtime configuration delivery + atomic application.       |
//+------------------------------------------------------------------+
#ifndef CONFIGSYNC_MQH
#define CONFIGSYNC_MQH

// ---- BEGIN EA/includes/Core/RuntimeConfigBus.mqh ----

// ---- END EA/includes/Core/RuntimeConfigBus.mqh ----

class CConfigSync
  {
private:
   string   m_symbol;
   string   m_endpoint;
   string   m_ackEndpoint;
   string   m_apiKey;
   string   m_compiledWeightVersion;
   int      m_timeoutMs;
   string   m_lastAppliedHash;

   bool ExtractJsonStringField(const string &json, string field, string &out);
   bool ExtractJsonNumberField(const string &json, string field, double &out);
   bool ValidateParams(const string &json, RuntimeParameters &out, string &reason);
   bool Ack(const string &configHash, const string &status, const string &reason);

public:
   CConfigSync(void) : m_timeoutMs(1500), m_lastAppliedHash("") {}

   void Init(string symbol, string signalEndpoint, string apiKey, string compiledWeightVersion, int timeoutMs = 1500)
     {
      m_symbol = symbol;
      m_apiKey = apiKey;
      m_compiledWeightVersion = compiledWeightVersion;
      m_timeoutMs = MathMax(500, timeoutMs);

      int pos = StringFind(signalEndpoint, "/signal");
      if(pos < 0)
        {
         m_endpoint = "";
         m_ackEndpoint = "";
         PrintFormat("MedisTouch ConfigSync: endpoint %s doesn't contain /signal; sync disabled.", signalEndpoint);
         return;
        }
      string base = StringSubstr(signalEndpoint, 0, pos);
      m_endpoint = base + "/config/" + symbol;
      m_ackEndpoint = base + "/config/" + symbol + "/ack";
     }

   void Poll(void);
   string LastAppliedHash() const { return m_lastAppliedHash; }
  };

bool CConfigSync::Ack(const string configHash, const string status, const string reason)
  {
   if(StringLen(m_ackEndpoint) == 0 || StringLen(configHash) != 64) return false;

   string escapedReason = reason;
   StringReplace(escapedReason, "\\", "\\\\");
   StringReplace(escapedReason, "\"", "\\\"");
   string instance = IntegerToString((int)ChartID());
   string body = "{\"config_hash\":\"" + configHash + "\","
                 + "\"ea_instance\":\"" + instance + "\","
                 + "\"status\":\"" + status + "\","
                 + "\"ea_version\":\"" + m_compiledWeightVersion + "\","
                 + "\"reason\":\"" + escapedReason + "\"}";

   char data[];
   StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   char result[];
   string resultHeaders;
   string headers = "Content-Type: application/json\r\n";
   if(StringLen(m_apiKey) > 0)
      headers += "X-API-Key: " + m_apiKey + "\r\n";

   ResetLastError();
   int statusCode = WebRequest("POST", m_ackEndpoint, headers, m_timeoutMs, data, result, resultHeaders);
   if(statusCode < 200 || statusCode >= 300)
     {
      PrintFormat("MedisTouch ConfigSync: ACK failed for %s (HTTP %d, err %d).", configHash, statusCode, GetLastError());
      return false;
     }
   return true;
  }

bool CConfigSync::ExtractJsonStringField(const string &json, string field, string &out)
  {
   string needle = "\"" + field + "\":";
   int pos = StringFind(json, needle);
   if(pos < 0) return false;
   int valueStart = pos + StringLen(needle);
   if(StringSubstr(json, valueStart, 4) == "null") { out = ""; return true; }
   if(StringGetCharacter(json, valueStart) != '"') return false;
   valueStart++;
   int valueEnd = StringFind(json, "\"", valueStart);
   if(valueEnd < 0) return false;
   out = StringSubstr(json, valueStart, valueEnd - valueStart);
   return true;
  }

bool CConfigSync::ExtractJsonNumberField(const string &json, string field, double &out)
  {
   string needle = "\"" + field + "\":";
   int pos = StringFind(json, needle);
   if(pos < 0) return false;
   int start = pos + StringLen(needle);
   int end = start;
   int length = StringLen(json);
   while(end < length)
     {
      ushort ch = StringGetCharacter(json, end);
      if((ch >= '0' && ch <= '9') || ch == '-' || ch == '+' || ch == '.' || ch == 'e' || ch == 'E')
        { end++; continue; }
      break;
     }
   if(end == start) return false;
   string token = StringSubstr(json, start, end - start);
   out = StringToDouble(token);
   return MathIsValidNumber(out);
  }

bool CConfigSync::ValidateParams(const string &json, RuntimeParameters &out, string &reason)
  {
   int paramsPos = StringFind(json, "\"params\":{");
   if(paramsPos < 0) { reason = "params_missing"; return false; }
   string params = StringSubstr(json, paramsPos);
   double v;

   if(!ExtractJsonNumberField(params, "ensemble_threshold", v) || v < 55 || v > 85) { reason = "ensemble_threshold_out_of_bounds"; return false; }
   out.ensemble_threshold = (int)MathRound(v);
   if(!ExtractJsonNumberField(params, "smc_threshold", v) || v < 50 || v > 85) { reason = "smc_threshold_out_of_bounds"; return false; }
   out.smc_threshold = (int)MathRound(v);
   if(!ExtractJsonNumberField(params, "momentum_threshold", v) || v < 50 || v > 85) { reason = "momentum_threshold_out_of_bounds"; return false; }
   out.momentum_threshold = (int)MathRound(v);
   if(!ExtractJsonNumberField(params, "breakout_threshold", v) || v < 50 || v > 85) { reason = "breakout_threshold_out_of_bounds"; return false; }
   out.breakout_threshold = (int)MathRound(v);
   if(!ExtractJsonNumberField(params, "mean_reversion_threshold", v) || v < 50 || v > 85) { reason = "mean_reversion_threshold_out_of_bounds"; return false; }
   out.mean_reversion_threshold = (int)MathRound(v);
   if(!ExtractJsonNumberField(params, "key_level_threshold", v) || v < 50 || v > 85) { reason = "key_level_threshold_out_of_bounds"; return false; }
   out.key_level_threshold = (int)MathRound(v);
   if(!ExtractJsonNumberField(params, "fvg_proximity_atr", v) || v < 0.05 || v > 1.00) { reason = "fvg_proximity_atr_out_of_bounds"; return false; }
   out.fvg_proximity_atr = v;
   if(!ExtractJsonNumberField(params, "contradiction_penalty", v) || v < 0.0 || v > 0.50) { reason = "contradiction_penalty_out_of_bounds"; return false; }
   out.contradiction_penalty = v;
   if(!ExtractJsonNumberField(params, "freshness_bars", v) || v < 3 || v > 30) { reason = "freshness_bars_out_of_bounds"; return false; }
   out.freshness_bars = (int)MathRound(v);
   return true;
  }

void CConfigSync::Poll(void)
  {
   if(StringLen(m_endpoint) == 0) return;

   char data[];
   char result[];
   string resultHeaders;
   string headers = "Content-Type: application/json\r\n";
   if(StringLen(m_apiKey) > 0)
      headers += "X-API-Key: " + m_apiKey + "\r\n";

   ResetLastError();
   int status = WebRequest("GET", m_endpoint, headers, m_timeoutMs, data, result, resultHeaders);
   if(status == -1 || status < 200 || status >= 300) return;

   string body = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   string configHash;
   if(!ExtractJsonStringField(body, "config_hash", configHash)) return;
   if(StringLen(configHash) != 64 || configHash == m_lastAppliedHash) return;

   string state;
   if(!ExtractJsonStringField(body, "state", state)) return;
   if(state != "SCHEDULED" && state != "EA_VALIDATED" && state != "ACTIVE") return;

   string parentVersion;
   if(!ExtractJsonStringField(body, "parent_version", parentVersion)) return;
   if(parentVersion != m_compiledWeightVersion)
     {
      PrintFormat("MedisTouch ConfigSync: rejected config %s — parent '%s' != compiled '%s'.",
                  configHash, parentVersion, m_compiledWeightVersion);
      Ack(configHash, "REJECTED", "parent_version_mismatch");
      return;
     }

   RuntimeParameters parsed;
   parsed.Defaults();
   string reason;
   if(!ValidateParams(body, parsed, reason))
     {
      Ack(configHash, "REJECTED", reason);
      return;
     }

   IRuntimeConfigConsumer *consumer = GetRuntimeConfigConsumer();
   if(consumer == NULL)
     {
      Ack(configHash, "REJECTED", "runtime_consumer_not_bound");
      return;
     }

   // SCHEDULED -> EA_VALIDATED is deliberately a separate acknowledgement.
   // This prevents the backend from activating a configuration merely because
   // the EA could parse it. The APPLIED acknowledgement is sent only after the
   // local runtime object has accepted the complete validated parameter set.
   if(state == "SCHEDULED" && !Ack(configHash, "VALIDATED", "runtime_parameters_validated"))
      return;

   consumer.ApplyRuntimeParameters(parsed);

   // If this acknowledgement fails, do not advance m_lastAppliedHash. The
   // next poll retries the APPLIED handshake while re-applying the same
   // idempotent local configuration.
   if(!Ack(configHash, "APPLIED", "runtime_parameters_applied_atomically"))
      return;

   m_lastAppliedHash = configHash;
   PrintFormat("MedisTouch ConfigSync: applied config %s to %s.", configHash, m_symbol);
  }

#endif // CONFIGSYNC_MQH


// ---- END EA/includes/Signals/ConfigSync.mqh ----

// ---- BEGIN EA/includes/Monitoring/ProductionMonitor.mqh ----

// ---- END EA/includes/Monitoring/ProductionMonitor.mqh ----


// --- Analysis inputs: kept identical to MedisTouch.mq5 so both files
// analyze the same way if you point them at the same values. ---
input group "General"
input int    InpMaxHistoryBars = 500;

input group "Structure"
input int    InpSwingStrength = 3;

input group "Per-Concept Timeframes"
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_D1;
input ENUM_TIMEFRAMES InpBOSTF = PERIOD_H4;
input ENUM_TIMEFRAMES InpLiquidityTF = PERIOD_M15;
input ENUM_TIMEFRAMES InpFVGTF = PERIOD_M15;

input group "Fair Value Gaps"
input double InpFVGMinSizeATR = 0.1;

input group "Liquidity"
input double InpInternalLiqThresholdATR = 0.2;

input group "Risk (setup validation)"
input double InpMinRiskReward = 1.5;
input double InpMaxSLDistanceATR = 1.5;
input double InpSLBufferATR = 0.25;        // invalidation margin beyond FVG far edge, in ATR (audit #23 fix)
input double InpMinStopSpreadMult = 3.0;   // floor: SL distance from entry never below (current spread * this) -- check against real Pepperstone/Exness spread in Tester
input double InpMaxEntryDeviationATR = 0.15; // reject a market order if price drifted this many ATR from decision entry (audit #25 fix)

input group "Inducement Engine"
input int    InpImpulseLookbackBars = 40;
input double InpImpulseATRMult = 1.2;
input double InpImpulseBodyRatio = 0.6;
input double InpEqualTolATR = 0.2;
input int    InpMaxLegExtend = 10;
input bool   InpRequirePremiumDiscount = true;
input bool   InpRequireDistributionPhase = false;
input int    InpPhaseRangeLookback = 20;
input double InpPhaseCompressionATRMult = 2.5;

input group "Volume Engine (v2.6)"
input bool   InpRequireVolumeConfirmation = true; // Gate: reject setups below the RVOL threshold — ON for this compile/integration pass, see Analysis/Scoring.mqh
input double InpRVOLThreshold = 1.5;        // Min relative volume vs. the trailing average to count as "confirmed"
input int    InpRVOLLookback = 20;          // Bars averaged for the RVOL baseline

input group "Fibonacci Engine (v2.6)"
input bool   InpRequireFibonacciZone = true; // Gate: reject setups whose price isn't in the pullback zone — ON for this compile/integration pass
input double InpFibZoneMinPct = 50.0;       // Pullback zone start (% retracement)
input double InpFibZoneMaxPct = 61.8;       // Pullback zone end (% retracement)

input group "Value Area Engine (v2.6)"
input bool   InpRequireValueAreaLocation = false; // Gate: reject setups outside Value Area location rule — OFF, brand new & unbacktested, see Scoring.mqh
input int    InpVALookbackBars = 100;       // Bars used to build the volume profile
input int    InpVANumBins = 24;             // Price bins in the profile
input double InpVAPercent = 70.0;           // Value Area coverage, % of profiled volume (Market Profile convention = 70)

input group "HTF Order Block Engine (v2.8)"
input ENUM_TIMEFRAMES InpHtfObTF = PERIOD_H4;      // Must stay genuinely higher than InpFVGTF/InpBOSTF
input bool   InpRequireHtfOB = false;              // Gate: OFF by default, unbacktested — see Scoring.mqh
input double InpOBDisplacementATRMult = 1.5;       // Min displacement-leg range/ATR to qualify as an OB origin
input double InpOBMinBodyRatio = 0.5;              // Min body/range of the displacement candle
input double InpOBDistATRMax = 2.0;                // Max distance (in HTF ATR) from an OB midpoint that still counts

input group "Volatility Regime (v2.8)"
input bool   InpBlockLowVolRegime = false;         // Gate: OFF by default, unbacktested — see Scoring.mqh/VolatilityRegime.mqh
input int    InpVolRegimeLookback = 100;           // Bars of ATR history the percentile is computed against
input double InpVolRegimeLowPct = 0.25;            // Bottom quartile (default) = LOW regime
input double InpVolRegimeHighPct = 0.75;           // Top quartile (default) = HIGH regime

input group "Session Filter (v2.8)"
input bool   InpUseSessionFilter = true;           // ON by default — replaces "trade every session equally"
input bool   InpAllowTokyoSession = false;         // Tokyo-only hours (thin liquidity) — off by default
input bool   InpAllowLondonSession = true;
input bool   InpAllowNewYorkSession = true;
input bool   InpAllowLondonNYOverlap = true;       // highest-liquidity window; independent of the two flags above

input group "Sweep Quality / Chase Filter / FVG Proximity (v2.9)"
input bool   InpRequireMinSweepGrade = false;      // Gate: OFF by default, unbacktested — reject sweeps graded below InpMinSweepGrade
input int    InpMinSweepGrade = 2;                 // 1=C(any valid sweep), 2=B, 3=A — see ENUM_SWEEP_GRADE
input bool   InpRequireFreshSetup = false;         // Gate: OFF by default — hard-reject once TimeDecay() hits 0 bars-since-BOS
input int    InpMaxBarsSinceBOS = 5;               // Decay-to-zero cutoff (0/90/75/55/0% curve, see Inducement.mqh)
input bool   InpRequireChaseFilter = false;        // Gate: OFF by default — reject setups that ran too far past BOS before entry
input double InpMaxChaseDistATR = 0.75;            // Max (price - BOS close)/ATR in the trade direction before rejecting as "chased"
input double InpFVGMaxDistATR = 1.25;              // FVG proximity cap — tightened default from the old hardcoded 3.0 (see Scoring.mqh)
input double InpMinDirectionalAdvantage = 0.0;     // v2.9: min confidence-point edge BUY must have over SELL (or vice versa) to be selected; 0 = old ">="-only behavior, unvalidated nonzero values need ablation testing (review item "directional competition")

input group "Signal Lifecycle (v2.9)"
input bool   InpPublishLifecycleUpdates = false;   // OFF by default — requires the bridge to be on migration 0004+; a pre-0004 bridge will 404 the PATCH endpoint
input int    InpSignalExpiryBars = 12;             // unfilled for this many bars -> EXPIRED (review: "signal expiry")
input double InpSignalStaleChaseATR = 1.0;         // unfilled AND price has moved this many ATR past entry -> STALE (looser than InpMaxChaseDistATR's pre-entry gate — this is post-publish drift, not pre-entry rejection)
input double InpInvalidateOpposingConfidence = 70.0; // unfilled AND the opposite direction's confidence reaches this -> INVALIDATED

input group "Confidence Diagnostics (v2.10) - measured, NOT acted on"
// Every input in this group affects CSV columns and nothing else. The
// contradiction/environment/execution model and the confidence decay are
// logged beside each signal and its resolved outcome so the multiplicative
// score can be compared against the live additive one on YOUR data. None of
// them can change a confidence value, a filter verdict, a lot size, or an
// order. Promoting the model to live is a deliberate code change, not a
// setting - see the v2.10 block in Analysis/Scoring.mqh.
input double InpDiagContradictionWeight = 0.25;    // penalty per actively-contradicting condition (0 = disable the penalty)
input double InpDiagEnvWeight = 1.0;               // 0..1 blend of the environment component toward neutral (0 = ignore it)
input double InpDiagExecWeight = 1.0;              // 0..1 blend of the execution component toward neutral (0 = ignore it)
input double InpDiagDecayHalfLifeBars = 12.0;      // half-life, in UNFILLED bars, of the logged confidence decay (<=0 = no decay)

input group "Strategy Diagnostics (v2.12) - measured, NOT acted on"
// Same discipline as the v2.10 group above: every input here affects
// CSV columns (Regime, MomentumScore, BreakoutScore, BreakoutClass) and
// nothing else. See Regime/RegimeDetector.mqh and
// Strategies/MomentumBreakout.mqh. Strategy module #1 of the
// multi-strategy architecture — Mean Reversion and the Key-Level Price
// Action engine are not built yet; see docs/CHANGELOG.md v2.12 entry.
input int    InpMomentumBreakoutRecencyBars = 10;  // a BOS older than this many bars no longer counts as a live breakout read
input int    InpBreakoutLiqOverlapBars = 2;        // BOS/liquidity-sweep bar_index gap allowed before calling it a LIQUIDITY breakout
input int    InpBreakoutExtensionLookbackBars = 15; // window checked BEFORE the break bar for pre-existing extension
input double InpBreakoutExhaustionATRMult = 3.0;   // pre-break run, in ATR, above which a break is classified EXHAUSTION not EXPANSION
input int    InpMomentumLookbackBars = 10;         // window for the independent momentum score

input group "Mean Reversion Diagnostics (v2.13) - measured, NOT acted on"
// Same discipline as the v2.12 group above. See Strategies/MeanReversion.mqh.
// Strategy module #2 of the multi-strategy architecture — Key-Level
// Price Action is next, not built yet; see docs/CHANGELOG.md v2.13 entry.
input double InpReversionMinStretchATR = 1.0;      // value-area-edge stretch, in ATR, required for the stronger VALUE_FADE path
input double InpReversionSRZoneATRTolerance = 0.25; // how close price must be to an SR zone edge, in ATR, to count as "at" it
input double InpReversionWickRejectionRatio = 0.55; // wick length / total range required to call a candle a rejection
input int    InpReversionLiqRecencyBars = 10;      // how far back a confirming sweep still counts
input int    InpReversionTrendConflictRecencyBars = 10; // how far back an opposing BOS still counts as live conflict
input double InpReversionTrendConflictMinStrength = 0.5; // BOSEvent.strength threshold to flag TREND_CONFLICT

input group "Key-Level Reaction Diagnostics (v2.14) - measured, NOT acted on"
// Same discipline as the groups above. See Strategies/KeyLevelReaction.mqh.
// Strategy module #3 of the multi-strategy architecture. v2.17 wired in
// the three sources v2.14 left out: previous week high/low, session
// high/low, psychological levels — see docs/CHANGELOG.md v2.17 entry.
input int    InpKeyLevelLookbackBars = 5;          // closed bars examined for the reaction pattern
input double InpKeyLevelSearchATRMax = 3.0;        // max distance, in ATR, for a level to count as "in range"
input double InpKeyLevelTouchToleranceATRMult = 0.15; // how close a candle's range must come to the level, in ATR, to count as a touch
input int    InpKeyLevelAbsorptionMinTouches = 3;  // touches required, with no break/rejection, to call it ABSORPTION
input double InpKeyLevelWickRejectionRatio = 0.55; // wick/range ratio required to call a candle a rejection
input double InpKeyLevelRoundStep = 10.0;          // psychological round-number level spacing, in price units (XAUUSD: 10.0 == whole-$10 levels)

input group "Strategy Selection (v2.15) - measured, NOT acted on"
// FOURTH AND LAST LAYER added in this batch. See
// Strategies/StrategySelector.mqh. Compares the three strategy modules'
// scores above against the live SMC engine's own confidence, per
// regime, and records what WOULD have been selected — never sums
// scores, never touches setup.confidence, never gates a trade. Nothing
// further is added until v2.12-v2.15 have compiled and been
// forward-tested as one unit; see docs/CHANGELOG.md v2.15 entry.
input double InpMinSelectionScore = 60.0;          // a challenger strategy must clear this AND beat SMC confidence to be selected

input group "Logging"
input bool   InpLogSignals = true;
input bool   InpTrackOutcomes = true;
input int    InpMaxTrackingBars = 100;
input int    InpCalibrationMinSample = 30;         // v2.9: bucket sample size before GetCalibratedProbability() is trusted — see CalibrationEngine.mqh
input int    InpSessionGMTOffsetOverride = 999;
input ENUM_FILL_POLICY InpFillPolicy = FILL_CONSERVATIVE;
input ENUM_TIMEFRAMES  InpReplayTF = PERIOD_M1;

// --- Policy Engine inputs: this is what actually turns the robot on ---
input group "Policy — what this account does with a validated setup"
input bool   InpEnableExecution = false;        // master switch: place real orders on THIS account
input bool   InpEnableSignals = false;          // master switch: write to the signal feed for subscribers
input double InpMinConfidenceExecute = 70.0;    // setups below this confidence are never executed
input double InpMinConfidenceSignal = 60.0;     // setups below this confidence are never signaled
input double InpFullRiskConfidence = 85.0;      // below this (but above min-execute), risk is halved
input int    InpMaxSpreadPoints = 0;            // 0 = no spread gate; else reject execution above this spread

input group "Execution"
input bool   InpUseMarketOrders = true;         // true = market fill on signal bar; false = resting limit at the FVG
input double InpRiskPercentPerTrade = 0.5;      // % of account equity risked per trade at full confidence
input int    InpMaxOpenTrades = 3;
input ulong  InpMagicNumber = 987654321;
input bool   InpAllowMinLotOverride = false;    // if riskPercent's true size < broker min lot: false = skip the trade (keeps risk% exact), true = trade at min lot anyway (risks MORE than InpRiskPercentPerTrade — will be logged when it happens)
input double InpMaxDailyLossPercent = 3.0;      // real daily loss cap — no new trades once hit (0 = disabled)
input double InpMaxDrawdownPercent = 10.0;      // hard halt: trading stops entirely below this equity drawdown from peak (0 = disabled)
input double InpDeriskStartPercent = 5.0;       // drawdown %, from peak, where position size starts ramping down
input double InpDeriskFloor = 0.25;             // minimum size multiplier the de-risk ramp can reach (0.25 = never below 25% size)
input bool   InpUseNewsFilter = false;          // off by default — you maintain the CSV yourself, see Core/NewsFilter.mqh
input string InpNewsFilterFile = "MedisTouch_News.csv"; // MQL5/Files/<this>, format: YYYY.MM.DD,HH:MM,HIGH,Label
input int    InpNewsMinutesBefore = 15;
input int    InpNewsMinutesAfter = 5;
input int    InpNewsWarnMinutesBefore = 60;        // v2.9: soft-discount window, wider than the hard block above — see NewsFilter.mqh
input int    InpNewsWarnMinutesAfter = 30;
input double InpNewsWarnMultiplier = 0.85;         // confidence *= this while inside the warning window but outside the block window

input group "Position Management"
input double InpBreakEvenAtR = 1.0;             // move SL to entry once price is this many R in favor
input double InpPartialAtR = 2.0;               // take TP1 partial once price is this many R in favor
input double InpPartialFraction = 0.5;          // fraction of volume closed at TP1
input double InpTrailATRMult = 1.5;             // runner trail distance, as an ATR multiple

input group "Trade Simulator costs (v2.7) — the outcome tracker's backtest economics"
input double InpSimCommissionPerLot = 7.0;      // round-turn $ commission per 1.0 lot
input double InpSimSpreadPoints = 10.0;         // simulated spread, in points
input double InpSimSlippagePoints = 2.0;        // simulated adverse slippage per fill, in points

input group "Portfolio (account-wide, across every symbol this magic number trades)"
input double InpMaxPortfolioRiskPercent = 3.0;  // total open risk across the account, as % of equity
input int    InpMaxPositionsPerSymbol = 2;
input int    InpMaxPositionsPerGroup = 3;       // per correlation bucket — see Portfolio/PortfolioManager.mqh

input group "Signal Transport"
input int    InpWebRequestTimeoutMs = 5000;
input string InpBridgeApiKey = "";              // must match telegram-bridge's SECRET_KEY env var — sent as X-API-Key on every /signal POST. Leave blank and WebRequest is skipped (Publish() still writes the local CSV feed, nothing is transmitted).
// v2.11 — manual weight-set version tag. Bump this string by hand every
// time a scoring-formula change ships (same trigger as CalibrationEngine
// Reset() — see its limitation #4). Nothing enforces this yet; it exists
// so every signal AND its eventual outcome carry a queryable label for
// "which weight set produced this," which is the prerequisite for the
// statistical gating / promotion layer (steps 4-5) ever being able to
// tell one weight set's expectancy apart from another's in signal_outcomes.
input string InpWeightSetVersion = "v2.10-baseline";
// v2.11 — the operator's OWN bridge endpoint, for ConfigSync polling
// only. Deliberately separate from the subscriber-fan-out CSV
// (SubscriberPlatform.mqh) — that list is for broadcasting signals to
// potentially several parties, while config-sync is a private
// operational concern about THIS instance's own weight_version staying
// in sync with what was approved on YOUR bridge. Leave blank to disable
// config sync entirely (the default; opt-in). Same base URL you'd use
// as the /signal endpoint, e.g. "https://your-bridge.onrender.com/signal".
input string InpConfigSyncEndpoint = "";
input int    InpConfigSyncPollMinutes = 15; // how often OnTimer polls GET /config/{symbol}; irrelevant if InpConfigSyncEndpoint is blank

input group "Production Monitoring"
input int    InpHeartbeatIntervalSec = 60;
input double InpMaxDrawdownAlertPercent = 10.0;

// --- Global objects: analysis stack (mirrors MedisTouch.mq5) ---
CTFContextPool     g_pool;
CScoringEngine     g_scoring;
CTradeDecision     g_decision;     // analysis-layer setup generator (Trading/TradeZone.mqh)
CRiskEngine        g_risk;
CSignalLogger      g_logger;
COutcomeTracker    g_tracker;

CTFContext*        g_chartCtx = NULL;
CTFContext*        g_trendCtx = NULL;
CTFContext*        g_bosCtx = NULL;
CTFContext*        g_liqCtx = NULL;
CTFContext*        g_fvgCtx = NULL;
CTFContext*        g_htfObCtx = NULL;   // v2.8 — must stay a genuinely higher TF than g_fvgCtx/g_bosCtx

// --- Global objects: the new layer ---
CDecisionEngine    g_router;
CBrokerAdapter     g_broker;
COrderManager      g_orders;
CPositionManager   g_positions;
CDecisionStore     g_store;
CRecoveryEngine    g_recovery;
CPortfolioManager  g_portfolio;
CRiskGuard         g_riskGuard;
CNewsFilter        g_newsFilter;
CSubscriberPlatform g_subscribers;
CSignalPublisher   g_publisher;
CConfigSync        g_configSync;
CProductionMonitor g_monitor;

datetime           g_lastLoggedTime = 0;
datetime           g_lastBarTime = 0;

// v2.9 — signal lifecycle monitor state. Tracks only the single most
// recently published, still-unfilled decision — matches the existing
// g_lastLoggedTime dedup pattern (one active setup at a time is this
// EA's whole model; see the "already routed this exact setup" check
// above). g_lifecycleDecisionId==0 means "nothing pending to monitor".
long               g_lifecycleDecisionId = 0;
datetime           g_lifecycleCreationTime = 0;
TradeSetup         g_lifecycleSetup;
string             g_lifecycleStatus = "valid"; // last status pushed for this decision — avoids re-POSTing the same transition every tick

//+------------------------------------------------------------------+
int OnInit()
  {
   g_pool.Configure(_Symbol, InpMaxHistoryBars, InpSwingStrength, InpFVGMinSizeATR, InpInternalLiqThresholdATR,
                    InpRVOLLookback, InpVALookbackBars, InpVANumBins, InpVAPercent / 100.0,
                    InpOBDisplacementATRMult, InpOBMinBodyRatio);

   g_chartCtx = g_pool.Get(_Period);
   g_trendCtx = g_pool.Get(InpTrendTF);
   g_bosCtx   = g_pool.Get(InpBOSTF);
   g_liqCtx   = g_pool.Get(InpLiquidityTF);
   g_fvgCtx   = g_pool.Get(InpFVGTF);
   g_htfObCtx = g_pool.Get(InpHtfObTF);   // pool dedupes by TF, so if InpHtfObTF matches InpTrendTF this reuses that context

   if(g_chartCtx == NULL || g_trendCtx == NULL || g_bosCtx == NULL || g_liqCtx == NULL || g_fvgCtx == NULL || g_htfObCtx == NULL)
     {
      Print("MedisTouch EA: failed to initialize one or more timeframe contexts.");
      return INIT_FAILED;
     }
   if(InpHtfObTF <= InpFVGTF || InpHtfObTF <= InpBOSTF)
      Print("MedisTouch EA: WARNING — InpHtfObTF (", EnumToString(InpHtfObTF),
            ") is not strictly higher than InpFVGTF/InpBOSTF. HTF Order Block confluence ",
            "will be comparing zones on the same or a lower resolution than the entry timeframe, ",
            "which defeats the point of the filter even if InpRequireHtfOB is left OFF for diagnostics only.");

   g_scoring.Init(g_trendCtx, g_bosCtx, g_liqCtx, g_fvgCtx, g_chartCtx, &g_chartCtx.candles);
   g_scoring.ConfigureInducement(InpImpulseLookbackBars, InpImpulseATRMult, InpImpulseBodyRatio,
                                 InpEqualTolATR, InpMaxLegExtend,
                                 InpRequirePremiumDiscount, InpRequireDistributionPhase,
                                 InpPhaseRangeLookback, InpPhaseCompressionATRMult);
   g_scoring.ConfigureVolumeFibonacci(InpRequireVolumeConfirmation, InpRVOLThreshold,
                                      InpRequireFibonacciZone, InpFibZoneMinPct, InpFibZoneMaxPct);
   g_scoring.ConfigureValueArea(InpRequireValueAreaLocation);
   g_scoring.ConfigureHtfOrderBlock(g_htfObCtx, InpRequireHtfOB, InpOBDistATRMax);
   g_scoring.ConfigureVolatilityRegime(InpBlockLowVolRegime, InpVolRegimeLookback, InpVolRegimeLowPct, InpVolRegimeHighPct);
   g_scoring.ConfigureSessionFilter(InpUseSessionFilter, InpAllowTokyoSession, InpAllowLondonSession,
                                    InpAllowNewYorkSession, InpAllowLondonNYOverlap);
   g_scoring.ConfigureSweepQuality(InpRequireMinSweepGrade, (ENUM_SWEEP_GRADE)InpMinSweepGrade,
                                   InpRequireFreshSetup, InpMaxBarsSinceBOS);
   g_scoring.ConfigureChaseFilter(InpRequireChaseFilter, InpMaxChaseDistATR);
   g_scoring.ConfigureFVGProximity(InpFVGMaxDistATR);
   g_scoring.ConfigureLearnedDiagnostics(InpDiagContradictionWeight, InpDiagEnvWeight, InpDiagExecWeight);
   g_scoring.ConfigureStrategyDiagnostics(InpMomentumBreakoutRecencyBars, InpBreakoutLiqOverlapBars,
                                          InpBreakoutExtensionLookbackBars, InpBreakoutExhaustionATRMult,
                                          InpMomentumLookbackBars);
   g_scoring.ConfigureMeanReversionDiagnostics(InpReversionMinStretchATR, InpReversionSRZoneATRTolerance,
                                               InpReversionWickRejectionRatio, InpReversionLiqRecencyBars,
                                               InpReversionTrendConflictRecencyBars, InpReversionTrendConflictMinStrength);
   g_scoring.ConfigureKeyLevelDiagnostics(InpKeyLevelLookbackBars, InpKeyLevelSearchATRMax,
                                          InpKeyLevelTouchToleranceATRMult, InpKeyLevelAbsorptionMinTouches,
                                          InpKeyLevelWickRejectionRatio, InpKeyLevelRoundStep);
   g_scoring.ConfigureStrategySelection(InpMinSelectionScore);
   g_decision.Init(&g_chartCtx.candles, g_fvgCtx, g_liqCtx, &g_scoring, InpSLBufferATR, InpMinStopSpreadMult);
   g_logger.Init(_Symbol, InpSessionGMTOffsetOverride);
   g_tracker.Init(&g_logger, _Symbol, InpFVGTF, InpMaxTrackingBars, InpFillPolicy, InpReplayTF);
   // Deliberately the SAME values driving g_positions/g_risk below — so the
   // simulator's numbers actually predict what this EA, configured exactly
   // like this, would do.
   g_tracker.ConfigureSimulation(InpRiskPercentPerTrade, InpAllowMinLotOverride,
                                 InpBreakEvenAtR, InpPartialAtR, InpPartialFraction, InpTrailATRMult,
                                 InpSimCommissionPerLot, InpSimSpreadPoints, InpSimSlippagePoints);
   g_tracker.ConfigureCalibration(InpTrackOutcomes, InpCalibrationMinSample);
   // v2.10 diagnostics - see the "Confidence Diagnostics" input group.
   g_tracker.ConfigureConfidenceDecay(InpDiagDecayHalfLifeBars);

   g_router.Init(_Symbol, InpEnableExecution, InpEnableSignals,
                InpMinConfidenceExecute, InpMinConfidenceSignal, InpFullRiskConfidence, InpMaxSpreadPoints);
   g_broker.Init(InpMagicNumber);
   g_monitor.Init(_Symbol, InpHeartbeatIntervalSec, InpMaxDrawdownAlertPercent);
   g_orders.Init(&g_broker, InpMaxOpenTrades, &g_monitor);
   g_positions.Init(&g_orders, &g_broker, InpBreakEvenAtR, InpPartialAtR, InpPartialFraction, InpTrailATRMult);

   g_store.Init(_Symbol);
   g_subscribers.Init();
   g_publisher.Init(_Symbol, &g_subscribers, InpWebRequestTimeoutMs, InpBridgeApiKey);
   g_publisher.SetWeightVersion(InpWeightSetVersion);
   // v2.11 — dormant until InpConfigSyncEndpoint is set AND a real
   // promotion has happened on the bridge; see ConfigSync.mqh header.
   // EventSetTimer's argument is seconds, hence the *60.
   if(StringLen(InpConfigSyncEndpoint) > 0)
     {
      g_configSync.Init(_Symbol, InpConfigSyncEndpoint, InpBridgeApiKey, InpWeightSetVersion, InpWebRequestTimeoutMs);
      EventSetTimer(MathMax(60, InpConfigSyncPollMinutes * 60));
     }
   // v2.11 — lets the tracker push resolved outcomes to the bridge
   // (POST /outcome) the moment it resolves them, right alongside the
   // existing local-CSV LogOutcome() call. See OutcomeTracker.mqh
   // FinalizeExit()/Resolve() for the call sites.
   g_tracker.ConfigurePublishing(&g_publisher, InpWeightSetVersion);
   g_portfolio.Init(InpMaxPortfolioRiskPercent, InpMaxPositionsPerSymbol, InpMaxPositionsPerGroup, InpMagicNumber, &g_risk);
   g_riskGuard.Init(_Symbol, InpMaxDailyLossPercent, InpMaxDrawdownPercent, InpDeriskStartPercent, InpDeriskFloor);
   if(InpUseNewsFilter)
      g_newsFilter.Load(InpNewsFilterFile, InpNewsMinutesBefore, InpNewsMinutesAfter);
   // v2.9: wire the same CNewsFilter instance into scoring for the
   // soft-discount tier. If InpUseNewsFilter is false, the filter was
   // never Load()-ed (m_enabled stays false internally), so
   // GetRiskTier() always returns NEWS_NONE and this is a no-op —
   // consistent with every other OFF-by-default v2.9 gate.
   g_scoring.ConfigureNewsAwareness(GetPointer(g_newsFilter), InpNewsWarnMinutesBefore,
                                    InpNewsWarnMinutesAfter, InpNewsWarnMultiplier);

   // Recovery must run AFTER OrderManager/BrokerAdapter exist (it writes
   // into g_orders) and AFTER g_store is initialized (it reads decision
   // history from it), but BEFORE the first OnTick — a restarted EA
   // should never take a fresh tick believing it has zero open trades
   // when the broker actually shows some under our magic number.
   g_recovery.Init(&g_store, &g_orders, InpMagicNumber, _Symbol);
   int restoredCount = g_recovery.Recover();
   if(restoredCount > 0)
      PrintFormat("MedisTouch EA: recovery restored %d live trade(s) from a prior session.", restoredCount);

   // Decision IDs are the matching key Recovery relies on (order comment
   // "MT#<id>") — a fresh EA instance must never reissue an ID already
   // live on a broker-side ticket or already sitting in the decision
   // store. Seed the counter past the highest ID this session has ever
   // seen, every time, not just after a restart with open trades.
   TradeDecisionRecord priorDecisions[];
   int priorCount = g_store.LoadAll(priorDecisions);
   long maxId = 0;
   for(int i = 0; i < priorCount; i++)
      if(priorDecisions[i].decision_id > maxId) maxId = priorDecisions[i].decision_id;
   if(maxId > 0) g_router.SeedNextId(maxId + 1);

   if(!InpEnableExecution && !InpEnableSignals)
      Print("MedisTouch EA: both InpEnableExecution and InpEnableSignals are OFF. ",
            "Analysis and logging still run, but nothing will be executed or published.");

   return INIT_SUCCEEDED;
  }
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(StringLen(InpConfigSyncEndpoint) > 0)
      EventKillTimer();
   g_publisher.Deinit();
   g_subscribers.Deinit();
   g_store.Deinit();
  }
//+------------------------------------------------------------------+
// v2.11 — fires every InpConfigSyncPollMinutes when config sync is
// enabled (see OnInit's EventSetTimer call); does nothing otherwise,
// since EventSetTimer() is never called when InpConfigSyncEndpoint is
// blank, so OnTimer() simply never fires in that case.
void OnTimer()
  {
   g_configSync.Poll();
  }
//+------------------------------------------------------------------+
// v2.9 — signal lifecycle monitor (review: "SCANNING -> QUALIFIED ->
// POSTED -> ACTIVE -> TP/SL/EXPIRED/INVALIDATED"). Called every tick
// when InpPublishLifecycleUpdates is on; each check is cheap (a handful
// of comparisons + at most one CalculateConfidence() call), and the
// function returns immediately if nothing is being tracked.
//
// Deliberately does NOT handle TP/SL resolution — that's already
// covered by the existing PositionManager -> OutcomeTracker -> POST
// /trade closed_tp1/closed_tp2/closed_sl path. This only handles "this
// setup stopped being a valid reason to enter", which is a distinct
// question from "did a filled position hit its target".
void CheckSignalLifecycle(double currentAtr)
  {
   if(g_lifecycleDecisionId == 0) return;

   bool filled; double fillPrice; datetime fillTime; int barsToFill;
   bool haveState = g_tracker.GetFillState(g_lifecycleCreationTime, filled, fillPrice, fillTime, barsToFill);
   if(!haveState) { g_lifecycleDecisionId = 0; return; } // tracker no longer has this setup (fell off m_maxBars window) — nothing more to say

   if(filled)
     {
      // Filled — no longer a "will this get entered" question. Clear
      // tracking; TP/SL/close events take over from here via /trade.
      g_lifecycleDecisionId = 0;
      return;
     }

   bool isBuy = (g_lifecycleSetup.type == ORDER_TYPE_BUY);
   int barsSinceCreation = iBarShift(_Symbol, InpFVGTF, g_lifecycleCreationTime, false);

   // EXPIRED takes priority over STALE — an old-and-drifted setup should
   // report as expired, not stale, since expiry is the terminal state.
   if(barsSinceCreation >= InpSignalExpiryBars)
     {
      if(g_lifecycleStatus != "expired")
        {
         g_publisher.PublishStatusUpdate(g_lifecycleDecisionId, "expired",
                                         StringFormat("Unfilled for %d bars (max %d) — setup abandoned", barsSinceCreation, InpSignalExpiryBars));
         g_lifecycleStatus = "expired";
        }
      g_lifecycleDecisionId = 0; // terminal — stop tracking
      return;
     }

   // INVALIDATED: the opposite direction has since become a strong
   // setup in its own right — a real structural contradiction of the
   // original read, not just drift. Checked before STALE for the same
   // "worse state wins" reasoning as EXPIRED above.
   double oppositeConfidence = g_scoring.CalculateConfidence(!isBuy);
   if(oppositeConfidence >= InpInvalidateOpposingConfidence)
     {
      if(g_lifecycleStatus != "invalidated")
        {
         g_publisher.PublishStatusUpdate(g_lifecycleDecisionId, "invalidated",
                                         StringFormat("Opposing setup confidence reached %.0f — original read contradicted", oppositeConfidence));
         g_lifecycleStatus = "invalidated";
        }
      g_lifecycleDecisionId = 0; // terminal — stop tracking
      return;
     }

   // STALE: unfilled and price has drifted meaningfully past the
   // intended entry zone. Non-terminal — price can pull back into the
   // zone, so keep monitoring (but only publish the transition once).
   if(currentAtr > 0)
     {
      double entry = ResolveExecutionEntry(g_lifecycleSetup);
      double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double driftATR = MathAbs(price - entry) / currentAtr;
      bool wentWrongWay = isBuy ? (price > entry) : (price < entry); // "chased" means price ran further into the trade direction, unfilled
      if(wentWrongWay && driftATR >= InpSignalStaleChaseATR)
        {
         if(g_lifecycleStatus != "stale")
           {
            g_publisher.PublishStatusUpdate(g_lifecycleDecisionId, "stale",
                                            StringFormat("Price drifted %.2f ATR past the entry zone, unfilled", driftATR));
            g_lifecycleStatus = "stale";
           }
        }
      else if(g_lifecycleStatus == "stale" && driftATR < InpSignalStaleChaseATR * 0.5)
        {
         // Price came back — revert to VALID. Half the trigger distance
         // as a hysteresis band so this doesn't flip-flop every tick
         // right at the threshold.
         g_publisher.PublishStatusUpdate(g_lifecycleDecisionId, "valid", "Price returned toward the entry zone");
         g_lifecycleStatus = "valid";
        }
     }
  }
//+------------------------------------------------------------------+
void OnTick()
  {
   g_monitor.OnTickCheck(); // cheap, cadence-gated internally — safe to call every tick

   g_pool.DetectAll();
   if(g_chartCtx == NULL || !g_chartCtx.candles.IsReady()) return;

   double currentAtr = g_fvgCtx.candles.GetATR(0);

   // Manage everything already open before looking for anything new —
   // a break-even/trailing update should never wait behind new-setup work.
   g_positions.OnTick(currentAtr);
   g_orders.Prune();
   g_riskGuard.OnTick(); // cheap — daily rollover check + peak-equity/drawdown tracking

   if(InpPublishLifecycleUpdates)
      CheckSignalLifecycle(currentAtr);

   string haltReason;
   if(g_riskGuard.IsHardHalted(haltReason))
     {
      static datetime lastHaltLog = 0;
      if(TimeCurrent() - lastHaltLog > 3600) { PrintFormat("MedisTouch EA: no new trades — %s", haltReason); lastHaltLog = TimeCurrent(); }
      return;
     }
   if(g_riskGuard.IsDailyLossLimitHit(haltReason))
     {
      static datetime lastDailyLog = 0;
      if(TimeCurrent() - lastDailyLog > 3600) { PrintFormat("MedisTouch EA: no new trades — %s", haltReason); lastDailyLog = TimeCurrent(); }
      return;
     }
   string newsReason;
   if(InpUseNewsFilter && g_newsFilter.IsLocked(newsReason))
     {
      static datetime lastNewsLog = 0;
      if(TimeCurrent() - lastNewsLog > 300) { PrintFormat("MedisTouch EA: no new trades — %s", newsReason); lastNewsLog = TimeCurrent(); }
      return;
     }

   // Only evaluate for a NEW decision once per closed bar, same as the
   // indicator's OnCalculate cadence — a decision per bar, not per tick.
   datetime barTime = iTime(_Symbol, _Period, 0);
   bool isNewBar = (barTime != g_lastBarTime);
   g_lastBarTime = barTime;
   if(!isNewBar) return;

   TradeSetup buySetup = g_decision.GenerateBuySetup();
   TradeSetup sellSetup = g_decision.GenerateSellSetup();

   // v2.9 — directional competition (review: "don't force equal BUY/SELL
   // frequency; require a minimum probability/confidence advantage").
   // Previously this was a bare ">=", i.e. a 0.01-point edge could flip
   // direction — no different from a coin flip when both setups are
   // roughly equally valid. InpMinDirectionalAdvantage=0 preserves that
   // exact old behavior (default); a nonzero value requires the winning
   // side to actually be ahead by that many confidence points, and drops
   // the bar entirely (no trade either direction) when neither side
   // clears it — an ambiguous market gets skipped instead of arbitrarily
   // resolved. Needs the same ablation-test treatment as everything else
   // to find a real threshold; 0 ships as the safe default.
   TradeSetup chosen;
   ZeroMemory(chosen);
   double confDelta = buySetup.confidence - sellSetup.confidence;
   if(buySetup.active && sellSetup.active)
     {
      if(confDelta >= InpMinDirectionalAdvantage)
        {
         if(g_risk.ValidateSetup(buySetup, InpMinRiskReward, InpMaxSLDistanceATR, currentAtr))
            chosen = buySetup;
        }
      else if(-confDelta >= InpMinDirectionalAdvantage)
        {
         if(g_risk.ValidateSetup(sellSetup, InpMinRiskReward, InpMaxSLDistanceATR, currentAtr))
            chosen = sellSetup;
        }
      // else: neither side clears the advantage threshold — no trade,
      // market read as ambiguous rather than arbitrarily picking one.
     }
   else if(buySetup.active)
     {
      if(g_risk.ValidateSetup(buySetup, InpMinRiskReward, InpMaxSLDistanceATR, currentAtr))
         chosen = buySetup;
     }
   else if(sellSetup.active)
     {
      if(g_risk.ValidateSetup(sellSetup, InpMinRiskReward, InpMaxSLDistanceATR, currentAtr))
         chosen = sellSetup;
     }

   if(!chosen.active) return;
   if(chosen.creation_time == g_lastLoggedTime) return; // already routed this exact setup
   g_lastLoggedTime = chosen.creation_time;

   // v2.9: attach the empirical calibration read for this confidence
   // bucket to the chosen setup before it's logged/published — this is
   // what turns "confidence 78" into "confidence 78, historically wins
   // 63% of the time (114 comparable setups)" on the Telegram card.
   chosen.calibrated_probability = g_tracker.GetCalibratedProbability(chosen.confidence,
                                                                       chosen.calibration_sample,
                                                                       chosen.calibration_has_enough_data);

   if(InpLogSignals)
     {
      ENUM_TREND_STATE t = g_trendCtx.trend.GetCurrentTrend();
      g_logger.LogSetup(chosen, _Symbol, InpFVGTF, EnumToString(t));
     }

   // --- This is the seam the audit found missing: analysis -> decision -> action ---
   // v2.11: moved ABOVE AddSetup()/Update() (was below) so a decision_id
   // exists BEFORE the setup enters the tracker — without it, PendingSetup
   // has no valid signal_id to publish resolved outcomes under (see
   // Config.mqh PendingSetup.decisionId). Behavior is otherwise identical:
   // Decide() always ran unconditionally on `chosen` right after this
   // point before, so nothing about ITS timing or inputs has changed —
   // only AddSetup()/Update() now run a few lines later, still within the
   // same tick, still processing the same pending array.
   TradeDecisionRecord decision = g_router.Decide(chosen);

   if(InpTrackOutcomes)
      g_tracker.AddSetup(chosen, decision.decision_id);
   g_tracker.Update(g_fvgCtx);

   if(!decision.valid || decision.action == POLICY_IGNORE) return;

   // Persist BEFORE acting — Recovery must be able to find this decision
   // even if the terminal dies immediately after an order fills.
   g_store.Save(decision);

   if(decision.action == POLICY_EXECUTE_ONLY || decision.action == POLICY_EXECUTE_AND_SIGNAL)
     {
      double entry = ResolveExecutionEntry(chosen); // same price ValidateSetup() gated against — see Core/Config.mqh
      bool exceededRiskBudget = false;
      double lots = g_risk.CalculateLotSize(_Symbol, InpRiskPercentPerTrade, entry, chosen.stop_loss,
                                            decision.reduce_risk, InpAllowMinLotOverride, exceededRiskBudget,
                                            g_riskGuard.SizeMultiplier());
      if(lots <= 0)
         PrintFormat("MedisTouch EA: decision #%d skipped — %.2f%% risk at this stop distance is below the broker's minimum lot for %s.",
                     decision.decision_id, InpRiskPercentPerTrade, _Symbol);
      else
        {
         if(exceededRiskBudget)
            PrintFormat("MedisTouch EA: decision #%d executing at broker-minimum lot (%.2f) — actual risk exceeds InpRiskPercentPerTrade (%.2f%%).",
                        decision.decision_id, lots, InpRiskPercentPerTrade);

         double proposedRisk = g_risk.RiskAmountForLots(_Symbol, lots, entry, chosen.stop_loss);
         string blockReason;
         if(!g_portfolio.AllowNewTrade(_Symbol, proposedRisk, blockReason))
            PrintFormat("MedisTouch EA: decision #%d blocked by Portfolio Manager — %s", decision.decision_id, blockReason);
         else
           {
            ulong ticketOut = 0;
            double maxDeviation = InpMaxEntryDeviationATR * currentAtr;
            if(g_orders.Submit(decision, lots, InpUseMarketOrders, maxDeviation, ticketOut))
               g_store.SaveExecution(decision.decision_id, lots, ticketOut);
            else
               g_monitor.NotifyBrokerReject();
           }
        }
     }
   if(decision.action == POLICY_SIGNAL_ONLY || decision.action == POLICY_EXECUTE_AND_SIGNAL)
     {
      g_publisher.Publish(decision);
      // v2.9: start lifecycle-monitoring this decision. Overwrites
      // whatever was being tracked before — matches the
      // one-active-setup-at-a-time model g_lastLoggedTime already
      // assumes elsewhere in this function.
      g_lifecycleDecisionId = decision.decision_id;
      g_lifecycleCreationTime = chosen.creation_time;
      g_lifecycleSetup = chosen;
      g_lifecycleStatus = "valid";
     }
  }
//+------------------------------------------------------------------+
// C003 FIX: a resting limit order (InpUseMarketOrders = false) sits in
// TS_PENDING with the ORDER ticket recorded. Before this handler existed,
// nothing ever noticed that order fill — PositionManager only manages
// trades already at TS_FILLED or later, and OnTick() never polls pending
// orders for a fill. The trade sat invisible to break-even/partial/trail
// logic until the terminal restarted and Recovery() reconstructed state
// from broker-side truth. OnTradeTransaction fires synchronously the
// moment MT5 books the fill, so this closes the gap live instead of
// waiting for a restart. Market-order fills are untouched by this — those
// already transition to TS_FILLED inside COrderManager::Submit() in the
// same call that sends the order.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;

   // Only the deal that OPENS a position can be a pending order's first
   // fill — a closing or partial-closing deal also raises DEAL_ADD and
   // must not be mistaken for one.
   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_IN) return;
   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;

   ulong orderTicket    = (ulong)HistoryDealGetInteger(trans.deal, DEAL_ORDER);
   ulong positionTicket = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   if(orderTicket == 0 || positionTicket == 0) return;

   double fillPrice = HistoryDealGetDouble(trans.deal, DEAL_PRICE); // FIX (#25): real fill price, straight off the deal record
   if(g_orders.MarkFilledFromPending(orderTicket, positionTicket, fillPrice))
      PrintFormat("MedisTouch EA: pending order #%d filled as position #%d at %.5f — caught live via OnTradeTransaction.",
                  orderTicket, positionTicket, fillPrice);
  }
//+------------------------------------------------------------------+
