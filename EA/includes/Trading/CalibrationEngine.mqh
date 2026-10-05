//+------------------------------------------------------------------+
//|                                    Trading/CalibrationEngine.mqh  |
//+------------------------------------------------------------------+
#ifndef CALIBRATIONENGINE_MQH
#define CALIBRATIONENGINE_MQH

// v2.17 calibration. Confidence is treated as an empirical statistic,
// not a probability claim. Outcomes are tracked globally and, when sample
// size permits, by regime + setup family + confidence bucket. The
// context-conditioned result is hierarchical: use the context bucket only
// when it has enough data; otherwise fall back to the global bucket.
//
// HONEST LIMITATIONS — read before trusting the numbers this produces:
//  1. Calibration is observational data until an explicit policy gate
//     consumes it. v2.19 uses that data in the execution precision tier,
//     while the broader signal stream can remain enabled for evidence gathering. It
//     have to look at the numbers and decide what to do with them (e.g.
//     discover 90+ underperforms 80-89 and investigate why, per review
//     item #9). Wiring a live gate off this is a deliberate next step,
//     not something this file does implicitly.
//  2. Sample sizes below MIN_SAMPLE (default 30) per context bucket are reported
//     but flagged low-confidence — with a live strategy this realistically
//     means MONTHS of forward/backtest data before any bucket's number
//     means anything. Don't trust a 5-trade bucket's win rate.
//  3. Buckets are fixed 10-point-wide bins from 0-100 (10 buckets). This
//     deliberately trades resolution for sample depth; the bin width is
//     still a research parameter, not an optimized fact.
//  4. The calibration file is versioned with MIDAS_WEIGHT_SET_VERSION so
//     changing the scoring definition automatically moves new outcomes
//     onto a new evidence population rather than mixing incompatible scores.
//  5. This tracks the RAW CalculateConfidence() output at the moment
//     AddSetup() logged the trade — if you change the scoring formula
//     (as the v2.9 sweep-grade/BOS-strength/decay changes in this same
//     release do), OLD calibration data no longer describes the NEW
//     score's meaning. Clear/reset the calibration file after any
//     scoring-formula change, or you'll be calibrating against a
//     confidence definition that no longer exists. See Reset().
//  6. Calibration remains diagnostic until independently validated. A
//     calibrated probability is never allowed to turn structurally-invalid
//     information into a trade.
class CCalibrationEngine
  {
private:
   static const int NUM_BUCKETS = 10;  // 0-10 ... 90-100
   static const int REGIME_SLOTS = 4;  // UNDEFINED/TRENDING/RANGING/TRANSITION
   static const int FAMILY_SLOTS = 2;  // REVERSAL/CONTINUATION

   int m_wins[NUM_BUCKETS];
   int m_losses[NUM_BUCKETS];
   int m_scratches[NUM_BUCKETS];

   int m_contextWins[REGIME_SLOTS][FAMILY_SLOTS][NUM_BUCKETS];
   int m_contextLosses[REGIME_SLOTS][FAMILY_SLOTS][NUM_BUCKETS];
   int m_contextScratches[REGIME_SLOTS][FAMILY_SLOTS][NUM_BUCKETS];
   // Target-reach calibration: probability that TP1/TP2/final target was
   // touched before the setup resolved. Stored separately from profit
   // outcome because a profitable partial trade can miss the final target.
   int m_tpHits[3][NUM_BUCKETS];
   int m_tpMisses[3][NUM_BUCKETS];
   int m_contextTpHits[3][REGIME_SLOTS][FAMILY_SLOTS][NUM_BUCKETS];
   int m_contextTpMisses[3][REGIME_SLOTS][FAMILY_SLOTS][NUM_BUCKETS];

   string m_filename;
   int m_minSample;

   int BucketIndex(double confidence) const
     {
      double c = MathMax(0.0, MathMin(99.999999, confidence));
      int idx = (int)MathFloor(c / 10.0);
      return MathMax(0, MathMin(idx, NUM_BUCKETS - 1));
     }

   bool ContextIndex(ENUM_MARKET_REGIME regime, ENUM_SETUP_FAMILY family,
                    int &rOut, int &fOut) const
     {
      int r = (int)regime;
      int f = (int)family - 1;
      if(r < 0 || r >= REGIME_SLOTS || f < 0 || f >= FAMILY_SLOTS) return false;
      rOut = r; fOut = f;
      return true;
     }

   double SmoothedProbability(int wins, int losses) const
     {
      int total = wins + losses;
      // Jeffreys-style prior: 50% before data, shrinking small samples
      // away from false 0%/100% certainty.
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
      ArrayInitialize(m_tpHits, 0);
      ArrayInitialize(m_tpMisses, 0);
      ArrayInitialize(m_contextTpHits, 0);
      ArrayInitialize(m_contextTpMisses, 0);
     }

   void Init(string symbol, int minSample = 30, bool useCommonFolder = false, string version = "")
     {
      string safe = "";
      for(int i = 0; i < StringLen(symbol); i++)
        {
         ushort ch = StringGetCharacter(symbol, i);
         bool ok = (ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'Z') ||
                   (ch >= 'a' && ch <= 'z') || ch == '_';
         safe += ok ? ShortToString(ch) : "_";
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
      ArrayInitialize(m_tpHits, 0);
      ArrayInitialize(m_tpMisses, 0);
      ArrayInitialize(m_contextTpHits, 0);
      ArrayInitialize(m_contextTpMisses, 0);
      Load(useCommonFolder);
     }

   void Record(double confidence, double netPnL,
               ENUM_MARKET_REGIME regime = REGIME_UNDEFINED,
               ENUM_SETUP_FAMILY family = SETUP_FAMILY_NONE,
               bool tp1Hit = false, bool tp2Hit = false, bool tp3Hit = false,
               bool useCommonFolder = false)
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

         // Every resolved, non-ambiguous trade has an observable answer for
         // each target: it either reached that target before resolution or it
         // did not. Keep target calibration independent of win/loss outcome.
         if(tp1Hit) m_contextTpHits[0][r][f][b]++; else m_contextTpMisses[0][r][f][b]++;
         if(tp2Hit) m_contextTpHits[1][r][f][b]++; else m_contextTpMisses[1][r][f][b]++;
         if(tp3Hit) m_contextTpHits[2][r][f][b]++; else m_contextTpMisses[2][r][f][b]++;
        }

      if(tp1Hit) m_tpHits[0][b]++; else m_tpMisses[0][b]++;
      if(tp2Hit) m_tpHits[1][b]++; else m_tpMisses[1][b]++;
      if(tp3Hit) m_tpHits[2][b]++; else m_tpMisses[2][b]++;

      Save(useCommonFolder);
     }

   double GetCalibratedProbability(double confidence, int &sampleSizeOut,
                                   bool &hasEnoughDataOut) const
     {
      int b = BucketIndex(confidence);
      int w = m_wins[b], l = m_losses[b];
      int total = w + l;
      sampleSizeOut = total;
      hasEnoughDataOut = (total >= m_minSample);
      return SmoothedProbability(w, l);
     }

   double GetContextCalibratedProbability(double confidence,
                                           ENUM_MARKET_REGIME regime,
                                           ENUM_SETUP_FAMILY family,
                                           int &sampleSizeOut,
                                           bool &hasEnoughDataOut,
                                           bool &contextUsedOut) const
     {
      int b = BucketIndex(confidence);
      int r, f;
      if(ContextIndex(regime, family, r, f))
        {
         int cw = m_contextWins[r][f][b];
         int cl = m_contextLosses[r][f][b];
         int ct = cw + cl;
         if(ct >= m_minSample)
           {
            sampleSizeOut = ct;
            hasEnoughDataOut = true;
            contextUsedOut = true;
            return SmoothedProbability(cw, cl);
           }

         // Sample-efficiency fallback: pool only adjacent confidence
         // buckets within the SAME regime + setup family. This does not
         // collapse across unrelated contexts and keeps the confidence
         // estimate local enough to avoid a global backfill when evidence
         // is sparse.
         int pooledW = 0, pooledL = 0;
         int fromB = MathMax(0, b - 1);
         int toB   = MathMin(NUM_BUCKETS - 1, b + 1);
         for(int pb = fromB; pb <= toB; pb++)
           {
            pooledW += m_contextWins[r][f][pb];
            pooledL += m_contextLosses[r][f][pb];
           }
         int pooledN = pooledW + pooledL;
         if(pooledN >= m_minSample)
           {
            sampleSizeOut = pooledN;
            hasEnoughDataOut = true;
            contextUsedOut = true;
            return SmoothedProbability(pooledW, pooledL);
           }
        }

      int gw = m_wins[b], gl = m_losses[b];
      int gt = gw + gl;
      sampleSizeOut = gt;
      hasEnoughDataOut = (gt >= m_minSample);
      contextUsedOut = false;
      return SmoothedProbability(gw, gl);
     }

   // Target IDs are canonicalized as 1=TP1, 2=TP2, 3=final TP.
   // This keeps the public API human-readable while the storage arrays remain
   // zero-based internally.
   double GetTargetCalibratedProbability(int targetIndex, double confidence,
                                                ENUM_MARKET_REGIME regime,
                                                ENUM_SETUP_FAMILY family,
                                                int &sampleSizeOut,
                                                bool &hasEnoughDataOut,
                                                bool &contextUsedOut) const
     {
      if(targetIndex < 1 || targetIndex > 3)
        {
         sampleSizeOut = 0; hasEnoughDataOut = false; contextUsedOut = false;
         return 50.0;
        }

      int b = BucketIndex(confidence);
      int t = targetIndex - 1;
      int r, f;
      if(ContextIndex(regime, family, r, f))
        {
         int ch = m_contextTpHits[t][r][f][b];
         int cm = m_contextTpMisses[t][r][f][b];
         int contextN = ch + cm;
         if(contextN >= m_minSample)
           {
            sampleSizeOut = contextN;
            hasEnoughDataOut = true;
            contextUsedOut = true;
            return SmoothedProbability(ch, cm);
           }

         // Same-context adjacent-bucket pooling for target calibration.
         // This is deliberately narrower than global fallback: regime and
         // setup family must match before evidence is pooled.
         int pooledHits = 0, pooledMisses = 0;
         int fromB = MathMax(0, b - 1);
         int toB   = MathMin(NUM_BUCKETS - 1, b + 1);
         for(int pb = fromB; pb <= toB; pb++)
           {
            pooledHits += m_contextTpHits[t][r][f][pb];
            pooledMisses += m_contextTpMisses[t][r][f][pb];
           }
         int pooledN = pooledHits + pooledMisses;
         if(pooledN >= m_minSample)
           {
            sampleSizeOut = pooledN;
            hasEnoughDataOut = true;
            contextUsedOut = true;
            return SmoothedProbability(pooledHits, pooledMisses);
           }
        }

      int hits = m_tpHits[t][b];
      int misses = m_tpMisses[t][b];
      int n = hits + misses;
      sampleSizeOut = n;
      hasEnoughDataOut = (n >= m_minSample);
      contextUsedOut = false;
      return SmoothedProbability(hits, misses);
     }

   string BucketSummary(int bucketIdx) const
     {
      if(bucketIdx < 0 || bucketIdx >= NUM_BUCKETS) return "";
      int lo = bucketIdx * 10;
      int hi = lo + 10;
      int w = m_wins[bucketIdx], l = m_losses[bucketIdx];
      int total = w + l;
      double p = SmoothedProbability(w, l);
      return StringFormat("%d-%d: %d trades, %.1f%% calibrated%s",
                          lo, hi, total, p,
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
      ArrayInitialize(m_tpHits, 0);
      ArrayInitialize(m_tpMisses, 0);
      ArrayInitialize(m_contextTpHits, 0);
      ArrayInitialize(m_contextTpMisses, 0);
      Save(useCommonFolder);
     }

   void Save(bool useCommonFolder = false)
     {
      if(StringLen(m_filename) == 0) return;
      int flags = FILE_CSV | FILE_WRITE | FILE_ANSI;
      if(useCommonFolder) flags |= FILE_COMMON;
      int h = FileOpen(m_filename, flags, ',');
      if(h == INVALID_HANDLE) return;

      FileWrite(h, "Scope", "Regime", "Family", "BucketLow", "BucketHigh", "Wins", "Losses", "Scratches",
                "TP1Hits", "TP1Misses", "TP2Hits", "TP2Misses", "TP3Hits", "TP3Misses");

      for(int b = 0; b < NUM_BUCKETS; b++)
         FileWrite(h, "GLOBAL", (int)REGIME_UNDEFINED, (int)SETUP_FAMILY_NONE,
                   b * 10, b * 10 + 10, m_wins[b], m_losses[b], m_scratches[b],
                   m_tpHits[0][b], m_tpMisses[0][b],
                   m_tpHits[1][b], m_tpMisses[1][b],
                   m_tpHits[2][b], m_tpMisses[2][b]);

      for(int r = 0; r < REGIME_SLOTS; r++)
         for(int f = 0; f < FAMILY_SLOTS; f++)
            for(int b = 0; b < NUM_BUCKETS; b++)
               FileWrite(h, "CONTEXT", r, f + 1, b * 10, b * 10 + 10,
                         m_contextWins[r][f][b], m_contextLosses[r][f][b],
                         m_contextScratches[r][f][b],
                         m_contextTpHits[0][r][f][b], m_contextTpMisses[0][r][f][b],
                         m_contextTpHits[1][r][f][b], m_contextTpMisses[1][r][f][b],
                         m_contextTpHits[2][r][f][b], m_contextTpMisses[2][r][f][b]);

      FileClose(h);
     }

   bool Load(bool useCommonFolder = false)
     {
      if(StringLen(m_filename) == 0) return false;
      int flags = FILE_CSV | FILE_READ | FILE_SHARE_READ | FILE_ANSI;
      if(useCommonFolder) flags |= FILE_COMMON;
      int h = FileOpen(m_filename, flags, ',');
      if(h == INVALID_HANDLE) return false;

      for(int c = 0; c < 15 && !FileIsEnding(h); c++) FileReadString(h);

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
         int t1h = (int)StringToInteger(FileReadString(h));
         int t1m = (int)StringToInteger(FileReadString(h));
         int t2h = (int)StringToInteger(FileReadString(h));
         int t2m = (int)StringToInteger(FileReadString(h));
         int t3h = (int)StringToInteger(FileReadString(h));
         int t3m = (int)StringToInteger(FileReadString(h));

         int b = MathMax(0, MathMin(NUM_BUCKETS - 1, bucketLow / 10));
         if(scope == "GLOBAL")
           {
            m_wins[b] = w;
            m_losses[b] = l;
            m_scratches[b] = s;
            m_tpHits[0][b] = t1h; m_tpMisses[0][b] = t1m;
            m_tpHits[1][b] = t2h; m_tpMisses[1][b] = t2m;
            m_tpHits[2][b] = t3h; m_tpMisses[2][b] = t3m;
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
               m_contextTpHits[0][r][f][b] = t1h; m_contextTpMisses[0][r][f][b] = t1m;
               m_contextTpHits[1][r][f][b] = t2h; m_contextTpMisses[1][r][f][b] = t2m;
               m_contextTpHits[2][r][f][b] = t3h; m_contextTpMisses[2][r][f][b] = t3m;
              }
           }
        }

      FileClose(h);
      return true;
     }
  };
#endif
//+------------------------------------------------------------------+
