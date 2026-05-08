//+------------------------------------------------------------------+
//| 马丁网格策略 EA — 逻辑见同目录 README.md                           |
//| 需对冲账户（同一方向可多笔持仓）；日志与参数说明为中文。              |
//+------------------------------------------------------------------+
#property copyright "zyb-ea"
#property version   "1.00"
#property description "马丁网格：MA 突破首单 + 首单价比例间距补仓 + 档间隔每组+#加仓放大手数 + 统盈；可选复利仅首单。"

#include <Trade/Trade.mqh>

CTrade g_trade;

int g_hMa = INVALID_HANDLE;

//------------------------------------------------------------
input group "工作区"
input ENUM_TIMEFRAMES InpWorkTF = PERIOD_M1;   // 工作周期（K 线：突破判定、新 K 检测；默认 1 分钟）
input int             InpSlippage  = 30;       // 滑点（点）
input int             InpMaxSpreadPoints = 0; // 最大点差（点，0=不限制）
input long            InpMagic     = 20260507; // Magic 识别码

input group "移动平均线"
input int                InpMAPeriod = 20;                    // MA 周期
input int                InpMAShift  = 0;                     // MA 位移
input ENUM_MA_METHOD     InpMAMethod = MODE_SMA;              // MA 算法
input ENUM_APPLIED_PRICE InpMAPrice  = PRICE_CLOSE;           // 应用于

input group "头寸与补仓"
input double InpFirstLot       = 0.01;  // 首单手数（复利关闭时为固定手数）
input double InpStepPercent    = 2.0;   // 补仓比例(%)：每档价距 = 首单开仓价 × 本参数%（相对上一同向开仓反向计数）
input double InpAddLotBoost    = 0.05; // 加仓放大手数：每新一组在上一组手数上 + 本参数（组内 N 档相同；首组=首单）
input int    InpTierInterval   = 5;     // 档间隔 N：每 N 个网格档为一组，组满后下一组手数 + 加仓放大手数
input int    InpMaxLayers      = 50;    // 单向最大档数（含首单，安全上限）

input group "统盈平仓"
input double InpTpPercent = 10.0; // 止盈比例(%)：多单目标 = 加权成本 × (1+本%)；空单反之

input group "补充逻辑（满档浮盈）"
input double InpMaxLayersFloatPct = 0.0; // 浮盈比例(%，相对账户结余)：该向已达「单向最大档」时，若该向浮盈(含库存费)≥结余×本%/100 则平掉该向全仓；0=关闭

input group "复利（仅首单）"
input bool   InpUseCompound     = false; // 开启后只按比例放大「首单」手数；加仓档仍用本节基准手数递推
input double InpCompoundRefEquity = 10000.0; // 参考净值：首单手数 ≈ InpFirstLot × (当前净值 / 参考净值)

input group "其它"
input bool InpLog = true; // 是否打印日志

//------------------------------------------------------------
double         g_longBaseLot  = 0.0;  // 本轮回多单首单基准手数（加仓按此递推）
double         g_shortBaseLot = 0.0;
static datetime g_lastWorkBar = 0;

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

int SpreadPoints()
{
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
}

//------------------------------------------------------------
// 复利仅影响首单：返回本轮「基准手数」，加仓用 LotForTier(..., 此基准)
double CalcBasketBaseLot()
{
   double lot = InpFirstLot;
   if(InpUseCompound && InpCompoundRefEquity > 1e-8)
   {
      const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      lot = InpFirstLot * (eq / InpCompoundRefEquity);
   }
   return NormalizeVolumeVal(lot);
}

// tierIndex：0=首单，1=第 2 笔 …；grp=tierIndex/N 为组号，组内手数相同，每组手数=首单基准+grp×加仓放大手数
double LotForTier(const int tierIndex, const double basketBaseLot)
{
   if(tierIndex < 0 || basketBaseLot <= 0.0)
      return 0.0;
   const int n = MathMax(1, InpTierInterval);
   const int grp = tierIndex / n;
   if(InpAddLotBoost <= 0.0)
      return NormalizeVolumeVal(basketBaseLot);
   double vol = basketBaseLot + (double)grp * InpAddLotBoost;
   vol = MathMin(vol, MaxLot());
   return NormalizeVolumeVal(vol);
}

