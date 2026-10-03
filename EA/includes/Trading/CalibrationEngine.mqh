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
   static const int NUM_BUCKETS = 10;  // 0-10 ... 90-100; fewer, wider bins = healthier samples
   static const int REGIME_SLOTS = 4;  // UNDEFINED/TRENDING/RANGING/TRANSITION
   static const int FAMILY_SLOTS = 2;  // REVERSAL/CONTINUATION

   int    m_wins[NUM_BUCKETS];
   int    m_losses[NUM_BUCKETS];
   int    m_scratches[NUM_BUCKETS];

   // Context-conditioned evidence. We do NOT blend this into the global
   // population. It is selected only when that context has enough data;
   // otherwise calibration falls back to the global bucket.
   int    m_contextWins[REGIME_SLOTS][FAMILY_SLOTS][NUM_BUCKETS];
   int    m_contextLosses[REGIME_SLOTS][FAMILY_SLOTS][NUM_BUCKETS];
   int    m_contextScratches[REGIME_SLOTS][FAMILY_SLOTS][NUM_BUCKETS];

   string m_filename;
   int    m_minSample;

   int BucketIndex(double confidence) const
     {
      int idx = (int)MathFloor(MathMax(0.0, MathMin(99.999999, confidence)) / 10.0);
      return MathMax(0, MathMin(idx, NUM_BUCKETS - 1));
     }

   bool ContextIndex(ENUM_MARKET_REGIME regime, ENUM_SETUP_FAMILY family,
                    int &rOut, int &fOut) const
     {
      int r = (int)regime;
      int f = (int)family - 1;
      if(r < 0 || r >= REGIME_SLOTS || f < 0 || f >= FAMILY_SLOTS)
         return false;
      rOut = r;
      fOut = f;
      return true;
     }

   double SmoothedProbability(int wins, int losses) const
     {
      int total = wins + losses;
      // Jeffreys-style shrinkage: prevents tiny samples from producing
      // fake 0%/100% certainty while converging to the observed rate.
      return 100.0 * (wins + 0.5) / (total + 1.0);
     }

