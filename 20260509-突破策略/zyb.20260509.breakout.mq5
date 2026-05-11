//+------------------------------------------------------------------+
//| 均线突破策略 EA — 逻辑见同目录 README.md                           |
//| MA(默认14) 突破收盘确认；独立持仓；SL/TP；移动止损=开仓价百分比间距。  |
//+------------------------------------------------------------------+
#property copyright "zyb-ea"
#property version   "2.20"
#property description "MA突破：SL=突破K极值；TP=盈亏比；移动止损=开仓价×百分比间距。"

#include <Trade/Trade.mqh>

CTrade g_trade;

int g_hMa = INVALID_HANDLE;
static datetime g_lastWorkBar = 0;

//------------------------------------------------------------
input group "工作区"
input ENUM_TIMEFRAMES InpWorkTF = PERIOD_M1;   // K 线周期（默认 1 分钟）
input int             InpSlippage  = 30;       // 滑点（点）
input int             InpMaxSpreadPoints = 0; // 最大点差（点，0=不限制）
input long            InpMagic     = 20260509; // Magic 识别码

input group "移动平均线"
input int                InpMAPeriod = 14;            // MA 周期
input int                InpMAShift  = 0;           // MA 位移
input ENUM_MA_METHOD     InpMAMethod = MODE_SMA;    // MA 算法
input ENUM_APPLIED_PRICE InpMAPrice  = PRICE_CLOSE; // 应用于

input group "下单"
input double InpLot = 0.01; // 基准开仓手数（复利关闭时即为实际手数）

input group "止盈（盈亏比）"
input double InpRewardRiskRatio = 2.0; // 盈亏比：止盈距离 = 入场相对止损的风险宽度 × 本值（≤0 表示不设止盈）

input group "移动止损"
input double InpTrailPercentOfOpen = 0.0; // 跟踪间距 = 开仓价 × 本%/100（0=关闭）；多：SL=BID−间距；空：SL=ASK+间距

input group "复利"
input bool   InpUseCompound = false; // 开启后按账户净值相对参考净值缩放手数
input double InpCompoundRefEquity = 10000.0; // 参考净值：实际手数 ≈ InpLot × (当前净值 / 参考净值)

input group "其它"
input bool InpLog = true; // 是否打印日志

//------------------------------------------------------------
double MinLot()  { return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN); }
double MaxLot()  { return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX); }
double LotStep() { return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP); }

double NormalizeVolumeVal(const double v)
{
   const double lo = MinLot();
   const double hi = MaxLot();
   const double st = LotStep();
   if(st <= 0.0 || hi < lo)
      return v;
   if(v < lo - 1e-12)
      return 0.0;
   double x = MathMin(v, hi);
   x = MathFloor(x / st + 1e-12) * st;
   return x;
}

double CalcOrderLot()
{
   double lot = InpLot;
   if(InpUseCompound && InpCompoundRefEquity > 1e-8)
   {
      const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      lot = InpLot * (eq / InpCompoundRefEquity);
   }
   return NormalizeVolumeVal(lot);
}

int SpreadPoints()
{
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
}

double StopsMinDistancePrice()
{
   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const int st = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int fr = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)(st + fr) * pt;
}

// 市价多单：SL 须在 Bid 下方且满足最小止损距离
bool IsBuyStopLossValid(const double sl)
{
   if(sl <= 0.0)
      return false;
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double need = StopsMinDistancePrice();
   const double slN = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   if(slN >= bid - need)
      return false;
   return true;
}

// 市价空单：SL 须在 Ask 上方且满足最小止损距离
bool IsSellStopLossValid(const double sl)
{
   if(sl <= 0.0)
      return false;
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double need = StopsMinDistancePrice();
   const double slN = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   if(slN <= ask + need)
      return false;
   return true;
}

// 多单止盈须在 Ask 上方且满足最小距离
bool IsBuyTakeProfitValid(const double tp)
{
   if(tp <= 0.0)
      return false;
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double need = StopsMinDistancePrice();
   if(tp <= ask + need)
      return false;
   return true;
}

// 空单止盈须在 Bid 下方且满足最小距离
bool IsSellTakeProfitValid(const double tp)
{
   if(tp <= 0.0)
      return false;
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double need = StopsMinDistancePrice();
   if(tp >= bid - need)
      return false;
   return true;
}