//------------------------------------------------------------
int CountPositions(const long typeFilter) // POSITION_TYPE_BUY / SELL，-1 表示不限方向但同 magic 同品种
{
   int c = 0;
   const int total = (int)PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      const long typ = (long)PositionGetInteger(POSITION_TYPE);
      if(typeFilter >= 0 && typ != typeFilter)
         continue;
      c++;
   }
   return c;
}

bool GetBasketEdges(const long posType, double &firstOpen, double &lastOpen, datetime &firstTime, datetime &lastTime)
{
   firstOpen = 0.0;
   lastOpen  = 0.0;
   firstTime = 0;
   lastTime  = 0;
   bool any  = false;
   const int total = (int)PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if((long)PositionGetInteger(POSITION_TYPE) != posType)
         continue;
      const double op = PositionGetDouble(POSITION_PRICE_OPEN);
      const datetime tm = (datetime)PositionGetInteger(POSITION_TIME);
      if(!any)
      {
         firstOpen = lastOpen = op;
         firstTime = lastTime = tm;
         any = true;
      }
      else
      {
         if(tm <= firstTime)
         {
            firstTime = tm;
            firstOpen = op;
         }
         if(tm >= lastTime)
         {
            lastTime = tm;
            lastOpen = op;
         }
      }
   }
   return any;
}

bool BasketAvgPrice(const long posType, double &avg, double &sumLots)
{
   avg = 0.0;
   sumLots = 0.0;
   double sumPxVol = 0.0;
   const int total = (int)PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if((long)PositionGetInteger(POSITION_TYPE) != posType)
         continue;
      const double v = PositionGetDouble(POSITION_VOLUME);
      const double p = PositionGetDouble(POSITION_PRICE_OPEN);
      sumPxVol += p * v;
      sumLots += v;
   }
   if(sumLots <= 1e-12)
      return false;
   avg = sumPxVol / sumLots;
   return true;
}

// 该向持仓浮动盈亏（账户货币，含库存费）
double BasketFloatingPL(const long posType)
{
   double sum = 0.0;
   const int total = (int)PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if((long)PositionGetInteger(POSITION_TYPE) != posType)
         continue;
      sum += PositionGetDouble(POSITION_PROFIT);
      sum += PositionGetDouble(POSITION_SWAP);
   }
   return sum;
}

bool CloseAllDirection(const long posType, const string reason)
{
   ulong tickets[];
   int n = 0;
   const int total = (int)PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if((long)PositionGetInteger(POSITION_TYPE) != posType)
         continue;
      ArrayResize(tickets, n + 1);
      tickets[n++] = ticket;
   }
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((uint)InpSlippage);
   bool ok = true;
   for(int j = 0; j < n; j++)
   {
      if(!g_trade.PositionClose(tickets[j], (uint)InpSlippage))
      {
         ok = false;
         if(InpLog)
            Print("平仓失败 ticket=", tickets[j], " err=", GetLastError());
      }
   }
   if(InpLog && ok && n > 0)
      Print("批量平仓 ", (posType == POSITION_TYPE_BUY ? "多" : "空"), " 笔数=", n, " 原因: ", reason);
   return ok;
}

//------------------------------------------------------------
void CheckBasketTakeProfit()
{
   const int nb = CountPositions(POSITION_TYPE_BUY);
   if(nb > 0)
   {
      double avg = 0.0, sumL = 0.0;
      if(BasketAvgPrice(POSITION_TYPE_BUY, avg, sumL))
      {
         const double target = avg * (1.0 + InpTpPercent / 100.0);
         const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(bid >= target)
            CloseAllDirection(POSITION_TYPE_BUY, "多单统盈");
      }
   }

   const int ns = CountPositions(POSITION_TYPE_SELL);
   if(ns > 0)
   {
      double avg = 0.0, sumL = 0.0;
      if(BasketAvgPrice(POSITION_TYPE_SELL, avg, sumL))
      {
         const double target = avg * (1.0 - InpTpPercent / 100.0);
         const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(ask <= target)
            CloseAllDirection(POSITION_TYPE_SELL, "空单统盈");
      }
   }

   if(CountPositions(POSITION_TYPE_BUY) == 0)
      g_longBaseLot = 0.0;
   if(CountPositions(POSITION_TYPE_SELL) == 0)
      g_shortBaseLot = 0.0;
}

