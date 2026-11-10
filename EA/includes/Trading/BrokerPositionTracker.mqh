//+------------------------------------------------------------------+
//|                             Trading/BrokerPositionTracker.mqh    |
//| Tracks real bid/ask excursions for broker-confirmed MT5 positions.|
//+------------------------------------------------------------------+
#ifndef BROKERPOSITIONTRACKER_MQH
#define BROKERPOSITIONTRACKER_MQH

struct BrokerPositionExcursion
  {
   ulong  position_id;
   bool   is_buy;
   long   decision_id;
   double entry_price;
   double initial_stop_loss;
   double initial_risk_distance;
   double mfe_price;
   double mae_price;
   double mfe_r;
   double mae_r;
  };

class CBrokerPositionTracker
  {
private:
   string                 m_symbol;
   ulong                  m_magic;
   BrokerPositionExcursion m_items[];

   int Find(ulong positionId)
     {
      for(int i=0; i<ArraySize(m_items); i++)
         if(m_items[i].position_id == positionId) return i;
      return -1;
     }

   string Key(ulong positionId, string suffix)
     {
      return "MTX_" + StringFormat("%I64u", positionId) + "_" + suffix;
     }

   double Stored(ulong positionId, string suffix, double fallback)
     {
      string key = Key(positionId, suffix);
      if(!GlobalVariableCheck(key)) return fallback;
      return GlobalVariableGet(key);
     }

   void Persist(int idx)
     {
      ulong id = m_items[idx].position_id;
      GlobalVariableSet(Key(id, "E"), m_items[idx].entry_price);
      GlobalVariableSet(Key(id, "S"), m_items[idx].initial_stop_loss);
      GlobalVariableSet(Key(id, "R"), m_items[idx].initial_risk_distance);
      GlobalVariableSet(Key(id, "MFE"), m_items[idx].mfe_price);
      GlobalVariableSet(Key(id, "MAE"), m_items[idx].mae_price);
      GlobalVariableSet(Key(id, "D"), (double)m_items[idx].decision_id);
      GlobalVariableSet(Key(id, "B"), m_items[idx].is_buy ? 1.0 : 0.0);
      if(m_items[idx].initial_risk_distance > 0.0)
        {
         m_items[idx].mfe_r = MathMax(0.0, m_items[idx].is_buy
                                      ? (m_items[idx].mfe_price-m_items[idx].entry_price)/m_items[idx].initial_risk_distance
                                      : (m_items[idx].entry_price-m_items[idx].mfe_price)/m_items[idx].initial_risk_distance);
         m_items[idx].mae_r = MathMax(0.0, m_items[idx].is_buy
                                      ? (m_items[idx].entry_price-m_items[idx].mae_price)/m_items[idx].initial_risk_distance
                                      : (m_items[idx].mae_price-m_items[idx].entry_price)/m_items[idx].initial_risk_distance);
         GlobalVariableSet(Key(id, "MFER"), m_items[idx].mfe_r);
         GlobalVariableSet(Key(id, "MAER"), m_items[idx].mae_r);
        }
     }

   void Restore(int idx, ulong positionId, bool isBuy, double entryPrice)
     {
      m_items[idx].position_id = positionId;
      m_items[idx].is_buy = isBuy;
      m_items[idx].entry_price = Stored(positionId, "E", entryPrice);
      m_items[idx].initial_stop_loss = Stored(positionId, "S", 0.0);
      m_items[idx].initial_risk_distance = Stored(positionId, "R", 0.0);
      m_items[idx].mfe_price = Stored(positionId, "MFE", m_items[idx].entry_price);
      m_items[idx].mae_price = Stored(positionId, "MAE", m_items[idx].entry_price);
      m_items[idx].decision_id = (long)Stored(positionId, "D", 0.0);
      m_items[idx].mfe_r = Stored(positionId, "MFER", 0.0);
      m_items[idx].mae_r = Stored(positionId, "MAER", 0.0);
     }

public:
   void Init(string symbol, ulong magic)
     {
      m_symbol = symbol;
      m_magic = magic;
      ArrayResize(m_items, 0);
     }

   // Called once from OnTradeTransaction for the opening deal. The
   // original stop and decision ID are persisted before any trailing or
   // break-even manager can modify the live broker stop.
   void RegisterOpen(ulong positionId, bool isBuy, double entryPrice,
                     double initialStopLoss, long decisionId)
     {
      if(positionId == 0 || entryPrice <= 0.0) return;
      int idx = Find(positionId);
      if(idx < 0)
        {
         idx = ArraySize(m_items);
         ArrayResize(m_items, idx+1);
         Restore(idx, positionId, isBuy, entryPrice);
        }
      m_items[idx].is_buy = isBuy;
      m_items[idx].entry_price = entryPrice;
      if(initialStopLoss > 0.0 && m_items[idx].initial_risk_distance <= 0.0)
        {
         m_items[idx].initial_stop_loss = initialStopLoss;
         m_items[idx].initial_risk_distance = MathAbs(entryPrice-initialStopLoss);
        }
      if(decisionId > 0) m_items[idx].decision_id = decisionId;
      Persist(idx);
     }

   // Called before PositionManager on every tick. Long excursions use bid
   // (the executable exit side); short excursions use ask.
   void Update()
     {
      MqlTick tick;
      if(!SymbolInfoTick(m_symbol, tick)) return;
      bool changed = false;

      for(int i=0; i<PositionsTotal(); i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol) continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != m_magic) continue;

         ulong positionId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
         if(positionId == 0) continue;
         bool isBuy = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
         double entry = PositionGetDouble(POSITION_PRICE_OPEN);

         int idx = Find(positionId);
         if(idx < 0)
           {
            idx = ArraySize(m_items);
            ArrayResize(m_items, idx+1);
            Restore(idx, positionId, isBuy, entry);
           }

         double exitQuote = isBuy ? tick.bid : tick.ask;
         bool itemChanged = false;
         if(isBuy)
           {
            if(exitQuote > m_items[idx].mfe_price) { m_items[idx].mfe_price = exitQuote; itemChanged = true; }
            if(exitQuote < m_items[idx].mae_price) { m_items[idx].mae_price = exitQuote; itemChanged = true; }
           }
         else
           {
            if(exitQuote < m_items[idx].mfe_price) { m_items[idx].mfe_price = exitQuote; itemChanged = true; }
            if(exitQuote > m_items[idx].mae_price) { m_items[idx].mae_price = exitQuote; itemChanged = true; }
           }
         if(itemChanged)
           {
            Persist(idx);
            changed = true;
           }
        }

      // Flush persistent terminal variables at most once per second.
      // This avoids an expensive disk flush for every quote while keeping
      // restart recovery bounded to a short interval.
      static ulong lastFlush = 0;
      ulong nowMs = GetTickCount64();
      if(changed && (lastFlush == 0 || nowMs-lastFlush >= 1000))
        {
         GlobalVariablesFlush();
         lastFlush = nowMs;
        }
     }

   bool PositionIsOpen(ulong positionId)
     {
      for(int i=0; i<PositionsTotal(); i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if((ulong)PositionGetInteger(POSITION_IDENTIFIER) != positionId) continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol) continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != m_magic) continue;
         return true;
        }
      return false;
     }

   bool Snapshot(ulong positionId, double &entryPrice, double &initialStopLoss,
                 double &initialRiskDistance, double &mfePrice, double &maePrice,
                 double &mfeR, double &maeR, long &decisionId, bool &isBuy)
     {
      int idx = Find(positionId);
      if(idx >= 0)
        {
         entryPrice = m_items[idx].entry_price;
         initialStopLoss = m_items[idx].initial_stop_loss;
         initialRiskDistance = m_items[idx].initial_risk_distance;
         mfePrice = m_items[idx].mfe_price;
         maePrice = m_items[idx].mae_price;
         mfeR = m_items[idx].mfe_r;
         maeR = m_items[idx].mae_r;
         decisionId = m_items[idx].decision_id;
         isBuy = m_items[idx].is_buy;
         return true;
        }

      if(!GlobalVariableCheck(Key(positionId, "E"))) return false;
      entryPrice = Stored(positionId, "E", 0.0);
      initialStopLoss = Stored(positionId, "S", 0.0);
      initialRiskDistance = Stored(positionId, "R", 0.0);
      mfePrice = Stored(positionId, "MFE", entryPrice);
      maePrice = Stored(positionId, "MAE", entryPrice);
      mfeR = Stored(positionId, "MFER", 0.0);
      maeR = Stored(positionId, "MAER", 0.0);
      decisionId = (long)Stored(positionId, "D", 0.0);
      isBuy = (Stored(positionId, "B", 1.0) > 0.5);
      return true;
     }

   void Remove(ulong positionId)
     {
      GlobalVariableDel(Key(positionId, "E"));
      GlobalVariableDel(Key(positionId, "S"));
      GlobalVariableDel(Key(positionId, "R"));
      GlobalVariableDel(Key(positionId, "MFE"));
      GlobalVariableDel(Key(positionId, "MAE"));
      GlobalVariableDel(Key(positionId, "D"));
      GlobalVariableDel(Key(positionId, "B"));
      GlobalVariableDel(Key(positionId, "MFER"));
      GlobalVariableDel(Key(positionId, "MAER"));

      int idx = Find(positionId);
      if(idx < 0) return;
      for(int i=idx; i<ArraySize(m_items)-1; i++)
         m_items[i] = m_items[i+1];
      ArrayResize(m_items, ArraySize(m_items)-1);
     }
  };

#endif
//+------------------------------------------------------------------+