// 风险宽 = |入场(Ask) − SL|；TP = Ask + 风险×RR
bool CalcBuyTpByRewardRisk(const double sl, double &tp)
{
   tp = 0.0;
   if(InpRewardRiskRatio <= 0.0)
      return true;
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double risk = ask - sl;
   if(risk <= 1e-12)
      return false;
   const int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   tp = NormalizeDouble(ask + risk * InpRewardRiskRatio, dg);
   return IsBuyTakeProfitValid(tp);
}

// 风险宽 = SL − Ask；TP = Ask − 风险×RR
bool CalcSellTpByRewardRisk(const double sl, double &tp)
{
   tp = 0.0;
   if(InpRewardRiskRatio <= 0.0)
      return true;
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double risk = sl - ask;
   if(risk <= 1e-12)
      return false;
   const int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   tp = NormalizeDouble(ask - risk * InpRewardRiskRatio, dg);
   return IsSellTakeProfitValid(tp);
}

/// 按开仓价百分比为间距跟踪止损（仅收紧：上移多单 SL、下移空单 SL）
void TryTrailingStopByOpenPercent()
{
   if(InpTrailPercentOfOpen <= 0.0)
      return;

   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((uint)InpSlippage);

   const int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double need = StopsMinDistancePrice();
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   for(int i = (int)PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      const double openPx = PositionGetDouble(POSITION_PRICE_OPEN);
      const double trailDist = openPx * (InpTrailPercentOfOpen / 100.0);
      if(trailDist <= 1e-12)
         continue;

      const double slOld = PositionGetDouble(POSITION_SL);
      const double tpOld = PositionGetDouble(POSITION_TP);
      const long typ = (long)PositionGetInteger(POSITION_TYPE);

      if(slOld <= 0.0)
         continue;

      if(typ == POSITION_TYPE_BUY)
      {
         double newSL = NormalizeDouble(bid - trailDist, dg);
         if(newSL <= slOld + pt * 0.5)
            continue;
         if(newSL >= bid - need)
            continue;
         if(tpOld > 0.0 && newSL >= tpOld)
            continue;
         if(!g_trade.PositionModify(ticket, newSL, tpOld))
         {
            if(InpLog)
               Print("移动止损(多)失败 ticket=", ticket, " err=", GetLastError(),
                     " newSL=", newSL, " oldSL=", slOld);
         }
      }
      else if(typ == POSITION_TYPE_SELL)
      {
         double newSL = NormalizeDouble(ask + trailDist, dg);
         if(newSL >= slOld - pt * 0.5)
            continue;
         if(newSL <= ask + need)
            continue;
         if(tpOld > 0.0 && newSL <= tpOld)
            continue;
         if(!g_trade.PositionModify(ticket, newSL, tpOld))
         {
            if(InpLog)
               Print("移动止损(空)失败 ticket=", ticket, " err=", GetLastError(),
                     " newSL=", newSL, " oldSL=", slOld);
         }
      }
   }
}

