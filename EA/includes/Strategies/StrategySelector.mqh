//+------------------------------------------------------------------+
//|                                  Strategies/StrategySelector.mqh  |
//+------------------------------------------------------------------+
#ifndef STRATEGYSELECTOR_MQH
#define STRATEGYSELECTOR_MQH

#include "../Core/Config.mqh"

// v2.15 addition. This is the FOURTH and LAST layer added in this
// batch — per explicit agreement to stop here and compile/test v2.12
// through v2.15 as one unit before adding anything further. Nothing
// past this point (Price Action was the last strategy module; this is
// the selection layer on top of it) is built until that happens.
//
// This is the doc's "four different questions, keep them separate"
// layer #2 (strategy-specific score, THIS ONE: strategy selection,
// trade confidence, portfolio decision). It answers exactly one
// question — "which strategy's read is strongest given the regime" —
// and answers nothing else. It does not gate a trade, does not touch
// setup.confidence, and does not run its own detection: every input it
// reads was already computed by CRegimeDetector, CMomentumBreakoutEngine,
// CMeanReversionEngine, and CKeyLevelEngine before this runs.
//
// THE WARNING THIS CLASS EXISTS TO IMPLEMENT: the spec's strongest
// warning is explicit — do not sum every strategy's score into one
// number and call the total a confidence ("SMC=+20, Momentum=+15... =
// 115, BUY" — an arbitrary confidence soup). This class never sums
// anything. It compares candidate scores and picks the single highest
// one; the loser candidates' own scores are already logged separately
// (momentum_score, reversion_score, keylevel_score all remain on
// SetupReasons untouched) so nothing is lost, but nothing is blended
// either.
//
// SELECTION RULE (deliberately simple — a genuine first cut, not the
// doc's full cross-regime free-for-all where every strategy competes
// regardless of regime): the live SMC engine's own confidence is
// always the baseline candidate, since it's the only strategy actually
// trading today. Regime determines which ONE challenger gets compared
// against it:
//   REGIME_TRENDING    -> best of (momentum_score, breakout_score)
//   REGIME_RANGING     -> reversion_score, UNLESS reversion_class ==
//                         REVERSION_TREND_CONFLICT, in which case no
//                         challenger is considered at all — this is
//                         the doc's explicit "should not fight a strong
//                         trend" rule enforced here, not just noted
//   REGIME_TRANSITION  -> keylevel_score, UNLESS keylevel_reaction ==
//                         REACTION_NONE (nothing to challenge with)
//   REGIME_UNDEFINED   -> no challenger considered; fail closed the
//                         same way every regime-dependent read in this
//                         codebase does on an unreliable regime
// The challenger only wins if it clears m_minSelectionScore AND beats
// the SMC confidence outright. If no challenger applies or none wins,
// selected_strategy = STRATEGY_SMC (or STRATEGY_NONE if SMC confidence
// itself is 0 / regime is undefined and nothing was even a candidate).
//
// DIAGNOSTIC ONLY. See the file-level note above and every prior
// v2.1x module for the same disclosure.
class CStrategySelector
  {
private:
   double            m_minSelectionScore; // a challenger must clear this AND beat SMC confidence to win (default 60.0)

public:
                     CStrategySelector() : m_minSelectionScore(60.0) {}
   // Starting point from the spec's own reasoning, not a tuned constant
   // — same discipline note as every other Configure() in this codebase.
   void              Configure(double minSelectionScore = 60.0)
     {
      m_minSelectionScore = (minSelectionScore >= 0 && minSelectionScore <= 100.0) ? minSelectionScore : 60.0;
     }

   void              Select(const SetupReasons &r, double smcConfidence,
                             ENUM_SELECTED_STRATEGY &selected, double &selectedScore);
  };
//+------------------------------------------------------------------+
void CStrategySelector::Select(const SetupReasons &r, double smcConfidence,
                               ENUM_SELECTED_STRATEGY &selected, double &selectedScore)
  {
   selected = STRATEGY_SMC;
   selectedScore = smcConfidence;

   if(r.regime == REGIME_UNDEFINED)
     {
      if(smcConfidence <= 0) selected = STRATEGY_NONE;
      return; // no challenger considered on an unreliable regime read
     }

   double challengerScore = -1.0;
   ENUM_SELECTED_STRATEGY challenger = STRATEGY_NONE;

   if(r.regime == REGIME_TRENDING)
     {
      challengerScore = MathMax(r.momentum_score, r.breakout_score);
      challenger = STRATEGY_MOMENTUM_BREAKOUT;
     }
   else if(r.regime == REGIME_RANGING)
     {
      if(r.reversion_class != REVERSION_TREND_CONFLICT)
        {
         challengerScore = r.reversion_score;
         challenger = STRATEGY_MEAN_REVERSION;
        }
     }
   else if(r.regime == REGIME_TRANSITION)
     {
      if(r.keylevel_reaction != REACTION_NONE)
        {
         challengerScore = r.keylevel_score;
         challenger = STRATEGY_KEY_LEVEL;
        }
     }

   if(challenger != STRATEGY_NONE && challengerScore >= m_minSelectionScore && challengerScore > smcConfidence)
     {
      selected = challenger;
      selectedScore = challengerScore;
     }

   if(selected == STRATEGY_SMC && smcConfidence <= 0)
      selected = STRATEGY_NONE; // nothing actually cleared as a real candidate
  }
#endif
//+------------------------------------------------------------------+
