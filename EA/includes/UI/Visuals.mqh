//+------------------------------------------------------------------+
//|                                                      UI/Visuals.mqh |
//+------------------------------------------------------------------+
#ifndef VISUALS_MQH
#define VISUALS_MQH

#include "../Core/Config.mqh"
#include "../Core/ObjectManager.mqh"
#include "../Structure/BOS.mqh"
#include "../Structure/CHOCH.mqh"
#include "../SmartMoney/FVG.mqh"
#include "../SmartMoney/Liquidity.mqh"
#include "../SmartMoney/SupportResistance.mqh"
#include "../Trading/TradeZone.mqh"

// Declutter fix: the original drew EVERY detected BOS/FVG/liquidity pool/
// SR zone ever found in up to 500 bars of history, every single
// OnCalculate call, including fully mitigated/invalidated FVGs that no
// longer matter. On a live gold chart that stacks into an unreadable wall
// of overlapping rectangles and lines within minutes. Every Draw*()
// method below now takes a maxCount cap and only draws the most
// recent/most relevant objects; FVG drawing also skips terminal states.
class CVisuals
  {
private:
   CObjectManager*   m_objMan;

public:
                     CVisuals();
   void              Init(CObjectManager* objMan);
   void              DrawBOS(CBOS* bos, int maxCount = 5);
   void              DrawCHOCH(CCHOCH* choch);
   void              DrawFVG(CFVG* fvg, int maxCount = 4);
   void              DrawLiquidity(CLiquidity* liq, int maxCount = 4);
   void              DrawSR(CSupportResistance* sr, int maxCount = 4);
   void              DrawTradeSetup(TradeSetup &setup, bool filled, double fillPrice, datetime fillTime);
   void              ClearAll();
  };
//+------------------------------------------------------------------+
CVisuals::CVisuals() : m_objMan(NULL) {}
void CVisuals::Init(CObjectManager* objMan) { m_objMan = objMan; }
void CVisuals::ClearAll() { if(m_objMan != NULL) m_objMan.ClearAll(); }
//+------------------------------------------------------------------+
void CVisuals::DrawBOS(CBOS* bos, int maxCount)
  {
   if(bos == NULL || m_objMan == NULL) return;
   int n = MathMin(bos.Count(), maxCount); // GetBOS(0) = most recent, so this is a true "last N" cap
   for(int i = 0; i < n; i++)
     {
      BOSEvent ev = bos.GetBOS(i);
      string key = "BOS_" + IntegerToString(i);
      color clr = ev.is_bullish ? clrLimeGreen : clrRed;
      m_objMan.CreateTrendLine(key, ev.time, ev.price, ev.time + PeriodSeconds() * 5, ev.price, clr, 2, STYLE_DOT);
      m_objMan.CreateLabel(key + "_lbl", ev.time, ev.price, ev.label, clr, 8);
     }
  }
//+------------------------------------------------------------------+
void CVisuals::DrawCHOCH(CCHOCH* choch)
  {
   // CHoCH is already capped structurally (at most one bullish + one
   // bearish live point at a time — see CCHOCH's class comment), so no
   // extra maxCount is needed here.
   if(choch == NULL || m_objMan == NULL) return;
   for(int i = 0; i < choch.Count(); i++)
     {
      CHOCHPoint pt = choch.Get(i);
      color clr = pt.bullish ? clrDodgerBlue : clrOrange;
      m_objMan.CreateTrendLine("CH_" + IntegerToString(i), pt.time, pt.price, pt.time + PeriodSeconds() * 5, pt.price, clr, 2, STYLE_DOT);
      m_objMan.CreateLabel("CH_" + IntegerToString(i) + "_lbl", pt.time, pt.price, pt.bullish ? "CHoCH \u2191" : "CHoCH \u2193", clr, 8);
     }
  }
//+------------------------------------------------------------------+
void CVisuals::DrawFVG(CFVG* fvg, int maxCount)
  {
   if(fvg == NULL || m_objMan == NULL) return;
   int drawn = 0;
   for(int i = 0; i < fvg.Count() && drawn < maxCount; i++)
     {
      FVGZone z = fvg.GetZone(i);
      // Skip mitigated/invalidated zones entirely — they're dead weight
      // on the chart. Only fresh/tested gaps are still tradeable.
      if(z.state != FVG_FRESH && z.state != FVG_TESTED) continue;
      color clr = (z.dir == FVG_BULL) ? clrGreen : clrRed;
      string key = "FVG_" + IntegerToString(drawn);
      m_objMan.CreateRectangle(key, z.time, z.top, z.time + PeriodSeconds() * 20, z.bottom, clr, 1, true);
      drawn++;
     }
  }
