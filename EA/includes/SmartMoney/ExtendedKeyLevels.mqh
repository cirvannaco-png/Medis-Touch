//+------------------------------------------------------------------+
//|                                SmartMoney/ExtendedKeyLevels.mqh   |
//+------------------------------------------------------------------+
#ifndef EXTENDEDKEYLEVELS_MQH
#define EXTENDEDKEYLEVELS_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"
#include "../Core/SessionFilter.mqh"

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
