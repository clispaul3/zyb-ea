//+------------------------------------------------------------------+
//|                                                20260425.ea.mq5  |
//| 马丁网格：小周期震荡、加仓后整体盈利平仓；K 线周期可独立于图表  |
//+------------------------------------------------------------------+
#property copyright "EA-2026"
#property link      ""
#property version   "1.11"
#property description "Martin grid: TP/统盈/加仓间距=%% of ref price; max orders/side; no K-timeout close (v1.11+)"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>

CTrade         g_trade;
CSymbolInfo    g_sym;
CPositionInfo  g_pos;

// 内置 20 档(解析 InpLotLadder 失败或节数不足时回退) — 与当前默认字符串一致
const double g_builtinLadder[20] =
  {
   0.05, 0.05, 0.05, 0.10, 0.10, 0.10, 0.15, 0.20, 0.20, 0.25,
   0.30, 0.35, 0.45, 0.55, 0.65, 0.75, 0.90, 1.2, 1.4, 1.5
  };
double         g_lotLadder[20];
#define        MGRID_VTP_B "MGvTP_20260425_BUY"
#define        MGRID_VTP_S "MGvTP_20260425_SELL"
#define        MGRID_TGT_L "MG_20260425_TGTLIST"

//--- 以下三处为「相对**参考价**的价距%」, 在运行时按当刻价格换算为实际价格步长(非点)
input group "滑点"
input int             InpSlippage = 30;        // 滑点（点）

input group "识别"
input long            InpMagic    = 20260425;   // Magics

input group "首单与统盈(百分比,见底部说明)"
input double          InpFirstTpPercent = 0.05;  // 首档(仅1~Lot1层)止盈：每单= **该笔开仓价**×% 为价距；>=2层用统盈% ；<=0=不挂首档TP(单档时改按统盈%平)
input double          InpAveTpPercent  = 0.05; // 统盈：相对**整体成本价** 的价距%（>=2 档整篮; 1档且未挂首档TP时亦用）

input group "加仓"
input double          InpDisPercent  = 0.1;   // 与上一同向**开仓价** 的间距：价距= lastOpen×%（市价多=Ask,空=Bid 与 last 比）
input double          InpAddTimes = 1.2;        // 满 20 单后再加仓：在 Lot20 上乘此倍率 (Add_times)
input int             InpMaxOrdersPerSide = 20; // 单方向最多同时持仓**笔数**；达到后不再开新仓(不平仓,可手工)；0=不限制

input group "头寸(第1~20档,一行逗号分隔)"
input string          InpLotLadder = "0.05,0.05,0.05,0.10,0.10,0.10,0.15,0.20,0.20,0.25,0.30,0.35,0.45,0.55,0.65,0.75,0.90,1.2,1.4,1.5";

input group "拆单"
input int             InpOrdersPerAdd = 1;     // 每次加仓/首单 同时下几笔同向单（>=1，总手数仍为一档合计）

input group "其它"
input int             InpMaxSpreadPoints = 0; // 最大点差（点），0=不限制
input bool            InpLog = true;          // 专家日志

input group "图表(统盈参考线)"
input bool            InpDrawVtp = true;     // 多/空各一条虚拟水平线(仅参考,非真实挂单)
input int             InpVtpLineWidth = 1;
input color           InpVtpColorLong  = clrDodgerBlue;
input color           InpVtpColorShort = clrDarkOrange;
input bool            InpShowBasketTgtList = true;  // 图上列表:每单#、开仓、统盈目标价(与程序整篮价一致,非订单TP栏)
input color           InpTgtListColor  = clrNavy;
input int             InpTgtListFont   = 9;

//+------------------------------------------------------------------+
double PointValue()
  {
   if(!g_sym.Name(_Symbol))
      return _Point;
   g_sym.RefreshRates();
   return g_sym.Point();
  }

