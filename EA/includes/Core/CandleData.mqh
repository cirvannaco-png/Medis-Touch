//+------------------------------------------------------------------+
//|                                                Core/CandleData.mqh |
//+------------------------------------------------------------------+
#ifndef CANDLEDATA_MQH
#define CANDLEDATA_MQH

#include "Config.mqh"

class CCandleData
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_timeframe;
   int               m_maxBars;
   CandleData        m_data[];
   int               m_size;
   int               m_atrHandle;
   double            m_atrBuffer[];

   // FIX: was named CopyRates(), same name as the built-in MQL5 function
   // it calls internally — legal but a real footgun (shadowing/ambiguity).
   void              FetchRates();
   void              UpdateATR();

public:
                     CCandleData();
                    ~CCandleData();

   bool              Init(string symbol, ENUM_TIMEFRAMES tf, int maxBars = 500);
   int               Total() const { return m_size; }
   string            Symbol() const { return m_symbol; }
   ENUM_TIMEFRAMES   Timeframe() const { return m_timeframe; }
   CandleData        GetCandle(int shift) const;  // shift 0=current
   double            GetATR(int shift) const;
   bool              IsReady() const { return m_size > 0 && m_atrHandle != INVALID_HANDLE; }
   void              Refresh();                    // call each OnCalculate to keep in sync
  };
//+------------------------------------------------------------------+
CCandleData::CCandleData()
  {
   m_size = 0;
   m_maxBars = 500;
   m_atrHandle = INVALID_HANDLE;
  }
CCandleData::~CCandleData()
  {
   if(m_atrHandle != INVALID_HANDLE)
      IndicatorRelease(m_atrHandle);
  }
//+------------------------------------------------------------------+
bool CCandleData::Init(string symbol, ENUM_TIMEFRAMES tf, int maxBars)
  {
   m_symbol = symbol;
   m_timeframe = tf;
   m_maxBars = MathMax(50, maxBars);
   m_atrHandle = iATR(symbol, tf, 14);
   if(m_atrHandle == INVALID_HANDLE)
      return false;
   ArraySetAsSeries(m_data, true);
   FetchRates();
   return m_size > 0;
  }
//+------------------------------------------------------------------+
void CCandleData::FetchRates()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(m_symbol, m_timeframe, 0, m_maxBars, rates);
   if(copied <= 0)
      return;
   m_size = copied;
   ArrayResize(m_data, m_size);
   for(int i = 0; i < m_size; i++)
     {
      m_data[i].time = rates[i].time;
      m_data[i].open = rates[i].open;
      m_data[i].high = rates[i].high;
      m_data[i].low  = rates[i].low;
      m_data[i].close = rates[i].close;
      m_data[i].tick_volume = rates[i].tick_volume;
      m_data[i].atr = 0.0;
     }
   UpdateATR();
  }
//+------------------------------------------------------------------+
void CCandleData::UpdateATR()
  {
   if(m_atrHandle == INVALID_HANDLE || m_size <= 0) return;
   ArraySetAsSeries(m_atrBuffer, true);
   int copied = CopyBuffer(m_atrHandle, 0, 0, m_size, m_atrBuffer);
   if(copied <= 0) return;
   for(int i = 0; i < m_size && i < ArraySize(m_atrBuffer); i++)
      m_data[i].atr = m_atrBuffer[i];
  }
//+------------------------------------------------------------------+
CandleData CCandleData::GetCandle(int shift) const
  {
   CandleData empty;
   ZeroMemory(empty);
   if(shift < 0 || shift >= m_size) return empty;
   return m_data[shift];
  }
//+------------------------------------------------------------------+
double CCandleData::GetATR(int shift) const
  {
   if(shift < 0 || shift >= m_size) return 0.0;
   return m_data[shift].atr;
  }
//+------------------------------------------------------------------+
void CCandleData::Refresh()
  {
   // Full refresh each tick — correct for the bar counts this indicator
   // targets (default 500). If you push maxBars into the thousands,
   // switch this to an incremental append-only update.
   FetchRates();
  }
#endif
//+------------------------------------------------------------------+
