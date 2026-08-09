//+------------------------------------------------------------------+
//|                                     Analysis/VolatilityRegime.mqh |
//+------------------------------------------------------------------+
#ifndef VOLATILITYREGIME_MQH
#define VOLATILITYREGIME_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"

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
