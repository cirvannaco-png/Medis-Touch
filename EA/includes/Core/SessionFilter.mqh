//+------------------------------------------------------------------+
//|                                          Core/SessionFilter.mqh   |
//+------------------------------------------------------------------+
#ifndef SESSIONFILTER_MQH
#define SESSIONFILTER_MQH

#include "Config.mqh"

// v2.8 addition. Pre-v2.8 the only session-aware code was
// CSignalLogger::SessionLabel() — a string used purely for CSV bucketing
// after the fact. It was never read by anything that decides whether to
// trade. This class is the actual gate: classifies the current GMT hour
// into a named session and exposes IsAllowed() so Scoring can block
// entries generated during configured-off windows (default: Tokyo-only
// and dead hours off, London/NY/overlap on) instead of trading every
// session uniformly regardless of liquidity.
//
// Windows are GMT-hour based (TimeGMT(), not TimeCurrent()) so behavior
// doesn't silently shift with the broker's own DST convention.
class CSessionFilter
  {
private:
   bool              m_enabled;
   bool              m_allowTokyo;
   bool              m_allowLondon;
   bool              m_allowNewYork;
   bool              m_allowOverlap;   // London/NY overlap — highest-liquidity window, allowed even if
                                        // m_allowLondon/m_allowNewYork are individually off
public:
                     CSessionFilter();
   void              Configure(bool enabled, bool allowTokyo = false, bool allowLondon = true,
                               bool allowNewYork = true, bool allowOverlap = true);
   ENUM_TRADING_SESSION CurrentSession();
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
// Standard FX session hours in GMT: Tokyo 00-09, London 07-16, New York
// 12-21. Overlap = 12-16 (London afternoon / NY morning), the window
// most SMC liquidity-sweep setups are built around.
ENUM_TRADING_SESSION CSessionFilter::CurrentSession()
  {
   MqlDateTime t;
   TimeToStruct(TimeGMT(), t);
   int h = t.hour;

   bool tokyo   = (h >= 0  && h < 9);
   bool london  = (h >= 7  && h < 16);
   bool newyork = (h >= 12 && h < 21);

   if(london && newyork) return SESSION_LONDON_NY_OVERLAP;
   if(london)  return SESSION_LONDON;
   if(newyork) return SESSION_NEWYORK;
   if(tokyo)   return SESSION_TOKYO;
   return SESSION_DEAD;
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
