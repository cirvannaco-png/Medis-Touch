//+------------------------------------------------------------------+
//|                                    Trading/CalibrationEngine.mqh  |
//+------------------------------------------------------------------+
#ifndef CALIBRATIONENGINE_MQH
#define CALIBRATIONENGINE_MQH

// v2.9 addition — review item #1 / #9: "a confidence score isn't a
// probability until it's been checked against real outcomes." This
// bucket-tracks CScoringEngine::CalculateConfidence()'s output against
// COutcomeTracker's resolved win/loss verdicts and reports the ACTUAL
// historical win rate for each confidence range, persisted to a file so
// the sample survives restarts.
//
// HONEST LIMITATIONS — read before trusting the numbers this produces:
//  1. This does NOT change trading behavior on its own. Nothing in the
//     EA gates on calibrated probability yet — it is purely an
//     observability layer that answers "is an 80 actually an 80?" You
//     have to look at the numbers and decide what to do with them (e.g.
//     discover 90+ underperforms 80-89 and investigate why, per review
//     item #9). Wiring a live gate off this is a deliberate next step,
//     not something this file does implicitly.
//  2. Sample sizes below MIN_SAMPLE (default 30) per bucket are reported
//     but flagged low-confidence — with a live strategy this realistically
//     means MONTHS of forward/backtest data before any bucket's number
//     means anything. Don't trust a 5-trade bucket's win rate.
//  3. Buckets are fixed 5-point-wide bins from 0-100 (20 buckets). This
//     is a starting resolution, not a tuned one — too fine and you never
//     accumulate samples per bucket, too coarse and you can't see
//     structure like "90+ underperforms 80-89". Revisit once you have
//     real volume.
//  4. This tracks the RAW CalculateConfidence() output at the moment
//     AddSetup() logged the trade — if you change the scoring formula
//     (as the v2.9 sweep-grade/BOS-strength/decay changes in this same
//     release do), OLD calibration data no longer describes the NEW
//     score's meaning. Clear/reset the calibration file after any
//     scoring-formula change, or you'll be calibrating against a
//     confidence definition that no longer exists. See Reset().
//  5. Calibration is symbol-agnostic by construction (one file per
//     EA instance/symbol, same as OutcomeTracker's CSV) — a XAUUSD
//     bucket's win rate says nothing about EURUSD's. Don't share the
//     file across symbols.
class CCalibrationEngine
  {
private:
   static const int  NUM_BUCKETS = 20; // 0-5, 5-10, ..., 95-100
   int               m_wins[NUM_BUCKETS];
   int               m_losses[NUM_BUCKETS];
   int               m_scratches[NUM_BUCKETS];
   string            m_filename;
   int               m_minSample;

   int               BucketIndex(double confidence) const
     {
      int idx = (int)MathFloor(confidence / 5.0);
      return (int)MathMax(0, MathMin(idx, NUM_BUCKETS - 1));
     }

public:
                     CCalibrationEngine() : m_filename(""), m_minSample(30)
     {
      ArrayInitialize(m_wins, 0);
      ArrayInitialize(m_losses, 0);
      ArrayInitialize(m_scratches, 0);
     }

   void              Init(string symbol, int minSample = 30, bool useCommonFolder = false)
     {
      m_filename = "MedisTouch_Calibration_" + symbol + ".csv";
      m_minSample = MathMax(1, minSample);
      Load(useCommonFolder);
     }

   // Call once per resolved, sized (lots>0), non-ambiguous trade — see
   // COutcomeTracker::FinalizeExit() for the call site. netPnL > 0 counts
   // as a win, < 0 a loss, == 0 a scratch (matches OutcomeStats'
   // win/loss/scratch convention exactly, so this stays consistent with
   // the dashboard's headline win rate).
   void              Record(double confidence, double netPnL, bool useCommonFolder = false)
     {
      int b = BucketIndex(confidence);
      if(netPnL > 0.0000001)      m_wins[b]++;
      else if(netPnL < -0.0000001) m_losses[b]++;
      else                          m_scratches[b]++;
      Save(useCommonFolder); // flush every trade — this is low-frequency (one call per resolved trade), not per-tick
     }

   // Returns the empirical win rate for the bucket confidence falls
   // into, the sample size behind it, and whether that sample clears
   // m_minSample. hasEnoughData=false is not "no edge" — it's "don't
   // trust this number yet."
   double            GetCalibratedProbability(double confidence, int &sampleSizeOut, bool &hasEnoughDataOut) const
     {
      int b = BucketIndex(confidence);
      int w = m_wins[b], l = m_losses[b];
      int total = w + l; // scratches excluded from the win-rate denominator, same convention as OutcomeStats.WinRateExcludingAmbiguous()
      sampleSizeOut = total;
      hasEnoughDataOut = (total >= m_minSample);
      if(total == 0) return 0.0;
      return 100.0 * w / total;
     }

   // Whole-curve dump for the dashboard/CSV export — one row per bucket,
   // "" for the string return means "print this yourself", kept simple
   // rather than building a UI dependency into this file.
   string            BucketSummary(int bucketIdx) const
     {
      if(bucketIdx < 0 || bucketIdx >= NUM_BUCKETS) return "";
      int lo = bucketIdx * 5, hi = lo + 5;
      int w = m_wins[bucketIdx], l = m_losses[bucketIdx], s = m_scratches[bucketIdx];
      int total = w + l;
      double wr = (total > 0) ? (100.0 * w / total) : 0.0;
      return StringFormat("%d-%d: %d trades, %.1f%% win rate%s", lo, hi, total, wr,
                           (total < m_minSample) ? " (low sample)" : "");
     }
   int               NumBuckets() const { return NUM_BUCKETS; }

   // v2.9 note #4 above — call this after any scoring-formula change so
   // stale-definition data doesn't masquerade as current calibration.
   void              Reset(bool useCommonFolder = false)
     {
      ArrayInitialize(m_wins, 0);
      ArrayInitialize(m_losses, 0);
      ArrayInitialize(m_scratches, 0);
      Save(useCommonFolder);
     }

   void              Save(bool useCommonFolder = false)
     {
      if(StringLen(m_filename) == 0) return;
      int flags = FILE_CSV | FILE_WRITE | FILE_ANSI;
      if(useCommonFolder) flags |= FILE_COMMON;
      int h = FileOpen(m_filename, flags, ',');
      if(h == INVALID_HANDLE) return;
      FileWrite(h, "BucketLow", "BucketHigh", "Wins", "Losses", "Scratches");
      for(int i = 0; i < NUM_BUCKETS; i++)
         FileWrite(h, i * 5, i * 5 + 5, m_wins[i], m_losses[i], m_scratches[i]);
      FileClose(h);
     }

   bool              Load(bool useCommonFolder = false)
     {
      if(StringLen(m_filename) == 0) return false;
      int flags = FILE_CSV | FILE_READ | FILE_SHARE_READ | FILE_ANSI;
      if(useCommonFolder) flags |= FILE_COMMON;
      int h = FileOpen(m_filename, flags, ',');
      if(h == INVALID_HANDLE) return false; // no prior file — fresh start, not an error

      // header row
      for(int c = 0; c < 5 && !FileIsEnding(h); c++) FileReadString(h);

      int i = 0;
      while(!FileIsEnding(h) && i < NUM_BUCKETS)
        {
         string loS = FileReadString(h);
         if(FileIsEnding(h)) break;
         FileReadString(h); // hi, unused (derivable from index)
         string wS = FileReadString(h);
         string lS = FileReadString(h);
         string sS = FileReadString(h);
         m_wins[i] = (int)StringToInteger(wS);
         m_losses[i] = (int)StringToInteger(lS);
         m_scratches[i] = (int)StringToInteger(sS);
         i++;
        }
      FileClose(h);
      return true;
     }
  };
#endif
//+------------------------------------------------------------------+