//+------------------------------------------------------------------+
// 价距 = 参考价 × (参数百分比/100)；参考为各用途各自给定的开仓/成本(见输入说明)
//+------------------------------------------------------------------+
double PctOfPrice(const double refPrice, const double pct)
  {
   if(refPrice <= 0.0)
      return 0.0;
   if(pct <= 0.0)
      return 0.0;
   return refPrice * (pct / 100.0);
  }

//+------------------------------------------------------------------+
double MinLot() { return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN); }
double MaxLot() { return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX); }
double LotStep(){ return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP); }

//+------------------------------------------------------------------+
string TrimToken(const string u)
  {
   string t = u;
   const int L0 = (int)StringLen(t);
   for(int a = 0; a < L0; a++)
     {
      if(StringGetCharacter(t, 0) != 32)
         break;
      t = StringSubstr(t, 1);
     }
   int L = (int)StringLen(t);
   for(int b = 0; b < L; b++)
     {
      if(StringGetCharacter(t, L - 1) != 32)
         break;
      t = StringSubstr(t, 0, L - 1);
      L = (int)StringLen(t);
     }
   return t;
  }

//+------------------------------------------------------------------+
// 自 InpLotLadder 解析 20 档; 节数/数值不对则回退 g_builtinLadder
//+------------------------------------------------------------------+
void InitLotLadder()
  {
   for(int a = 0; a < 20; a++)
      g_lotLadder[a] = g_builtinLadder[a];
   const int slen = (int)StringLen(InpLotLadder);
   if(slen < 1)
     {
      if(InpLog)
         Print("InpLotLadder empty, using builtin 20-lot");
      return;
     }
   string toks[];
   // StringSplit(…,ushort,[]) 无隐式 string→ushort 警告
   int n = StringSplit(InpLotLadder, (ushort)44, toks);
   if(n < 20)
     {
      n = StringSplit(InpLotLadder, (ushort)59, toks);
     }
   if(n < 20)
     {
      if(InpLog)
         Print("InpLotLadder need 20 numbers, got ", n, " — builtin");
      return;
     }
   for(int k = 0; k < 20; k++)
     {
      const double w = StringToDouble(TrimToken(toks[k]));
      if(w <= 0.0)
        {
         g_lotLadder[k] = g_builtinLadder[k];
        }
      else
         g_lotLadder[k] = w;
     }
  }

//+------------------------------------------------------------------+
void LogInitDiagnostics()
  {
   if(!InpLog)
      return;
   Print("20260425 v1.11 ", _Symbol, " magic=", (long)InpMagic,
         " 首档TP%=", InpFirstTpPercent, " 统盈%=", InpAveTpPercent, " 加仓距%=", InpDisPercent,
         " 单向最多笔数=", InpMaxOrdersPerSide);
  }

//+------------------------------------------------------------------+
bool SpreadOk()
  {
   if(InpMaxSpreadPoints <= 0)
      return true;
   const int sp = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(sp > InpMaxSpreadPoints)
      return false;
   return true;
  }

//+------------------------------------------------------------------+
// 0-based 第 idx 档同向总手数(第0档=第1单 … 第19档=第20单; 第20档起为 第20档手数*倍率^n)
//+------------------------------------------------------------------+
double LotForLayerIndex(const int idx)
  {
   const double m = InpAddTimes;
   if(idx < 0)
      return MinLot();
   if(idx < 20)
      return g_lotLadder[idx];
   // idx >= 20: 以第20档(索引19)为基准
   const int p = idx - 19;
   return g_lotLadder[19] * MathPow(m, p);
  }

//+------------------------------------------------------------------+
double NormalizeVolume(const double v)
  {
   double o = v;
   const double st = LotStep();
   const double lo = MinLot();
   const double hi = MaxLot();
   if(st > 0.0)
      o = MathRound(o / st) * st;
   o = MathMax(lo, MathMin(hi, o));
   o = MathMax(lo, o);
   return o;
  }

//+------------------------------------------------------------------+
int OrdersPerAdd()
  {
   return MathMax(1, InpOrdersPerAdd);
  }

