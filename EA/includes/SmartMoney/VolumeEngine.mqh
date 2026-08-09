//+------------------------------------------------------------------+
//|                                       SmartMoney/VolumeEngine.mqh |
//+------------------------------------------------------------------+
#ifndef VOLUMEENGINE_MQH
#define VOLUMEENGINE_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"

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