//------------------------------------------------------------
bool CopyBar1OHLCMA(double &o1, double &c1, double &l1, double &h1, double &ma1)
{
   double o[], c[], l[], h[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(c, true);
   ArraySetAsSeries(l, true);
   ArraySetAsSeries(h, true);
   if(CopyOpen(_Symbol, InpWorkTF, 1, 1, o) != 1)
      return false;
   if(CopyHigh(_Symbol, InpWorkTF, 1, 1, h) != 1)
      return false;
   if(CopyLow(_Symbol, InpWorkTF, 1, 1, l) != 1)
      return false;
   if(CopyClose(_Symbol, InpWorkTF, 1, 1, c) != 1)
      return false;
   double m[];
   ArraySetAsSeries(m, true);
   if(CopyBuffer(g_hMa, 0, 1, 1, m) != 1)
      return false;
   o1 = o[0];
   c1 = c[0];
   l1 = l[0];
   h1 = h[0];
   ma1 = m[0];
   return true;
}

/// 新 K 线开盘：上一根已收盘 K 为突破 K；每单独立，带 SL / 可选 RR 止盈
void OnNewClosedBar()
{
   if(g_hMa == INVALID_HANDLE)
      return;

   double o1 = 0.0, c1 = 0.0, l1 = 0.0, h1 = 0.0, ma1 = 0.0;
   if(!CopyBar1OHLCMA(o1, c1, l1, h1, ma1))
      return;

   const bool longBreak  = (o1 < ma1 && c1 > ma1);
   const bool shortBreak = (o1 > ma1 && c1 < ma1);

   if(!longBreak && !shortBreak)
      return;

   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((uint)InpSlippage);

   const double vol = CalcOrderLot();
   if(vol < MinLot() - 1e-12)
   {
      if(InpLog)
         Print("手数过小，跳过开仓");
      return;
   }

   const int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(longBreak)
   {
      double sl = NormalizeDouble(l1, dg);
      if(!IsBuyStopLossValid(sl))
      {
         if(InpLog)
            Print("多单突破: 止损价不满足券商最小距离或无效，跳过 SL=", sl,
                  " Bid=", SymbolInfoDouble(_Symbol, SYMBOL_BID),
                  " 突破K最低=", l1);
         return;
      }
      double tp = 0.0;
      if(InpRewardRiskRatio > 0.0)
      {
         if(!CalcBuyTpByRewardRisk(sl, tp))
         {
            if(InpLog)
               Print("多单突破: 止盈(盈亏比 ", InpRewardRiskRatio, ") 无效或距离不足，跳过");
            return;
         }
      }
      const string cmt = "突破-多";
      if(!g_trade.Buy(vol, _Symbol, 0.0, sl, tp, cmt))
      {
         if(InpLog)
            Print("开多单失败 err=", GetLastError(), " SL=", sl, " TP=", tp);
      }
      else if(InpLog)
         Print("多单突破 独立开仓 手数=", vol, " SL=", sl, " TP=", tp,
               " RR=", InpRewardRiskRatio,
               " O=", o1, " C=", c1, " MA=", ma1);
   }
   else if(shortBreak)
   {
      double sl = NormalizeDouble(h1, dg);
      if(!IsSellStopLossValid(sl))
      {
         if(InpLog)
            Print("空单突破: 止损价不满足券商最小距离或无效，跳过 SL=", sl,
                  " Ask=", SymbolInfoDouble(_Symbol, SYMBOL_ASK),
                  " 突破K最高=", h1);
         return;
      }
      double tp = 0.0;
      if(InpRewardRiskRatio > 0.0)
      {
         if(!CalcSellTpByRewardRisk(sl, tp))
         {
            if(InpLog)
               Print("空单突破: 止盈(盈亏比 ", InpRewardRiskRatio, ") 无效或距离不足，跳过");
            return;
         }
      }
      const string cmt = "突破-空";
      if(!g_trade.Sell(vol, _Symbol, 0.0, sl, tp, cmt))
      {
         if(InpLog)
            Print("开空单失败 err=", GetLastError(), " SL=", sl, " TP=", tp);
      }
      else if(InpLog)
         Print("空单突破 独立开仓 手数=", vol, " SL=", sl, " TP=", tp,
               " RR=", InpRewardRiskRatio,
               " O=", o1, " C=", c1, " MA=", ma1);
   }
}

//------------------------------------------------------------
int OnInit()
{
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((uint)InpSlippage);
   const int filling = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);

   g_hMa = iMA(_Symbol, InpWorkTF, InpMAPeriod, InpMAShift, InpMAMethod, InpMAPrice);
   if(g_hMa == INVALID_HANDLE)
   {
      Print("初始化 MA 句柄失败");
      return INIT_FAILED;
   }
   g_lastWorkBar = 0;
   if(InpLog)
      Print("均线突破 EA v2.2: ", _Symbol,
            " 周期=", EnumToString(InpWorkTF),
            " MA=", InpMAPeriod,
            " 基准手数=", InpLot,
            " 盈亏比RR=", InpRewardRiskRatio,
            " 移动止损%=", InpTrailPercentOfOpen,
            " 复利=", (InpUseCompound ? "开" : "关"),
            (InpUseCompound ? StringFormat(" 参考净值=%.2f 当前手数≈%.4f", InpCompoundRefEquity, CalcOrderLot()) : ""),
            " 独立持仓 SL=突破K TP=风险×RR");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_hMa != INVALID_HANDLE)
   {
      IndicatorRelease(g_hMa);
      g_hMa = INVALID_HANDLE;
   }
}

void OnTick()
{
   if(InpMaxSpreadPoints > 0 && SpreadPoints() > InpMaxSpreadPoints)
      return;

   TryTrailingStopByOpenPercent();

   const datetime bar0 = iTime(_Symbol, InpWorkTF, 0);
   if(bar0 != 0 && bar0 != g_lastWorkBar)
   {
      g_lastWorkBar = bar0;
      OnNewClosedBar();
   }
}

//+------------------------------------------------------------------+