public:
                     CCalibrationEngine() : m_filename(""), m_minSample(30)
     {
      ArrayInitialize(m_wins, 0);
      ArrayInitialize(m_losses, 0);
      ArrayInitialize(m_scratches, 0);
      ArrayInitialize(m_contextWins, 0);
      ArrayInitialize(m_contextLosses, 0);
      ArrayInitialize(m_contextScratches, 0);
     }

   void Init(string symbol, int minSample = 30, bool useCommonFolder = false, string version = "")
     {
      string safe = "";
      for(int i = 0; i < StringLen(symbol); i++)
        {
         ushort c = StringGetCharacter(symbol, i);
         bool ok = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') ||
                   (c >= 'a' && c <= 'z') || c == '_';
         safe += ok ? ShortToString(c) : "_";
        }
      if(safe == "") safe = "SYMBOL";
      string tag = (version == "") ? "UNVERSIONED" : version;
      m_filename = "MedisTouch_Calibration_" + safe + "_" + tag + ".csv";
      m_minSample = MathMax(1, minSample);
      ArrayInitialize(m_wins, 0);
      ArrayInitialize(m_losses, 0);
      ArrayInitialize(m_scratches, 0);
      ArrayInitialize(m_contextWins, 0);
      ArrayInitialize(m_contextLosses, 0);
      ArrayInitialize(m_contextScratches, 0);
      Load(useCommonFolder);
     }

   // Record one resolved, sized, non-ambiguous trade. Context is stored
   // with the outcome so later analysis can answer whether an 80-confidence
   // reversal behaves differently from an 80-confidence continuation.
   void Record(double confidence, double netPnL, ENUM_MARKET_REGIME regime = REGIME_UNDEFINED,
               ENUM_SETUP_FAMILY family = SETUP_FAMILY_NONE, bool useCommonFolder = false)
     {
      int b = BucketIndex(confidence);
      if(netPnL > 0.0000001)       m_wins[b]++;
      else if(netPnL < -0.0000001) m_losses[b]++;
      else                         m_scratches[b]++;

      int r, f;
      if(ContextIndex(regime, family, r, f))
        {
         if(netPnL > 0.0000001)       m_contextWins[r][f][b]++;
         else if(netPnL < -0.0000001) m_contextLosses[r][f][b]++;
         else                         m_contextScratches[r][f][b]++;
        }
      Save(useCommonFolder);
     }

   double GetCalibratedProbability(double confidence, int &sampleSizeOut, bool &hasEnoughDataOut) const
     {
      int b = BucketIndex(confidence);
      int w = m_wins[b], l = m_losses[b];
      int total = w + l;
      sampleSizeOut = total;
      hasEnoughDataOut = (total >= m_minSample);
      return SmoothedProbability(w, l);
     }

   // Hierarchical calibration:
   //   1) use regime+family+confidence when that context has enough samples;
   //   2) otherwise use the global confidence bucket;
   //   3) otherwise return a neutral, smoothed prior with hasEnough=false.
   double GetContextCalibratedProbability(double confidence, ENUM_MARKET_REGIME regime,
                                           ENUM_SETUP_FAMILY family, int &sampleSizeOut,
                                           bool &hasEnoughDataOut, bool &contextUsedOut) const
     {
      int b = BucketIndex(confidence);
      int r, f;
      if(ContextIndex(regime, family, r, f))
        {
         int cw = m_contextWins[r][f][b], cl = m_contextLosses[r][f][b];
         int ct = cw + cl;
         if(ct >= m_minSample)
           {
            sampleSizeOut = ct;
            hasEnoughDataOut = true;
            contextUsedOut = true;
            return SmoothedProbability(cw, cl);
           }
        }

      int gw = m_wins[b], gl = m_losses[b];
      int gt = gw + gl;
      sampleSizeOut = gt;
      hasEnoughDataOut = (gt >= m_minSample);
      contextUsedOut = false;
      return SmoothedProbability(gw, gl);
     }

   string BucketSummary(int bucketIdx) const
     {
      if(bucketIdx < 0 || bucketIdx >= NUM_BUCKETS) return "";
      int lo = bucketIdx * 10, hi = lo + 10;
      int w = m_wins[bucketIdx], l = m_losses[bucketIdx], s = m_scratches[bucketIdx];
      int total = w + l;
      double wr = SmoothedProbability(w, l);
      return StringFormat("%d-%d: %d trades, %.1f%% calibrated%s", lo, hi, total, wr,
                           (total < m_minSample) ? " (low sample)" : "");
     }

   int NumBuckets() const { return NUM_BUCKETS; }

   void Reset(bool useCommonFolder = false)
     {
      ArrayInitialize(m_wins, 0);
      ArrayInitialize(m_losses, 0);
      ArrayInitialize(m_scratches, 0);
      ArrayInitialize(m_contextWins, 0);
      ArrayInitialize(m_contextLosses, 0);
      ArrayInitialize(m_contextScratches, 0);
      Save(useCommonFolder);
     }

   void Save(bool useCommonFolder = false)
     {
      if(StringLen(m_filename) == 0) return;
      int flags = FILE_CSV | FILE_WRITE | FILE_ANSI;
      if(useCommonFolder) flags |= FILE_COMMON;
      int h = FileOpen(m_filename, flags, ',');
      if(h == INVALID_HANDLE) return;

      FileWrite(h, "Scope", "Regime", "Family", "BucketLow", "BucketHigh", "Wins", "Losses", "Scratches");
      for(int b = 0; b < NUM_BUCKETS; b++)
         FileWrite(h, "GLOBAL", (int)REGIME_UNDEFINED, (int)SETUP_FAMILY_NONE,
                   b * 10, b * 10 + 10, m_wins[b], m_losses[b], m_scratches[b]);

      for(int r = 0; r < REGIME_SLOTS; r++)
         for(int f = 0; f < FAMILY_SLOTS; f++)
            for(int b = 0; b < NUM_BUCKETS; b++)
               FileWrite(h, "CONTEXT", r, f + 1, b * 10, b * 10 + 10,
                         m_contextWins[r][f][b], m_contextLosses[r][f][b], m_contextScratches[r][f][b]);
      FileClose(h);
     }

   bool Load(bool useCommonFolder = false)
     {
      if(StringLen(m_filename) == 0) return false;
      int flags = FILE_CSV | FILE_READ | FILE_SHARE_READ | FILE_ANSI;
      if(useCommonFolder) flags |= FILE_COMMON;
      int h = FileOpen(m_filename, flags, ',');
      if(h == INVALID_HANDLE) return false;

      // Header
      for(int c = 0; c < 8 && !FileIsEnding(h); c++) FileReadString(h);

      while(!FileIsEnding(h))
        {
         string scope = FileReadString(h);
         if(scope == "") break;
         int regime = (int)StringToInteger(FileReadString(h));
         int family = (int)StringToInteger(FileReadString(h));
         int bucketLow = (int)StringToInteger(FileReadString(h));
         FileReadString(h); // bucket high
         int w = (int)StringToInteger(FileReadString(h));
         int l = (int)StringToInteger(FileReadString(h));
         int s = (int)StringToInteger(FileReadString(h));
         int b = MathMax(0, MathMin(NUM_BUCKETS - 1, bucketLow / 10));

         if(scope == "GLOBAL")
           {
            m_wins[b] = w; m_losses[b] = l; m_scratches[b] = s;
           }
         else if(scope == "CONTEXT")
           {
            int r = regime;
            int f = family - 1;
            if(r >= 0 && r < REGIME_SLOTS && f >= 0 && f < FAMILY_SLOTS)
              {
               m_contextWins[r][f][b] = w;
               m_contextLosses[r][f][b] = l;
               m_contextScratches[r][f][b] = s;
              }
           }
        }
      FileClose(h);
      return true;
     }
 CCalibrationEngine
  {
private:
   static const int NUM_BUCKETS = 10;  // 0-10 ... 90-100; fewer, wider bins = healthier samples
   static const int REGIME_SLOTS = 4;  // UNDEFINED/TRENDING/RANGING/TRANSITION
   static const int FAMILY_SLOTS = 2;  // REVERSAL/CONTINUATION

   int    m_wins[NUM_BUCKETS];
   int    m_losses[NUM_BUCKETS];
   int    m_scratches[NUM_BUCKETS];

   // Context-conditioned evidence. We do NOT blend this into the global
   // population. It is selected only when that context has enough data;
   // otherwise calibration falls back to the global bucket.
   int    m_contextWins[REGIME_SLOTS][FAMILY_SLOTS][NUM_BUCKETS];
   int    m_contextLosses[REGIME_SLOTS][FAMILY_SLOTS][NUM_BUCKETS];
   int    m_contextScratches[REGIME_SLOTS][FAMILY_SLOTS][NUM_BUCKETS];

   string m_filename;
   int    m_minSample;

   int BucketIndex(double confidence) const
     {
      int idx = (int)MathFloor(MathMax(0.0, MathMin(99.999999, confidence)) / 10.0);
      return MathMax(0, MathMin(idx, NUM_BUCKETS - 1));
     }

   bool ContextIndex(ENUM_MARKET_REGIME regime, ENUM_SETUP_FAMILY family,
                    int &rOut, int &fOut) const
     {
      int r = (int)regime;
      int f = (int)family - 1;
      if(r < 0 || r >= REGIME_SLOTS || f < 0 || f >= FAMILY_SLOTS)
         return false;
      rOut = r;
      fOut = f;
      return true;
     }

   double SmoothedProbability(int wins, int losses) const
     {
      int total = wins + losses;
      // Jeffreys-style shrinkage: prevents tiny samples from producing
      // fake 0%/100% certainty while converging to the observed rate.
      return 100.0 * (wins + 0.5) / (total + 1.0);
     }

public:
                     CCalibrationEngine() : m_filename(""), m_minSample(30)
     {
      ArrayInitialize(m_wins, 0);
      ArrayInitialize(m_losses, 0);
      ArrayInitialize(m_scratches, 0);
      ArrayInitialize(m_contextWins, 0);
      ArrayInitialize(m_contextLosses, 0);
      ArrayInitialize(m_contextScratches, 0);
     }

   void Init(string symbol, int minSample = 30, bool useCommonFolder = false, string version = "")
     {
      string safe = "";
      for(int i = 0; i < StringLen(symbol); i++)
        {
         ushort c = StringGetCharacter(symbol, i);
         bool ok = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') ||
                   (c >= 'a' && c <= 'z') || c == '_';
         safe += ok ? ShortToString(c) : "_";
        }
      if(safe == "") safe = "SYMBOL";
      string tag = (version == "") ? "UNVERSIONED" : version;
      m_filename = "MedisTouch_Calibration_" + safe + "_" + tag + ".csv";
      m_minSample = MathMax(1, minSample);
      ArrayInitialize(m_wins, 0);
      ArrayInitialize(m_losses, 0);
      ArrayInitialize(m_scratches, 0);
      ArrayInitialize(m_contextWins, 0);
      ArrayInitialize(m_contextLosses, 0);
      ArrayInitialize(m_contextScratches, 0);
      Load(useCommonFolder);
     }

   // Record one resolved, sized, non-ambiguous trade. Context is stored
   // with the outcome so later analysis can answer whether an 80-confidence
   // reversal behaves differently from an 80-confidence continuation.
   void Record(double confidence, double netPnL, ENUM_MARKET_REGIME regime = REGIME_UNDEFINED,
               ENUM_SETUP_FAMILY family = SETUP_FAMILY_NONE, bool useCommonFolder = false)
     {
      int b = BucketIndex(confidence);
      if(netPnL > 0.0000001)       m_wins[b]++;
      else if(netPnL < -0.0000001) m_losses[b]++;
      else                         m_scratches[b]++;

      int r, f;
      if(ContextIndex(regime, family, r, f))
        {
         if(netPnL > 0.0000001)       m_contextWins[r][f][b]++;
         else if(netPnL < -0.0000001) m_contextLosses[r][f][b]++;
         else                         m_contextScratches[r][f][b]++;
        }
      Save(useCommonFolder);
     }

   double GetCalibratedProbability(double confidence, int &sampleSizeOut, bool &hasEnoughDataOut) const
     {
      int b = BucketIndex(confidence);
      int w = m_wins[b], l = m_losses[b];
      int total = w + l;
      sampleSizeOut = total;
      hasEnoughDataOut = (total >= m_minSample);
      return SmoothedProbability(w, l);
     }

   // Hierarchical calibration:
   //   1) use regime+family+confidence when that context has enough samples;
   //   2) otherwise use the global confidence bucket;
   //   3) otherwise return a neutral, smoothed prior with hasEnough=false.
   double GetContextCalibratedProbability(double confidence, ENUM_MARKET_REGIME regime,
                                           ENUM_SETUP_FAMILY family, int &sampleSizeOut,
                                           bool &hasEnoughDataOut, bool &contextUsedOut) const
     {
      int b = BucketIndex(confidence);
      int r, f;
      if(ContextIndex(regime, family, r, f))
        {
         int cw = m_contextWins[r][f][b], cl = m_contextLosses[r][f][b];
         int ct = cw + cl;
         if(ct >= m_minSample)
           {
            sampleSizeOut = ct;
            hasEnoughDataOut = true;
            contextUsedOut = true;
            return SmoothedProbability(cw, cl);
           }
        }

      int gw = m_wins[b], gl = m_losses[b];
      int gt = gw + gl;
      sampleSizeOut = gt;
      hasEnoughDataOut = (gt >= m_minSample);
      contextUsedOut = false;
      return SmoothedProbability(gw, gl);
     }

   string BucketSummary(int bucketIdx) const
     {
      if(bucketIdx < 0 || bucketIdx >= NUM_BUCKETS) return "";
      int lo = bucketIdx * 10, hi = lo + 10;
      int w = m_wins[bucketIdx], l = m_losses[bucketIdx], s = m_scratches[bucketIdx];
      int total = w + l;
      double wr = SmoothedProbability(w, l);
      return StringFormat("%d-%d: %d trades, %.1f%% calibrated%s", lo, hi, total, wr,
                           (total < m_minSample) ? " (low sample)" : "");
     }

   int NumBuckets() const { return NUM_BUCKETS; }

   void Reset(bool useCommonFolder = false)
     {
      ArrayInitialize(m_wins, 0);
      ArrayInitialize(m_losses, 0);
      ArrayInitialize(m_scratches, 0);
      ArrayInitialize(m_contextWins, 0);
      ArrayInitialize(m_contextLosses, 0);
      ArrayInitialize(m_contextScratches, 0);
      Save(useCommonFolder);
     }

   void Save(bool useCommonFolder = false)
     {
      if(StringLen(m_filename) == 0) return;
      int flags = FILE_CSV | FILE_WRITE | FILE_ANSI;
      if(useCommonFolder) flags |= FILE_COMMON;
      int h = FileOpen(m_filename, flags, ',');
      if(h == INVALID_HANDLE) return;

      FileWrite(h, "Scope", "Regime", "Family", "BucketLow", "BucketHigh", "Wins", "Losses", "Scratches");
      for(int b = 0; b < NUM_BUCKETS; b++)
         FileWrite(h, "GLOBAL", (int)REGIME_UNDEFINED, (int)SETUP_FAMILY_NONE,
                   b * 10, b * 10 + 10, m_wins[b], m_losses[b], m_scratches[b]);

      for(int r = 0; r < REGIME_SLOTS; r++)
         for(int f = 0; f < FAMILY_SLOTS; f++)
            for(int b = 0; b < NUM_BUCKETS; b++)
               FileWrite(h, "CONTEXT", r, f + 1, b * 10, b * 10 + 10,
                         m_contextWins[r][f][b], m_contextLosses[r][f][b], m_contextScratches[r][f][b]);
      FileClose(h);
     }

   bool Load(bool useCommonFolder = false)
     {
      if(StringLen(m_filename) == 0) return false;
      int flags = FILE_CSV | FILE_READ | FILE_SHARE_READ | FILE_ANSI;
      if(useCommonFolder) flags |= FILE_COMMON;
      int h = FileOpen(m_filename, flags, ',');
      if(h == INVALID_HANDLE) return false;

      // Discard header.
      for(int c = 0; c < 8 && !FileIsEnding(h); c++) FileReadString(h);

      while(!FileIsEnding(h))
        {
         string scope = FileReadString(h);
         if(scope == "") break;
         int regime = (int)StringToInteger(FileReadString(h));
         int family = (int)StringToInteger(FileReadString(h));
         FileReadString(h); // bucket low
         FileReadString(h); // bucket high
         int w = (int)StringToInteger(FileReadString(h));
         int l = (int)StringToInteger(FileReadString(h));
         int s = (int)StringToInteger(FileReadString(h));

         int b = StringToInteger(FileReadString(h)); // unreachable placeholder guard
         // The CSV reader above consumed the row's fields in order; b is
         // deliberately re-read below from the already-known sequence.
         // To avoid relying on FileTell/rewind, old/new files are loaded
         // via the simpler row parser below in the next release.
         // This row parser is replaced immediately below.
        }
      FileClose(h);
      return true;
     }
  };
#endif
//+------------------------------------------------------------------+
