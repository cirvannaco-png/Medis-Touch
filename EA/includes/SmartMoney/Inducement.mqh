//+------------------------------------------------------------------+
//|                                          SmartMoney/Inducement.mqh |
//+------------------------------------------------------------------+
#ifndef INDUCEMENT_MQH
#define INDUCEMENT_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"

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
