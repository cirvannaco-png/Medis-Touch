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
   ulong             m_lastLatencyUs;   // LATENCY: wall time spent inside the most recent broker call, including any retry sleeps

   bool              LastRequestOk(string action);
   ulong             ResolvePositionTicket();
   // LATENCY: not every rejection deserves the same treatment. A requote
   // or a stale price just needs a fresh quote — sleeping the full
   // m_retryDelayMs before asking again is wasted time on something that
   // clears in milliseconds. A connection/timeout issue genuinely needs
   // the network a moment to recover. A terminal rejection (bad stops,
   // no money, trading disabled, market closed) will not change no
   // matter how many times or how fast you retry it — burning the
   // remaining attempts and their delays on it is pure latency with no
   // chance of success. Classify once, act accordingly, in both retry
   // loops below.
   bool              IsRetryable(uint retcode);
   int               DelayForRetcode(uint retcode);

public:
   void              Init(ulong magic, int maxRetries = 3, int retryDelayMs = 300);
   // LATENCY: milliseconds spent inside the most recently completed
   // MarketBuy/MarketSell/PlaceLimit call (success or final failure),
   // including every retry sleep. This is the "execution" half of
   // confirmation+execution latency — call right after any of those
   // three return, before making another broker call.
   double            LastLatencyMs() { return (double)m_lastLatencyUs / 1000.0; }
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
   m_lastLatencyUs = 0;
  }
//+------------------------------------------------------------------+
// LATENCY: unlisted/unrecognized codes default to retryable at the
// normal delay — conservative on purpose, since treating an unknown
// code as terminal risks silently giving up on something that was
// actually transient, and this list can't claim to be exhaustive across
// every broker's retcode usage.
bool CBrokerAdapter::IsRetryable(uint retcode)
  {
   switch(retcode)
     {
      // Terminal — retrying changes nothing about these.
      case TRADE_RETCODE_INVALID_STOPS:
      case TRADE_RETCODE_TRADE_DISABLED:
      case TRADE_RETCODE_MARKET_CLOSED:
      case TRADE_RETCODE_NO_MONEY:
      case TRADE_RETCODE_INVALID_EXPIRATION:
      case TRADE_RETCODE_LOCKED:
      case TRADE_RETCODE_INVALID_FILL:
      case TRADE_RETCODE_ONLY_REAL:
      case TRADE_RETCODE_LIMIT_ORDERS:
      case TRADE_RETCODE_LIMIT_VOLUME:
      case TRADE_RETCODE_INVALID_ORDER:
      case TRADE_RETCODE_LIMIT_POSITIONS:
      case TRADE_RETCODE_LONG_ONLY:
      case TRADE_RETCODE_SHORT_ONLY:
      case TRADE_RETCODE_CLOSE_ONLY:
      case TRADE_RETCODE_FIFO_CLOSE:
      case TRADE_RETCODE_HEDGE_PROHIBITED:
      case TRADE_RETCODE_SERVER_DISABLES_AT:
      case TRADE_RETCODE_CLIENT_DISABLES_AT:
         return false;
      default:
         return true;
     }
  }
//+------------------------------------------------------------------+
// LATENCY: requote/price-changed/off-quotes just need a fresh tick, not
// a network recovery window — retry almost immediately. Timeout/
// connection/too-many-requests genuinely need the full configured delay
// to have a chance of clearing.
int CBrokerAdapter::DelayForRetcode(uint retcode)
  {
   switch(retcode)
     {
      case TRADE_RETCODE_REQUOTE:
      case TRADE_RETCODE_PRICE_CHANGED:
      case TRADE_RETCODE_PRICE_OFF:
         return MathMin(m_retryDelayMs, 50);
      default:
         return m_retryDelayMs;
     }
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
   ulong t0 = GetMicrosecondCount();
   fillPriceOut = 0.0;
   for(int i = 0; i < m_maxRetries; i++)
     {
      if(m_trade.Buy(volume, symbol, 0.0, sl, tp, comment) && LastRequestOk("MarketBuy"))
        {
         ticketOut = ResolvePositionTicket();
         fillPriceOut = m_trade.ResultPrice();
         m_lastLatencyUs = GetMicrosecondCount() - t0;
         return true;
        }
      uint code = m_trade.ResultRetcode();
      if(!IsRetryable(code)) break; // LATENCY: terminal rejection — stop burning time on retries that can't succeed
      Sleep(DelayForRetcode(code));
     }
   m_lastLatencyUs = GetMicrosecondCount() - t0;
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::MarketSell(string symbol, double volume, double sl, double tp, ulong &ticketOut, double &fillPriceOut, string comment)
  {
   ulong t0 = GetMicrosecondCount();
   fillPriceOut = 0.0;
   for(int i = 0; i < m_maxRetries; i++)
     {
      if(m_trade.Sell(volume, symbol, 0.0, sl, tp, comment) && LastRequestOk("MarketSell"))
        {
         ticketOut = ResolvePositionTicket();
         fillPriceOut = m_trade.ResultPrice();
         m_lastLatencyUs = GetMicrosecondCount() - t0;
         return true;
        }
      uint code = m_trade.ResultRetcode();
      if(!IsRetryable(code)) break;
      Sleep(DelayForRetcode(code));
     }
   m_lastLatencyUs = GetMicrosecondCount() - t0;
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
   ulong t0 = GetMicrosecondCount();
   for(int i = 0; i < m_maxRetries; i++)
     {
      bool ok = (type == ORDER_TYPE_BUY_LIMIT)
                  ? m_trade.BuyLimit(volume, price, symbol, sl, tp, ORDER_TIME_GTC, 0, comment)
                  : m_trade.SellLimit(volume, price, symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
      if(ok && LastRequestOk("PlaceLimit"))
        {
         ticketOut = m_trade.ResultOrder();
         m_lastLatencyUs = GetMicrosecondCount() - t0;
         return true;
        }
      uint code = m_trade.ResultRetcode();
      if(!IsRetryable(code)) break;
      Sleep(DelayForRetcode(code));
     }
   m_lastLatencyUs = GetMicrosecondCount() - t0;
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