//+------------------------------------------------------------------+
// InpMaxOrdersPerSide<=0 不限制；否则本次若开仓则持仓笔数不超过上限（含拆单）
//+------------------------------------------------------------------+
bool CanOpenMoreOrders(const int currentOrderCount)
  {
   if(InpMaxOrdersPerSide <= 0)
      return true;
   const int nOrd = OrdersPerAdd();
   return (currentOrderCount + nOrd <= InpMaxOrdersPerSide);
  }

//+------------------------------------------------------------------+
// 将一层总手数拆成多笔（README：加仓可同时下多笔同向单），总和≈ total
//+------------------------------------------------------------------+
void SplitVolumeToOrders(const double total, double &parts[])
  {
   const int n = OrdersPerAdd();
   ArrayResize(parts, n);
   if(n == 1)
     {
      parts[0] = NormalizeVolume(total);
      return;
     }
   const double t = NormalizeVolume(total);
   if(t < MinLot() * n - 1e-12)
     {
      parts[0] = NormalizeVolume(total);
      for(int k = 1; k < n; k++)
         parts[k] = MinLot();
      return;
     }
   const double st  = MathMax(LotStep(), 0.0000000001);
   const int    steps = (int)MathRound((t - MinLot() * n) / st);
   if(steps < 0)
     {
      for(int i = 0; i < n; i++)
         parts[i] = MinLot();
      return;
     }
   const int base = steps / n;
   int      rem  = (int)(steps - base * n);
   for(int j = 0; j < n; j++)
     {
      const int add = base + (rem > 0 ? 1 : 0);
      if(rem > 0)
         rem--;
      parts[j] = NormalizeVolume(MinLot() + (double)add * st);
     }
  }

//+------------------------------------------------------------------+
struct SBasket
  {
   int               count;
   double            lastPrice;     // 时间上最后一笔的开仓价
   double            avgPrice;      // 成本价
   double            sumLots;
  };

//+------------------------------------------------------------------+
bool BuildBasket(const ENUM_POSITION_TYPE ptype, SBasket &b)
  {
   b.count = 0;
   b.lastPrice = 0.0;
   b.avgPrice = 0.0;
   b.sumLots = 0.0;
   double sumP = 0.0;
   datetime tLast   = 0;
   ulong    lastTix = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!g_pos.SelectByIndex(i))
         continue;
      if(g_pos.Magic() != (ulong)InpMagic)
         continue;
      if(g_pos.Symbol() != _Symbol)
         continue;
      if(g_pos.PositionType() != ptype)
         continue;
      b.count++;
      const datetime tt = g_pos.Time();
      const double  op = g_pos.PriceOpen();
      const double  vl = g_pos.Volume();
      const ulong  tix = (ulong)g_pos.Ticket();
      sumP += op * vl;
      b.sumLots += vl;
      if(tLast == 0 || tt > tLast || (tt == tLast && tix > lastTix))
        {
         tLast = tt;
         lastTix = tix;
         b.lastPrice = op;
        }
     }
   if(b.count < 1 || b.sumLots <= 0.0)
      return false;
   b.avgPrice = sumP / b.sumLots;
   return true;
  }

//+------------------------------------------------------------------+
bool CloseType(const ENUM_POSITION_TYPE ptype, const string reason)
  {
   bool ok = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!g_pos.SelectByIndex(i))
         continue;
      if(g_pos.Magic() != (ulong)InpMagic || g_pos.Symbol() != _Symbol)
         continue;
      if(g_pos.PositionType() != ptype)
         continue;
      if(!g_trade.PositionClose(g_pos.Ticket(), InpSlippage))
        {
         ok = false;
         if(InpLog)
            Print("20260425 close fail ticket=", (ulong)g_pos.Ticket(), " err=", GetLastError());
        }
     }
   if(InpLog && ok)
      Print("20260425 全部平", ptype == POSITION_TYPE_BUY ? "多" : "空", " 原因: ", reason);
   return ok;
  }