//+------------------------------------------------------------------+
void CVisuals::DrawLiquidity(CLiquidity* liq, int maxCount)
  {
   if(liq == NULL || m_objMan == NULL) return;
   int n = MathMin(liq.PoolCount(), maxCount);
   for(int i = 0; i < n; i++)
     {
      LiquidityPool p = liq.GetPool(i);
      color clr = p.external ? clrYellow : clrKhaki;
      m_objMan.CreateTrendLine("Liq_" + IntegerToString(i), 0, p.price_top, PeriodSeconds() * 10, p.price_top, clr, 1, STYLE_SOLID);
     }
  }
//+------------------------------------------------------------------+
void CVisuals::DrawSR(CSupportResistance* sr, int maxCount)
  {
   if(sr == NULL || m_objMan == NULL) return;
   // GetZone(i) is already sorted strongest-first, so this cap naturally
   // keeps the most meaningful zones and drops long-tail single-touch noise.
   int n = MathMin(sr.Count(), maxCount);
   for(int i = 0; i < n; i++)
     {
      SRZone z = sr.GetZone(i);
      bool isSupport = (z.type == SR_MAJOR_SUPPORT || z.type == SR_MINOR_SUPPORT);
      color clr = isSupport ? clrDodgerBlue : clrMediumOrchid;
      m_objMan.CreateRectangle("SR_" + IntegerToString(i), z.startTime, z.top, z.startTime + PeriodSeconds() * 20, z.bottom, clr, 1, true);
     }
  }
//+------------------------------------------------------------------+
// filled/fillPrice/fillTime come from COutcomeTracker::GetFillState() for
// this exact setup (matched by creation_time). When outcome tracking is
// off, or the tracker just hasn't seen this bar yet, filled defaults to
// false and the zone simply renders as pending — which is still accurate,
// just slightly behind by at most one OnCalculate call.
//
// Trade zone: hollow/dashed while pending (order working, not yet
// touched), solid-filled once price actually trades into it. The zone's
// right edge is pinned to fillTime once filled, instead of trailing
// "now" forever, so the rectangle marks the real window the order sat
// there rather than growing indefinitely.
// Trade arrow: only drawn once fill is confirmed, anchored at the actual
// fill bar/price — not at "now" — so it doesn't visually slide forward
// on every tick before a fill has even happened.
void CVisuals::DrawTradeSetup(TradeSetup &setup, bool filled, double fillPrice, datetime fillTime)
  {
   if(m_objMan == NULL || !setup.active) return;
   datetime now = TimeCurrent();
   bool isBuy = (setup.type == ORDER_TYPE_BUY);
   color zoneClr = isBuy ? clrLimeGreen : clrRed;

   datetime zoneRight = filled ? fillTime : now;
   if(zoneRight <= setup.creation_time)
      zoneRight = setup.creation_time + PeriodSeconds();

   m_objMan.CreateRectangle("TradeZone", setup.creation_time, setup.entry_top, zoneRight, setup.entry_bottom,
                             zoneClr, 1, filled, filled ? STYLE_SOLID : STYLE_DASH);
   m_objMan.CreateLabel("TradeZoneLbl", setup.creation_time, setup.entry_top,
                         filled ? StringFormat("FILLED @ %s", DoubleToString(fillPrice, _Digits)) : "PENDING",
                         zoneClr, 8);

   if(filled)
     {
      if(isBuy)
         m_objMan.CreateArrow("BuyArrow", fillTime, fillPrice, 241, clrLimeGreen, 3);
      else
         m_objMan.CreateArrow("SellArrow", fillTime, fillPrice, 242, clrRed, 3);
     }

   m_objMan.CreateTrendLine("SL", now, setup.stop_loss, now + PeriodSeconds() * 5, setup.stop_loss, clrCrimson, 2, STYLE_DOT);
   m_objMan.CreateTrendLine("TP1", now, setup.tp1, now + PeriodSeconds() * 5, setup.tp1, clrGold, 2, STYLE_DOT);
  }
#endif
//+------------------------------------------------------------------+
