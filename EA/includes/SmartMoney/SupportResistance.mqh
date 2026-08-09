//+------------------------------------------------------------------+
//|                                     SmartMoney/SupportResistance.mqh |
//+------------------------------------------------------------------+
#ifndef SUPPORTRESISTANCE_MQH
#define SUPPORTRESISTANCE_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"
#include "../Structure/SwingDetector.mqh"

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