//+------------------------------------------------------------------+
void RemoveTakeProfitsType(const ENUM_POSITION_TYPE ptype)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!g_pos.SelectByIndex(i))
         continue;
      if(g_pos.Magic() != (ulong)InpMagic || g_pos.Symbol() != _Symbol)
         continue;
      if(g_pos.PositionType() != ptype)
         continue;
      if(g_pos.TakeProfit() == 0.0)
         continue;
      g_trade.PositionModify(g_pos.Ticket(), g_pos.StopLoss(), 0.0);
     }
  }

//+------------------------------------------------------------------+
int PriceDigits() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }

//+------------------------------------------------------------------+
bool OpenChunkBuy(const double vol, const string cmt)
  {
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((uint)InpSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   if(!g_trade.Buy(NormalizeVolume(vol), _Symbol, 0, 0, 0, cmt))
     {
      if(InpLog)
         Print("20260425 Buy fail vol=", vol, " err=", g_trade.ResultRetcodeDescription());
      return false;
     }
   g_sym.RefreshRates();
   return true;
  }

//+------------------------------------------------------------------+
bool OpenChunkSell(const double vol, const string cmt)
  {
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((uint)InpSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   if(!g_trade.Sell(NormalizeVolume(vol), _Symbol, 0, 0, 0, cmt))
     {
      if(InpLog)
         Print("20260425 Sell fail vol=", vol, " err=", g_trade.ResultRetcodeDescription());
      return false;
     }
   g_sym.RefreshRates();
   return true;
  }

//+------------------------------------------------------------------+
bool OpenBuyLayersForTotal(const int layerIdx, const string tag)
  {
   const double want = LotForLayerIndex(layerIdx);
   if(want < MinLot() - 0.0000001)
     {
      if(InpLog)
         Print("20260425 手数过小 跳过 layer=", layerIdx);
      return false;
     }
   double parts[];
   SplitVolumeToOrders(want, parts);
   for(int k = 0; k < ArraySize(parts); k++)
     {
      if(!OpenChunkBuy(parts[k], "MGb_" + tag + "_" + IntegerToString(k)))
         return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
bool OpenSellLayersForTotal(const int layerIdx, const string tag)
  {
   const double want = LotForLayerIndex(layerIdx);
   if(want < MinLot() - 0.0000001)
     {
      if(InpLog)
         Print("20260425 手数过小 跳过 layer=", layerIdx);
      return false;
     }
   double parts[];
   SplitVolumeToOrders(want, parts);
   for(int k = 0; k < ArraySize(parts); k++)
     {
      if(!OpenChunkSell(parts[k], "MGs_" + tag + "_" + IntegerToString(k)))
         return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
void SetFirstLayerBuyTP()
  {
   // 仅首档(一层)：每笔按该笔 **开仓价×首档%** 挂 TP；拆单时各单各自
   if(InpFirstTpPercent <= 0.0)
      return;
   g_sym.RefreshRates();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!g_pos.SelectByIndex(i))
         continue;
      if(g_pos.Magic() != (ulong)InpMagic || g_pos.Symbol() != _Symbol)
         continue;
      if(g_pos.PositionType() != POSITION_TYPE_BUY)
         continue;
      const double op  = g_pos.PriceOpen();
      const double tpd = PctOfPrice(op, InpFirstTpPercent);
      const double tp  = op + tpd;
      g_trade.PositionModify(g_pos.Ticket(), 0, NormalizeDouble(tp, PriceDigits()));
     }
  }

//+------------------------------------------------------------------+
void SetFirstLayerSellTP()
  {
   if(InpFirstTpPercent <= 0.0)
      return;
   g_sym.RefreshRates();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!g_pos.SelectByIndex(i))
         continue;
      if(g_pos.Magic() != (ulong)InpMagic || g_pos.Symbol() != _Symbol)
         continue;
      if(g_pos.PositionType() != POSITION_TYPE_SELL)
         continue;
      const double op  = g_pos.PriceOpen();
      const double tpd = PctOfPrice(op, InpFirstTpPercent);
      const double tp  = op - tpd;
      g_trade.PositionModify(g_pos.Ticket(), 0, NormalizeDouble(tp, PriceDigits()));
     }
  }

//+------------------------------------------------------------------+
void VtpLineDeleteName(const string name)
  {
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);
  }

//+------------------------------------------------------------------+
// >=2 档时列表「获利」为 0(程序内统盈此时尚无单笔 TP) — 用水平线标出统盈价供查看
//+------------------------------------------------------------------+
void VtpHLineSet(const string name, const double price, const color clr, const string toolTip)
  {
   const int dd = PriceDigits();
   const double p = NormalizeDouble(price, dd);
   if(!ObjectCreate(0, name, OBJ_HLINE, 0, 0, p))
     {
      if(ObjectFind(0, name) < 0)
         return;
     }
   ObjectSetDouble(0, name, OBJPROP_PRICE, p);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, InpVtpLineWidth);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, toolTip);
  }