// 已达单向最大档时：浮盈 ≥ 结余×比例 则清该向仓位（重头在平仓后由突破逻辑再开）
void CheckMaxLayersBalanceFloatExit()
{
   if(InpMaxLayersFloatPct <= 0.0)
      return;

   const double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal <= 0.0)
      return;

   const double need = bal * (InpMaxLayersFloatPct / 100.0);

   const int nb = CountPositions(POSITION_TYPE_BUY);
   if(nb == InpMaxLayers)
   {
      const double fpl = BasketFloatingPL(POSITION_TYPE_BUY);
      if(fpl >= need)
      {
         if(InpLog)
            Print("满档多单补充平仓: 浮盈=", fpl, " 阈值(结余×", InpMaxLayersFloatPct, "%)=", need);
         CloseAllDirection(POSITION_TYPE_BUY, "满档-浮盈达结余×设定比例");
      }
   }

   const int ns = CountPositions(POSITION_TYPE_SELL);
   if(ns == InpMaxLayers)
   {
      const double fpl = BasketFloatingPL(POSITION_TYPE_SELL);
      if(fpl >= need)
      {
         if(InpLog)
            Print("满档空单补充平仓: 浮盈=", fpl, " 阈值(结余×", InpMaxLayersFloatPct, "%)=", need);
         CloseAllDirection(POSITION_TYPE_SELL, "满档-浮盈达结余×设定比例");
      }
   }

   if(CountPositions(POSITION_TYPE_BUY) == 0)
      g_longBaseLot = 0.0;
   if(CountPositions(POSITION_TYPE_SELL) == 0)
      g_shortBaseLot = 0.0;
}

