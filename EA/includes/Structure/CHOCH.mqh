//+------------------------------------------------------------------+
//|                                                 Structure/CHOCH.mqh |
//+------------------------------------------------------------------+
#ifndef CHOCH_MQH
#define CHOCH_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"
#include "SwingDetector.mqh"

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
