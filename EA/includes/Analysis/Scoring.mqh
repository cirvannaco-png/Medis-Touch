//+------------------------------------------------------------------+
//|                                                Analysis/Scoring.mqh |
//+------------------------------------------------------------------+
#ifndef SCORING_MQH
#define SCORING_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"
#include "TFContext.mqh"
#include "../SmartMoney/Inducement.mqh"
#include "../SmartMoney/PremiumDiscount.mqh"
#include "../SmartMoney/MarketPhase.mqh"
#include "../SmartMoney/OrderBlock.mqh"
#include "VolatilityRegime.mqh"
#include "../Core/SessionFilter.mqh"
#include "../Core/PipCalculator.mqh"
#include "../Regime/RegimeDetector.mqh"
#include "../Strategies/MomentumBreakout.mqh"
#include "../Strategies/MeanReversion.mqh"
#include "../Strategies/KeyLevelReaction.mqh"
#include "../Strategies/StrategySelector.mqh"

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