//+------------------------------------------------------------------+
void UpdateVirtualTPLines()
  {
   if(!InpDrawVtp)
     {
      VtpLineDeleteName(MGRID_VTP_B);
      VtpLineDeleteName(MGRID_VTP_S);
      ChartRedraw(0);
      return;
     }
   g_sym.RefreshRates();
   const int    nO   = MathMax(1, InpOrdersPerAdd);

   SBasket bB, bS;
   const bool hB = BuildBasket(POSITION_TYPE_BUY, bB);
   const bool hS = BuildBasket(POSITION_TYPE_SELL, bS);

   if(hB && bB.count > 0)
     {
      const int    lay  = bB.count / nO;
      const double aved = PctOfPrice(bB.avgPrice, InpAveTpPercent);
      const double tppd = PctOfPrice(bB.avgPrice, InpFirstTpPercent);
      double       target;
      if(lay >= 2)
         target = bB.avgPrice + aved;
      else
         target = bB.avgPrice + (InpFirstTpPercent > 0.0 ? tppd : aved);
      VtpHLineSet(MGRID_VTP_B, target, InpVtpColorLong, "buy VTP");
     }
   else
      VtpLineDeleteName(MGRID_VTP_B);

   if(hS && bS.count > 0)
     {
      const int    layS = bS.count / nO;
      const double aved = PctOfPrice(bS.avgPrice, InpAveTpPercent);
      const double tppd = PctOfPrice(bS.avgPrice, InpFirstTpPercent);
      double       tgs;
      if(layS >= 2)
         tgs = bS.avgPrice - aved;
      else
         tgs = bS.avgPrice - (InpFirstTpPercent > 0.0 ? tppd : aved);
      VtpHLineSet(MGRID_VTP_S, tgs, InpVtpColorShort, "sell VTP");
     }
   else
      VtpLineDeleteName(MGRID_VTP_S);

   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
// 统盈同价多笔时不可能全部挂成有效经纪商 TP,故仅图上列出「#—开仓—T目标」(与程序整篮价一致)
//+------------------------------------------------------------------+
void TgtListDelete()
  {
   if(ObjectFind(0, MGRID_TGT_L) >= 0)
      ObjectDelete(0, MGRID_TGT_L);
  }

//+------------------------------------------------------------------+
void UpdateBasketTgtListLabel()
  {
   if(!InpShowBasketTgtList)
     {
      TgtListDelete();
      return;
     }
   g_sym.RefreshRates();
   const int    d    = PriceDigits();
   const int    nO   = MathMax(1, InpOrdersPerAdd);

   SBasket bB, bS;
   const bool hB = BuildBasket(POSITION_TYPE_BUY, bB) && bB.count > 0;
   const bool hS = BuildBasket(POSITION_TYPE_SELL, bS) && bS.count > 0;
   if(!hB && !hS)
     {
      TgtListDelete();
      return;
     }
   string txt = "20260425 统盈(程序整篮)\n(订单「获利」可能为0)\n";
   if(hB)
     {
      const int    layB  = bB.count / nO;
      const double aved  = PctOfPrice(bB.avgPrice, InpAveTpPercent);
      const double tppd  = PctOfPrice(bB.avgPrice, InpFirstTpPercent);
      const double pexB  = (layB >= 2) ? bB.avgPrice + aved : bB.avgPrice + (InpFirstTpPercent > 0.0 ? tppd : aved);
      txt += "多 目标T " + DoubleToString(pexB, d) + "  成本 " + DoubleToString(bB.avgPrice, d) + "\n";
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(!g_pos.SelectByIndex(i))
            continue;
         if(g_pos.Magic() != (ulong)InpMagic || g_pos.Symbol() != _Symbol)
            continue;
         if(g_pos.PositionType() != POSITION_TYPE_BUY)
            continue;
         const ulong t = (ulong)g_pos.Ticket();
         txt += "  #" + (string)(ulong)t + "  开" + DoubleToString(g_pos.PriceOpen(), d) + "  →T" + DoubleToString(pexB, d) + "\n";
        }
     }
   if(hS)
     {
      const int    layS  = bS.count / nO;
      const double avedS = PctOfPrice(bS.avgPrice, InpAveTpPercent);
      const double tppdS = PctOfPrice(bS.avgPrice, InpFirstTpPercent);
      const double pexS  = (layS >= 2) ? bS.avgPrice - avedS : bS.avgPrice - (InpFirstTpPercent > 0.0 ? tppdS : avedS);
      txt += "空 目标T " + DoubleToString(pexS, d) + "  成本 " + DoubleToString(bS.avgPrice, d) + "\n";
      for(int j = PositionsTotal() - 1; j >= 0; j--)
        {
         if(!g_pos.SelectByIndex(j))
            continue;
         if(g_pos.Magic() != (ulong)InpMagic || g_pos.Symbol() != _Symbol)
            continue;
         if(g_pos.PositionType() != POSITION_TYPE_SELL)
            continue;
         const ulong t2 = (ulong)g_pos.Ticket();
         txt += "  #" + (string)(ulong)t2 + "  开" + DoubleToString(g_pos.PriceOpen(), d) + "  →T" + DoubleToString(pexS, d) + "\n";
        }
     }
   const int mlen = 1800; // 防止过长
   if(StringLen(txt) > mlen)
      txt = StringSubstr(txt, 0, mlen) + "…";

   if(!ObjectCreate(0, MGRID_TGT_L, OBJ_LABEL, 0, 0, 0))
     {
      if(ObjectFind(0, MGRID_TGT_L) < 0)
         return;
     }
   ObjectSetInteger(0, MGRID_TGT_L, OBJPROP_CORNER, CORNER_LEFT_LOWER);
   ObjectSetInteger(0, MGRID_TGT_L, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, MGRID_TGT_L, OBJPROP_XDISTANCE, 6);
   ObjectSetInteger(0, MGRID_TGT_L, OBJPROP_YDISTANCE, 8);
   ObjectSetString(0, MGRID_TGT_L, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, MGRID_TGT_L, OBJPROP_COLOR, InpTgtListColor);
   ObjectSetInteger(0, MGRID_TGT_L, OBJPROP_FONTSIZE, InpTgtListFont);
   ObjectSetString(0, MGRID_TGT_L, OBJPROP_FONT, "Arial");
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
void ProcessLongSide()
  {
   SBasket b;
   g_sym.RefreshRates();
   const int nOrd = OrdersPerAdd();
   if(!BuildBasket(POSITION_TYPE_BUY, b))
     {
      if(!SpreadOk())
         return;
      if(!CanOpenMoreOrders(0))
         return;
      if(!OpenBuyLayersForTotal(0, "0"))
         return;
      SetFirstLayerBuyTP();
      return;
     }
   const int layers = b.count / nOrd;

   const double dis = PctOfPrice(b.lastPrice, InpDisPercent);
   const double ave = PctOfPrice(b.avgPrice, InpAveTpPercent);

   // 1) 统盈: >=2 档 用成本价+统盈%；1 档 靠首档TP(或首档%=0 时在此统盈)
   g_sym.RefreshRates();
   if(layers >= 2)
     {
      if(g_sym.Bid() >= b.avgPrice + ave)
        {
         CloseType(POSITION_TYPE_BUY, "统盈(>=2档)");
         return;
        }
     }
   else
     {
      if(InpFirstTpPercent <= 0.0 && g_sym.Bid() >= b.avgPrice + ave)
        {
         CloseType(POSITION_TYPE_BUY, "单档无首档TP%,按成本+统盈%");
         return;
        }
     }

   // 2) 加仓: 与上一笔成交价(多=Ask)相对 last 至少 上一×Dis%
   g_sym.RefreshRates();
   if(g_sym.Ask() <= b.lastPrice - dis)
     {
      if(!CanOpenMoreOrders(b.count))
         return;
      if(!SpreadOk())
         return;
      if(b.count > 0)
         RemoveTakeProfitsType(POSITION_TYPE_BUY);
      const int nextLayer = b.count / nOrd; // 下一档索引 = 已满仓数
      if(!OpenBuyLayersForTotal(nextLayer, IntegerToString(nextLayer)))
         return;
     }
  }

//+------------------------------------------------------------------+
void ProcessShortSide()
  {
   SBasket b;
   g_sym.RefreshRates();
   const int nOrd = OrdersPerAdd();
   if(!BuildBasket(POSITION_TYPE_SELL, b))
     {
      if(!SpreadOk())
         return;
      if(!CanOpenMoreOrders(0))
         return;
      if(!OpenSellLayersForTotal(0, "0"))
         return;
      SetFirstLayerSellTP();
      return;
     }
   const int layers = b.count / nOrd;

   const double dis = PctOfPrice(b.lastPrice, InpDisPercent);
   const double ave = PctOfPrice(b.avgPrice, InpAveTpPercent);

   g_sym.RefreshRates();
   if(layers >= 2)
     {
      if(g_sym.Ask() <= b.avgPrice - ave)
        {
         CloseType(POSITION_TYPE_SELL, "统盈(>=2档)");
         return;
        }
     }
   else
     {
      if(InpFirstTpPercent <= 0.0 && g_sym.Ask() <= b.avgPrice - ave)
        {
         CloseType(POSITION_TYPE_SELL, "单档无首档TP%,按成本+统盈%");
         return;
        }
     }
   g_sym.RefreshRates();
   if(g_sym.Bid() >= b.lastPrice + dis)
     {
      if(!CanOpenMoreOrders(b.count))
         return;
      if(!SpreadOk())
         return;
      if(b.count > 0)
         RemoveTakeProfitsType(POSITION_TYPE_SELL);
      const int nextLayer = b.count / nOrd;
      if(!OpenSellLayersForTotal(nextLayer, IntegerToString(nextLayer)))
         return;
     }
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_sym.Name(_Symbol);
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   InitLotLadder();
   LogInitDiagnostics();
   if(InpAddTimes < 1.0)
     {
      Print("20260425: AddTimes 应 >=1");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpDisPercent <= 0.0)
     {
      Print("20260425: InpDisPercent 应 >0");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpAveTpPercent <= 0.0)
     {
      Print("20260425: InpAveTpPercent 应 >0");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpFirstTpPercent < 0.0)
     {
      Print("20260425: InpFirstTpPercent 应 >=0");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(LotForLayerIndex(0) < MinLot() - 1e-8)
     {
      Print("20260425: 第1档手数小于平台最小手,请改 InpLotLadder[0] 或品种");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMaxOrdersPerSide > 0 && OrdersPerAdd() > InpMaxOrdersPerSide)
     {
      Print("20260425: InpOrdersPerAdd 不能大于 InpMaxOrdersPerSide(否则无法开首单)");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      Print("20260425: 自动交易已关闭(终端设置)");
     }
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   VtpLineDeleteName(MGRID_VTP_B);
   VtpLineDeleteName(MGRID_VTP_S);
   TgtListDelete();
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   g_sym.RefreshRates();
   // 多、空 两边独立
   ProcessLongSide();
   ProcessShortSide();
   UpdateVirtualTPLines();
   UpdateBasketTgtListLabel();
  }

//+------------------------------------------------------------------+

