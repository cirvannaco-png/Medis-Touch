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
