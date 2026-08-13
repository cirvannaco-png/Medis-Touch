//+------------------------------------------------------------------+
//|                                       Execution/BrokerAdapter.mqh |
//+------------------------------------------------------------------+
#ifndef BROKERADAPTER_MQH
#define BROKERADAPTER_MQH

#include <Trade\Trade.mqh>

// Thin wrapper around the standard CTrade class. OrderManager and
// PositionManager never touch the trade API directly — everything routes
// through here, which centralizes retry/error logging and gives one seam
// to swap execution backends later (e.g. a copier API) without touching
// the rest of Execution.
//
// FIXED: market fills used to hand back CTrade::ResultOrder() (the order
// ticket) as the position ticket. That happens to work on a netting
// account, where MT5 keeps one position per symbol, but it is not
// guaranteed to equal the position ticket in general and breaks outright
// on a hedging account with multiple concurrent positions on the same
// symbol. Every deal MT5 executes records which position it belongs to
// (DEAL_POSITION_ID), and that ID is exactly what
// PositionSelectByTicket()/POSITION_TICKET expect — on both account
// modes. MarketBuy/MarketSell now resolve the real position ticket via
// the deal, with the old order-ticket behavior kept only as a logged
// fallback if history lookup ever fails.
class CBrokerAdapter
  {
private:
   CTrade            m_trade;
   int               m_maxRetries;
   int               m_retryDelayMs;

   bool              LastRequestOk(string action);
   ulong             ResolvePositionTicket();

public:
   void              Init(ulong magic, int maxRetries = 3, int retryDelayMs = 300);
   // FIX (audit #25): fillPriceOut returns the REAL price CTrade filled at
   // (ResultPrice()), not the theoretical FVG-edge entry the signal was
   // built around. Market execution uses price=0.0 (fill at whatever the
   // market gives), so the two can differ. Everything downstream that
   // assumed "filled at the decision's entry price" (break-even trigger,
   // R-multiple, partial-close trigger) needs this real number instead.
   bool              MarketBuy(string symbol, double volume, double sl, double tp, ulong &ticketOut, double &fillPriceOut, string comment = "");
   bool              MarketSell(string symbol, double volume, double sl, double tp, ulong &ticketOut, double &fillPriceOut, string comment = "");
   bool              PlaceLimit(string symbol, ENUM_ORDER_TYPE type, double volume, double price,
                                double sl, double tp, ulong &ticketOut, string comment = "");
   bool              CancelOrder(ulong ticket);
   bool              ModifySLTP(ulong ticket, double sl, double tp);
   bool              ClosePartial(ulong ticket, double volume);
   bool              CloseFull(ulong ticket);
  };
//+------------------------------------------------------------------+
void CBrokerAdapter::Init(ulong magic, int maxRetries, int retryDelayMs)
  {
   m_trade.SetExpertMagicNumber(magic);
   m_trade.SetDeviationInPoints(20);
   m_trade.SetTypeFillingBySymbol(_Symbol);
   m_maxRetries = maxRetries;
   m_retryDelayMs = retryDelayMs;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::LastRequestOk(string action)
  {
   uint code = m_trade.ResultRetcode();
   if(code == TRADE_RETCODE_DONE || code == TRADE_RETCODE_PLACED)
      return true;
   PrintFormat("MedisTouch BrokerAdapter: %s failed, retcode=%d (%s)",
               action, code, m_trade.ResultRetcodeDescription());
   return false;
  }
//+------------------------------------------------------------------+
ulong CBrokerAdapter::ResolvePositionTicket()
  {
   ulong dealTicket = m_trade.ResultDeal();
   if(dealTicket == 0)
     {
      Print("MedisTouch BrokerAdapter: fill had no deal ticket in the trade result, ",
            "falling back to order ticket — verify this position manually.");
      return m_trade.ResultOrder();
     }
   if(!HistoryDealSelect(dealTicket))
     {
      // FIX: this was two separate string-literal arguments after the
      // format string, with only one %d specifier to consume them and
      // dealTicket left as a trailing unmatched argument — a malformed
      // PrintFormat call, not a working one. Concatenated into a single
      // format string with its one real argument.
      PrintFormat("MedisTouch BrokerAdapter: could not select deal #%d from history, falling back to order ticket — verify this position manually.",
                  dealTicket);
      return m_trade.ResultOrder();
     }
   ulong positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   if(positionId == 0)
     {
      // FIX: same malformed-call shape as above.
      PrintFormat("MedisTouch BrokerAdapter: deal #%d carried no DEAL_POSITION_ID, falling back to order ticket — verify this position manually.",
                  dealTicket);
      return m_trade.ResultOrder();
     }
   return positionId;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::MarketBuy(string symbol, double volume, double sl, double tp, ulong &ticketOut, double &fillPriceOut, string comment)
  {
   fillPriceOut = 0.0;
   for(int i = 0; i < m_maxRetries; i++)
     {
      if(m_trade.Buy(volume, symbol, 0.0, sl, tp, comment) && LastRequestOk("MarketBuy"))
        {
         ticketOut = ResolvePositionTicket();
         fillPriceOut = m_trade.ResultPrice();
         return true;
        }
      Sleep(m_retryDelayMs);
     }
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::MarketSell(string symbol, double volume, double sl, double tp, ulong &ticketOut, double &fillPriceOut, string comment)
  {
   fillPriceOut = 0.0;
   for(int i = 0; i < m_maxRetries; i++)
     {
      if(m_trade.Sell(volume, symbol, 0.0, sl, tp, comment) && LastRequestOk("MarketSell"))
        {
         ticketOut = ResolvePositionTicket();
         fillPriceOut = m_trade.ResultPrice();
         return true;
        }
      Sleep(m_retryDelayMs);
     }
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::PlaceLimit(string symbol, ENUM_ORDER_TYPE type, double volume, double price,
                                double sl, double tp, ulong &ticketOut, string comment)
  {
   if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT)
     {
      Print("MedisTouch BrokerAdapter: PlaceLimit called with a non-limit order type");
      return false;
     }
   for(int i = 0; i < m_maxRetries; i++)
     {
      bool ok = (type == ORDER_TYPE_BUY_LIMIT)
                  ? m_trade.BuyLimit(volume, price, symbol, sl, tp, ORDER_TIME_GTC, 0, comment)
                  : m_trade.SellLimit(volume, price, symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
      if(ok && LastRequestOk("PlaceLimit"))
        {
         ticketOut = m_trade.ResultOrder();
         return true;
        }
      Sleep(m_retryDelayMs);
     }
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::CancelOrder(ulong ticket)
  {
   if(m_trade.OrderDelete(ticket)) return true;
   LastRequestOk("CancelOrder");
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::ModifySLTP(ulong ticket, double sl, double tp)
  {
   if(m_trade.PositionModify(ticket, sl, tp)) return true;
   LastRequestOk("ModifySLTP");
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::ClosePartial(ulong ticket, double volume)
  {
   if(m_trade.PositionClosePartial(ticket, volume)) return true;
   LastRequestOk("ClosePartial");
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::CloseFull(ulong ticket)
  {
   if(m_trade.PositionClose(ticket)) return true;
   LastRequestOk("CloseFull");
   return false;
  }
#endif
//+------------------------------------------------------------------+
