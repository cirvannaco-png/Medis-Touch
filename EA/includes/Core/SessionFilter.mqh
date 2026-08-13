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