//------------------------------------------------------------
bool CopyBar1OcMa(double &o1, double &c1, double &ma1)
{
   double o[], c[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(c, true);
   if(CopyOpen(_Symbol, InpWorkTF, 1, 1, o) != 1)
      return false;
   if(CopyClose(_Symbol, InpWorkTF, 1, 1, c) != 1)
      return false;
   double m[];
   ArraySetAsSeries(m, true);
   if(CopyBuffer(g_hMa, 0, 1, 1, m) != 1)
      return false;
   o1 = o[0];
   c1 = c[0];
   ma1 = m[0];
   return true;
}

// 新 K 线开盘时：用上一根已收盘 K 做突破判定；仅在无同向持仓时开首单
void TryOpenFirstOnBreakout()
{
   if(g_hMa == INVALID_HANDLE)
      return;

   double o1 = 0.0, c1 = 0.0, ma1 = 0.0;
   if(!CopyBar1OcMa(o1, c1, ma1))
      return;

   const bool longBreak  = (o1 < ma1 && c1 > ma1);
   const bool shortBreak = (o1 > ma1 && c1 < ma1);

   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((uint)InpSlippage);

   if(longBreak && CountPositions(POSITION_TYPE_BUY) == 0)
   {
      g_longBaseLot = CalcBasketBaseLot();
      if(g_longBaseLot >= MinLot() - 1e-12)
      {
         const string cmt = "马丁-多首单-突破";
         if(g_trade.Buy(g_longBaseLot, _Symbol, 0.0, 0.0, 0.0, cmt))
         {
            if(InpLog)
               Print("开多单首单 手数=", g_longBaseLot);
         }
         else if(InpLog)
            Print("开多单首单失败 err=", GetLastError());
      }
      else
      {
         if(InpLog)
            Print("多单首单手数过小，跳过");
         g_longBaseLot = 0.0;
      }
   }

   if(shortBreak && CountPositions(POSITION_TYPE_SELL) == 0)
   {
      g_shortBaseLot = CalcBasketBaseLot();
      if(g_shortBaseLot >= MinLot() - 1e-12)
      {
         const string cmt = "马丁-空首单-突破";
         if(g_trade.Sell(g_shortBaseLot, _Symbol, 0.0, 0.0, 0.0, cmt))
         {
            if(InpLog)
               Print("开空单首单 手数=", g_shortBaseLot);
         }
         else if(InpLog)
            Print("开空单首单失败 err=", GetLastError());
      }
      else
      {
         if(InpLog)
            Print("空单首单手数过小，跳过");
         g_shortBaseLot = 0.0;
      }
   }
}

//------------------------------------------------------------
void TryGridAddBuy()
{
   const int n = CountPositions(POSITION_TYPE_BUY);
   if(n < 1 || n >= InpMaxLayers)
      return;
   double fo = 0.0, lo = 0.0;
   datetime ft, lt;
   if(!GetBasketEdges(POSITION_TYPE_BUY, fo, lo, ft, lt))
      return;
   if(g_longBaseLot <= 0.0)
      g_longBaseLot = CalcBasketBaseLot(); // 若未设置（如手工单），尽力 fallback

   const double dPrice = fo * (InpStepPercent / 100.0);
   if(dPrice <= 0.0)
      return;
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(bid <= lo - dPrice)
   {
      const int nextTier = n; // 当前已有 n 笔，下一笔档位索引为 n（首单为 0）
      double vol = LotForTier(nextTier, g_longBaseLot);
      if(vol < MinLot() - 1e-12)
      {
         if(InpLog)
            Print("多单加仓手数过小 tier=", nextTier, " 跳过");
         return;
      }
      g_trade.SetExpertMagicNumber((ulong)InpMagic);
      g_trade.SetDeviationInPoints((uint)InpSlippage);
      const bool lastToCap = (n + 1 == InpMaxLayers); // 本次成交后达到单向最大档数（含首单）
      const string cmt = lastToCap ? "马丁-多加仓-已达最大档(末笔·不再加仓)" : "马丁-多加仓";
      if(g_trade.Buy(vol, _Symbol, 0.0, 0.0, 0.0, cmt))
      {
         if(InpLog)
            Print("多加仓 第", (nextTier + 1), "/", InpMaxLayers, "笔 手数=", vol,
                  (lastToCap ? " 【已达单向最大档，后续不再加仓】" : ""),
                  " bid=", bid, " 上开=", lo, " 首开=", fo);
      }
      else if(InpLog)
         Print("多加仓失败 err=", GetLastError());
   }
}

void TryGridAddSell()
{
   const int n = CountPositions(POSITION_TYPE_SELL);
   if(n < 1 || n >= InpMaxLayers)
      return;
   double fo = 0.0, lo = 0.0;
   datetime ft, lt;
   if(!GetBasketEdges(POSITION_TYPE_SELL, fo, lo, ft, lt))
      return;
   if(g_shortBaseLot <= 0.0)
      g_shortBaseLot = CalcBasketBaseLot();

   const double dPrice = fo * (InpStepPercent / 100.0);
   if(dPrice <= 0.0)
      return;
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(ask >= lo + dPrice)
   {
      const int nextTier = n;
      double vol = LotForTier(nextTier, g_shortBaseLot);
      if(vol < MinLot() - 1e-12)
      {
         if(InpLog)
            Print("空单加仓手数过小 tier=", nextTier, " 跳过");
         return;
      }
      g_trade.SetExpertMagicNumber((ulong)InpMagic);
      g_trade.SetDeviationInPoints((uint)InpSlippage);
      const bool lastToCap = (n + 1 == InpMaxLayers);
      const string cmt = lastToCap ? "马丁-空加仓-已达最大档(末笔·不再加仓)" : "马丁-空加仓";
      if(g_trade.Sell(vol, _Symbol, 0.0, 0.0, 0.0, cmt))
      {
         if(InpLog)
            Print("空加仓 第", (nextTier + 1), "/", InpMaxLayers, "笔 手数=", vol,
                  (lastToCap ? " 【已达单向最大档，后续不再加仓】" : ""),
                  " ask=", ask, " 上开=", lo, " 首开=", fo);
      }
      else if(InpLog)
         Print("空加仓失败 err=", GetLastError());
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
   g_longBaseLot = 0.0;
   g_shortBaseLot = 0.0;
   if(InpLog)
      Print("马丁网格 EA 初始化: ", _Symbol, " 工作周期=", EnumToString(InpWorkTF),
            " MA=", InpMAPeriod,
            " 补仓%=", InpStepPercent,
            " 加仓放大手数=", InpAddLotBoost, " 档间隔=", InpTierInterval,
            " 统盈%=", InpTpPercent,
            " 满档浮盈阈值%=", InpMaxLayersFloatPct,
            " 复利=", (InpUseCompound ? "开" : "关"));
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

   CheckBasketTakeProfit();
   CheckMaxLayersBalanceFloatExit();

   const datetime bar0 = iTime(_Symbol, InpWorkTF, 0);
   if(bar0 != 0 && bar0 != g_lastWorkBar)
   {
      g_lastWorkBar = bar0;
      TryOpenFirstOnBreakout();
   }

   TryGridAddBuy();
   TryGridAddSell();
}

//+------------------------------------------------------------------+
