//+------------------------------------------------------------------+
//|                                            GoldKylin_MQL5.mq5    |
//|                        金麒麟EA - MQL5版本                        |
//|                        网格马丁+对冲策略                          |
//+------------------------------------------------------------------+
#property copyright "Converted to MQL5"
#property link      "https://hisanhe.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- 交易对象
CTrade         trade;
CPositionInfo  posInfo;
COrderInfo     orderInfo;
CSymbolInfo    symInfo;

//+------------------------------------------------------------------+
//| 输入参数                                                          |
//+------------------------------------------------------------------+
//--- 价格限制
input group "价格限制设置"
input double   On_top_of_this_price_not_Buy_first_order = 0;      // 高于此价不开首单买(0=关闭)
input double   On_under_of_this_price_not_Sell_first_order = 0;   // 低于此价不开首单卖(0=关闭)
input double   On_top_of_this_price_not_Buy_order = 0;            // 高于此价不补单买(0=关闭)
input double   On_under_of_this_price_not_Sell_order = 0;         // 低于此价不补单卖(0=关闭)

//--- 时间控制
input group "时间控制"
input string   InLimit_StartTime = "00:00";                        // 挂单开始时间
input string   InLimit_StopTime = "24:00";                         // 挂单停止时间
input string   InEA_StartTime = "00:00";                           // EA开始时间
input string   InEA_StopTime = "24:00";                            // EA停止时间

//--- 平仓控制
input group "平仓设置"
input bool     CloseBuySell = true;                                // 对冲平仓开关
input bool     HomeopathyCloseAll = true;                          // 同向对冲平仓开关
input bool     Homeopathy = true;                                  // 允许同向手数对冲补单
input bool     Over = false;                                       // 公司到期
input int      NextTime = 0;                                       // 到期后等待秒数

//--- 资金管理
input group "资金管理"
input double   Money = -300;                                       // 盈利后才补单(负数=关闭)
input int      InFirstStep = 60;                                   // 首单距离(点)
input int      InMinDistance = 200;                                // 最小距离(点)
input int      TwoMinDistance = 200;                               // 第二最小距离(点)
input int      StepTrallOrders = 80;                               // 挂单追踪点数
input int      InStep = 300;                                       // 补单间距(点)
input int      TwoStep = 300;                                      // 第二补单间距(点)

//--- 开仓时间模式
enum ENUM_OPEN_MODE {
   MODE_NEW_BAR = 1,        // 新K线开仓
   MODE_TIMED = 2,          // 定时开仓(秒)
   MODE_ALWAYS = 3          // 不限制
};
input ENUM_OPEN_MODE  OpenMode = MODE_ALWAYS;                      // 开仓模式
input ENUM_TIMEFRAMES TimeZone = PERIOD_M1;                        // 新K线时间周期
input int      SleepSeconds = 30;                                  // 定时开仓间隔(秒)

//--- 风险控制
input group "风险控制"
input double   MaxLoss = -1000;                                    // 单边最大亏损后不再补单
input double   MaxLossCloseAll = -50;                              // 单边强平阈值
input double   lot = 0.01;                                         // 初始手数
input double   MaxLot = 5;                                         // 最大单次手数
input double   PlusLot = 0;                                        // 累加手数
input double   K_Lot = 2.0;                                        // 手数倍率
input int      DigitsLot = 2;                                      // 手数小数位数
input double   CloseAll = 5.0;                                     // 总盈利平仓(美元)
input bool     Profit = true;                                      // 单边盈利平仓开关
input double   StopProfit = 5.0;                                   // 单边止盈(美元)
input double   StopLoss = -1000;                                   // 总亏损止损(美元)
input int      Magic = 9589998;                                    // EA魔术号
input int      Totals = 10;                                        // 最大订单数
input int      MaxSpread = 60;                                     // 最大点差限制
input int      Leverage = 100;                                     // 最小杠杆要求

//--- 显示设置
input group "显示设置"
input color    clr1 = clrMediumSeaGreen;                           // 多单颜色
input color    clr2 = clrCrimson;                                  // 空单颜色

//+------------------------------------------------------------------+
//| 全局变量                                                          |
//+------------------------------------------------------------------+
datetime g_lastBarTime = 0;          // 上一根K线时间
datetime g_lastOpenTime = 0;         // 上次开仓时间
datetime g_lastBuyOrderTime = 0;     // 上次多单挂单时间
datetime g_lastSellOrderTime = 0;    // 上次空单挂单时间
datetime g_expirationTime = 0;       // 到期时间
bool     g_canTradeBuy = true;       // 允许做多
bool     g_canTradeSell = true;      // 允许做空
int      g_freezeLevel = 0;          // 冻结距离
double   g_pointValue = 0;           // 点值
int      g_digits = 0;               // 小数位数
int      g_lastBuyCount = 0;         // 上次多单数量
int      g_lastSellCount = 0;        // 上次空单数量
double   g_lastBuyPendingPrice = 0;  // 上次多单挂单价格
double   g_lastSellPendingPrice = 0; // 上次空单挂单价格
bool     g_processingBuyOrder = false;  // 正在处理多单(防止并发)
bool     g_processingSellOrder = false; // 正在处理空单(防止并发)

// 运行时变量(从input复制)
string   Limit_StartTime;
string   Limit_StopTime;
string   EA_StartTime;
string   EA_StopTime;
int      FirstStep;
int      MinDistance;
int      Step;

//+------------------------------------------------------------------+
//| 专家初始化函数                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- 复制input参数到可修改变量
   Limit_StartTime = InLimit_StartTime;
   Limit_StopTime = InLimit_StopTime;
   EA_StartTime = InEA_StartTime;
   EA_StopTime = InEA_StopTime;
   FirstStep = InFirstStep;
   MinDistance = InMinDistance;
   Step = InStep;

   //--- 设置交易对象
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   trade.SetAsyncMode(false);

   //--- 获取品种信息
   if(!symInfo.Name(_Symbol))
   {
      Print("品种信息获取失败");
      return(INIT_FAILED);
   }
   symInfo.Refresh();

   //--- 设置全局变量
   g_digits = (int)symInfo.Digits();
   g_pointValue = symInfo.Point();
   g_freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   //--- 检查最小距离
   int minStopLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(FirstStep < minStopLevel)
      FirstStep = minStopLevel;
   if(Step < minStopLevel)
      Step = minStopLevel;
   if(MinDistance < minStopLevel)
      MinDistance = minStopLevel;

   //--- 检查时间字符串格式
   StringReplace(EA_StartTime, " ", "");
   StringReplace(EA_StopTime, " ", "");
   StringReplace(Limit_StartTime, " ", "");
   StringReplace(Limit_StopTime, " ", "");

   if(EA_StopTime == "24:00") EA_StopTime = "23:59:59";
   if(Limit_StopTime == "24:00") Limit_StopTime = "23:59:59";

   //--- 设置定时器(每秒检查一次)
   EventSetTimer(1);

   Print("金麒麟EA MQL5版本初始化成功!");
   PlaySound("starting.wav");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 专家反初始化函数                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, -1);
   Comment("");
}

//+------------------------------------------------------------------+
//| 专家tick函数                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 更新品种信息
   symInfo.Refresh();
   symInfo.RefreshRates();

   //--- 检查交易权限
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      Comment("未开启自动交易或EA未授权");
      return;
   }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Comment("终端未允许交易");
      return;
   }

   //--- 检查杠杆
   if((int)AccountInfoInteger(ACCOUNT_LEVERAGE) < Leverage)
   {
      Comment("账户杠杆不足,需要至少:", Leverage);
      g_canTradeBuy = false;
      g_canTradeSell = false;
      return;
   }

   //--- 检查点差
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpread)
   {
      Comment("点差过大:", spread, " > ", MaxSpread);
      g_canTradeBuy = false;
      g_canTradeSell = false;
      return;
   }

   //--- 检查EA运行时间
   if(!CheckEATimeFilter())
   {
      Comment("当前不在EA运行时间内");
      g_canTradeBuy = false;
      g_canTradeSell = false;
      return;
   }
   else
   {
      g_canTradeBuy = true;
      g_canTradeSell = true;
   }

   //--- 检查是否到期
   if(Over && TimeCurrent() < g_expirationTime)
   {
      Comment("EA暂停运行 ", NextTime, " 秒!");
      g_canTradeBuy = false;
      g_canTradeSell = false;
      return;
   }

   //--- 统计持仓信息
   int buyCount = 0, sellCount = 0;
   int buyStopCount = 0, sellStopCount = 0;
   double buyLots = 0, sellLots = 0;
   double buyProfit = 0, sellProfit = 0;
   double highestBuyPrice = 0, lowestBuyPrice = 0;
   double highestSellPrice = 0, lowestSellPrice = 0;

   CountPositions(buyCount, sellCount, buyLots, sellLots, buyProfit, sellProfit,
                   highestBuyPrice, lowestBuyPrice, highestSellPrice, lowestSellPrice);

   CountPendingOrders(buyStopCount, sellStopCount);

   double totalProfit = buyProfit + sellProfit;

   //--- 检查订单数限制
   if(buyCount + sellCount >= Totals)
   {
      g_canTradeBuy = false;
      g_canTradeSell = false;
   }

   //--- 检查Over模式
   if(Over)
   {
      if(buyCount == 0) g_canTradeBuy = false;
      if(sellCount == 0) g_canTradeSell = false;
   }

   //--- 平仓逻辑
   CheckCloseConditions(buyCount, sellCount, buyLots, sellLots, buyProfit, sellProfit, totalProfit);

   //--- 检查最大亏损限制
   if(buyProfit <= MaxLoss) g_canTradeBuy = false;
   if(sellProfit <= MaxLoss) g_canTradeSell = false;

   //--- 开仓/挂单逻辑
   if(CheckOpenTimeFilter())
   {
      //--- 做多逻辑 - 多层防重复保护
      if(g_canTradeBuy && buyStopCount == 0 && buyProfit > MaxLoss && !g_processingBuyOrder)
      {
         bool canPlaceBuyOrder = false;

         // 检查1: 持仓数是否变化(新单成交)
         if(buyCount > g_lastBuyCount)
         {
            canPlaceBuyOrder = true;
            Print("📈 检测到多单数量增加: ", g_lastBuyCount, " → ", buyCount);
            g_lastBuyCount = buyCount;  // 立即更新,防止重复检测
         }
         // 检查2: 首次运行或时间间隔足够(至少30秒,更保守)
         else if(g_lastBuyOrderTime == 0 || TimeCurrent() - g_lastBuyOrderTime >= 30)
         {
            canPlaceBuyOrder = true;
         }

         if(canPlaceBuyOrder)
         {
            g_processingBuyOrder = true;  // 加锁
            ProcessBuyOrders(buyCount, buyLots, sellLots, highestBuyPrice, lowestBuyPrice, totalProfit);
            g_lastBuyOrderTime = TimeCurrent();
            g_lastBuyCount = buyCount;
            g_processingBuyOrder = false;  // 解锁
         }
      }

      //--- 做空逻辑 - 多层防重复保护
      if(g_canTradeSell && sellStopCount == 0 && sellProfit > MaxLoss && !g_processingSellOrder)
      {
         bool canPlaceSellOrder = false;

         // 检查1: 持仓数是否变化(新单成交)
         if(sellCount > g_lastSellCount)
         {
            canPlaceSellOrder = true;
            Print("📉 检测到空单数量增加: ", g_lastSellCount, " → ", sellCount);
            g_lastSellCount = sellCount;  // 立即更新,防止重复检测
         }
         // 检查2: 首次运行或时间间隔足够(至少30秒,更保守)
         else if(g_lastSellOrderTime == 0 || TimeCurrent() - g_lastSellOrderTime >= 30)
         {
            canPlaceSellOrder = true;
         }

         if(canPlaceSellOrder)
         {
            g_processingSellOrder = true;  // 加锁
            ProcessSellOrders(sellCount, buyLots, sellLots, highestSellPrice, lowestSellPrice, totalProfit);
            g_lastSellOrderTime = TimeCurrent();
            g_lastSellCount = sellCount;
            g_processingSellOrder = false;  // 解锁
         }
      }
   }

   //--- 更新界面显示
   UpdateDisplay(buyCount, sellCount, buyLots, sellLots, buyProfit, sellProfit);
}

//+------------------------------------------------------------------+
//| 定时器函数                                                        |
//+------------------------------------------------------------------+
void OnTimer()
{
   // 可在此处添加定时任务
}

//+------------------------------------------------------------------+
//| 统计持仓信息                                                      |
//+------------------------------------------------------------------+
void CountPositions(int &buyCount, int &sellCount,
                    double &buyLots, double &sellLots,
                    double &buyProfit, double &sellProfit,
                    double &highestBuyPrice, double &lowestBuyPrice,
                    double &highestSellPrice, double &lowestSellPrice)
{
   buyCount = 0;
   sellCount = 0;
   buyLots = 0;
   sellLots = 0;
   buyProfit = 0;
   sellProfit = 0;
   highestBuyPrice = 0;
   lowestBuyPrice = 0;
   highestSellPrice = 0;
   lowestSellPrice = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic() != Magic) continue;

      double openPrice = posInfo.PriceOpen();
      double lots = posInfo.Volume();
      double profit = posInfo.Profit() + posInfo.Swap() + posInfo.Commission();

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
      {
         buyCount++;
         buyLots += lots;
         buyProfit += profit;

         if(highestBuyPrice < openPrice || highestBuyPrice == 0)
            highestBuyPrice = openPrice;
         if(lowestBuyPrice > openPrice || lowestBuyPrice == 0)
            lowestBuyPrice = openPrice;
      }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
      {
         sellCount++;
         sellLots += lots;
         sellProfit += profit;

         if(highestSellPrice < openPrice || highestSellPrice == 0)
            highestSellPrice = openPrice;
         if(lowestSellPrice > openPrice || lowestSellPrice == 0)
            lowestSellPrice = openPrice;
      }
   }
}

//+------------------------------------------------------------------+
//| 统计挂单信息                                                      |
//+------------------------------------------------------------------+
void CountPendingOrders(int &buyStopCount, int &sellStopCount)
{
   buyStopCount = 0;
   sellStopCount = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!orderInfo.SelectByIndex(i)) continue;
      if(orderInfo.Symbol() != _Symbol) continue;
      if(orderInfo.Magic() != Magic) continue;

      ENUM_ORDER_TYPE type = orderInfo.Type();
      if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_LIMIT)
         buyStopCount++;
      else if(type == ORDER_TYPE_SELL_STOP || type == ORDER_TYPE_SELL_LIMIT)
         sellStopCount++;
   }
}

//+------------------------------------------------------------------+
//| 检查EA时间过滤                                                    |
//+------------------------------------------------------------------+
bool CheckEATimeFilter()
{
   datetime now = TimeCurrent();

   MqlDateTime dtNow;
   TimeToStruct(now, dtNow);

   string todayStart = StringFormat("%04d.%02d.%02d %s", dtNow.year, dtNow.mon, dtNow.day, EA_StartTime);
   string todayStop = StringFormat("%04d.%02d.%02d %s", dtNow.year, dtNow.mon, dtNow.day, EA_StopTime);

   datetime startTime = StringToTime(todayStart);
   datetime stopTime = StringToTime(todayStop);

   if(startTime < stopTime)
   {
      return (now >= startTime && now <= stopTime);
   }
   else  // 跨日
   {
      return (now >= startTime || now <= stopTime);
   }
}

//+------------------------------------------------------------------+
//| 检查挂单时间过滤                                                  |
//+------------------------------------------------------------------+
bool CheckLimitTimeFilter()
{
   datetime now = TimeCurrent();

   MqlDateTime dtNow;
   TimeToStruct(now, dtNow);

   string todayStart = StringFormat("%04d.%02d.%02d %s", dtNow.year, dtNow.mon, dtNow.day, Limit_StartTime);
   string todayStop = StringFormat("%04d.%02d.%02d %s", dtNow.year, dtNow.mon, dtNow.day, Limit_StopTime);

   datetime startTime = StringToTime(todayStart);
   datetime stopTime = StringToTime(todayStop);

   if(startTime < stopTime)
   {
      return (now >= startTime && now <= stopTime);
   }
   else
   {
      return (now >= startTime || now <= stopTime);
   }
}

//+------------------------------------------------------------------+
//| 检查开仓时间过滤                                                  |
//+------------------------------------------------------------------+
bool CheckOpenTimeFilter()
{
   if(OpenMode == MODE_NEW_BAR)
   {
      datetime currentBarTime = iTime(_Symbol, TimeZone, 0);
      if(g_lastBarTime != currentBarTime)
      {
         g_lastBarTime = currentBarTime;
         return true;
      }
      return false;
   }
   else if(OpenMode == MODE_TIMED)
   {
      if(TimeCurrent() - g_lastOpenTime >= SleepSeconds)
      {
         g_lastOpenTime = TimeCurrent();
         return true;
      }
      return false;
   }
   else  // MODE_ALWAYS
   {
      return true;
   }
}

//+------------------------------------------------------------------+
//| 处理多单逻辑                                                      |
//+------------------------------------------------------------------+
void ProcessBuyOrders(int buyCount, double buyLots, double sellLots,
                      double highestBuyPrice, double lowestBuyPrice, double totalProfit)
{
   if(!CheckLimitTimeFilter()) return;

   double ask = symInfo.Ask();
   double pendingPrice = 0;

   //--- 计算挂单价格
   if(buyCount == 0)
   {
      pendingPrice = NormalizeDouble(ask + FirstStep * g_pointValue, g_digits);
   }
   else
   {
      //--- 判断是否满足Money条件
      bool canAdd = (Money != 0 && totalProfit > Money) || Money == 0;

      if(canAdd)
         pendingPrice = NormalizeDouble(ask + MinDistance * g_pointValue, g_digits);

      if(!canAdd && Money != 0)
         pendingPrice = NormalizeDouble(ask + TwoMinDistance * g_pointValue, g_digits);

      //--- 确保距离足够
      if(pendingPrice < NormalizeDouble(lowestBuyPrice - Step * g_pointValue, g_digits) && canAdd)
         pendingPrice = NormalizeDouble(ask + Step * g_pointValue, g_digits);

      if(pendingPrice < NormalizeDouble(lowestBuyPrice - TwoStep * g_pointValue, g_digits) && !canAdd && Money != 0)
         pendingPrice = NormalizeDouble(ask + TwoStep * g_pointValue, g_digits);
   }

   //--- 价格限制检查
   if(On_top_of_this_price_not_Buy_first_order > 0 && buyCount == 0)
   {
      if(ask >= On_top_of_this_price_not_Buy_first_order) return;
   }

   if(On_top_of_this_price_not_Buy_order > 0 && buyCount > 0)
   {
      if(ask >= On_top_of_this_price_not_Buy_order) return;
   }

   //--- 检查是否需要加仓
   bool needAddOrder = false;
   bool canAdd = (Money != 0 && totalProfit > Money) || Money == 0;

   if(buyCount == 0)
   {
      needAddOrder = true;
   }
   else
   {
      //--- 对冲条件
      bool hedgeCondition = (sellLots > buyLots * 3.0 && sellLots - buyLots > 0.2);

      if(canAdd)
      {
         if((highestBuyPrice != 0 && pendingPrice >= NormalizeDouble(highestBuyPrice + Step * g_pointValue, g_digits) && hedgeCondition) ||
            (lowestBuyPrice != 0 && pendingPrice <= NormalizeDouble(lowestBuyPrice - Step * g_pointValue, g_digits)) ||
            (Homeopathy && highestBuyPrice != 0 && pendingPrice >= NormalizeDouble(highestBuyPrice + Step * g_pointValue, g_digits) && buyLots == sellLots))
         {
            needAddOrder = true;
         }
      }
      else if(Money != 0)
      {
         if((highestBuyPrice != 0 && pendingPrice >= NormalizeDouble(highestBuyPrice + TwoStep * g_pointValue, g_digits) && hedgeCondition) ||
            (lowestBuyPrice != 0 && pendingPrice <= NormalizeDouble(lowestBuyPrice - TwoStep * g_pointValue, g_digits)))
         {
            needAddOrder = true;
         }
      }
   }

   //--- 执行挂单
   if(needAddOrder)
   {
      //--- 检查是否与上次挂单价格相同(防止重复)
      if(MathAbs(pendingPrice - g_lastBuyPendingPrice) < g_pointValue * 5)
      {
         Print("⏭️ 跳过多单挂单: 价格与上次太接近 ", pendingPrice, " ≈ ", g_lastBuyPendingPrice);
         return;
      }

      //--- 计算手数
      double orderLots = lot;
      if(buyCount > 0)
      {
         orderLots = NormalizeDouble(buyCount * PlusLot + lot * MathPow(K_Lot, buyCount), DigitsLot);
      }

      if(orderLots > MaxLot)
         orderLots = MaxLot;

      //--- 标准化手数
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

      orderLots = MathMax(minLot, MathMin(maxLot, orderLots));
      orderLots = NormalizeDouble(MathFloor(orderLots / lotStep) * lotStep, DigitsLot);

      //--- 检查保证金
      if(buyCount > 0 || AccountInfoDouble(ACCOUNT_MARGIN_FREE) > 0)
      {
         double marginRequired = 0;
         if(OrderCalcMargin(ORDER_TYPE_BUY_STOP, _Symbol, orderLots, pendingPrice, marginRequired))
         {
            if(orderLots * 2.0 * marginRequired < AccountInfoDouble(ACCOUNT_MARGIN_FREE) || buyCount == 0)
            {
               //--- 下挂单
               if(trade.BuyStop(orderLots, pendingPrice, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "GoldKylin"))
               {
                  Print("✅ 多单挂单成功: ", orderLots, " lots @ ", pendingPrice, " | 当前多单:", buyCount);
                  g_lastBuyPendingPrice = pendingPrice;  // 记录挂单价格
               }
               else
               {
                  Print("❌ 多单挂单失败: ", trade.ResultRetcodeDescription(), " | Code:", trade.ResultRetcode());
               }
            }
            else
            {
               Print("⚠️ 保证金不足,无法挂多单");
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 处理空单逻辑                                                      |
//+------------------------------------------------------------------+
void ProcessSellOrders(int sellCount, double buyLots, double sellLots,
                       double highestSellPrice, double lowestSellPrice, double totalProfit)
{
   if(!CheckLimitTimeFilter()) return;

   double bid = symInfo.Bid();
   double pendingPrice = 0;

   //--- 计算挂单价格
   if(sellCount == 0)
   {
      pendingPrice = NormalizeDouble(bid - FirstStep * g_pointValue, g_digits);
   }
   else
   {
      bool canAdd = (Money != 0 && totalProfit > Money) || Money == 0;

      if(canAdd)
         pendingPrice = NormalizeDouble(bid - MinDistance * g_pointValue, g_digits);

      if(!canAdd && Money != 0)
         pendingPrice = NormalizeDouble(bid - TwoMinDistance * g_pointValue, g_digits);

      if(pendingPrice < NormalizeDouble(highestSellPrice + Step * g_pointValue, g_digits) && canAdd)
         pendingPrice = NormalizeDouble(bid - Step * g_pointValue, g_digits);

      if(pendingPrice < NormalizeDouble(highestSellPrice + TwoStep * g_pointValue, g_digits) && !canAdd && Money != 0)
         pendingPrice = NormalizeDouble(bid - TwoStep * g_pointValue, g_digits);
   }

   //--- 价格限制检查
   if(On_under_of_this_price_not_Sell_first_order > 0 && sellCount == 0)
   {
      if(bid <= On_under_of_this_price_not_Sell_first_order) return;
   }

   if(On_under_of_this_price_not_Sell_order > 0 && sellCount > 0)
   {
      if(bid <= On_under_of_this_price_not_Sell_order) return;
   }

   //--- 检查是否需要加仓
   bool needAddOrder = false;
   bool canAdd = (Money != 0 && totalProfit > Money) || Money == 0;

   if(sellCount == 0)
   {
      needAddOrder = true;
   }
   else
   {
      bool hedgeCondition = (buyLots > sellLots * 3.0 && buyLots - sellLots > 0.2);

      if(canAdd)
      {
         if((lowestSellPrice != 0 && pendingPrice <= NormalizeDouble(lowestSellPrice - Step * g_pointValue, g_digits) && hedgeCondition) ||
            (highestSellPrice != 0 && pendingPrice >= NormalizeDouble(highestSellPrice + Step * g_pointValue, g_digits)) ||
            (Homeopathy && lowestSellPrice != 0 && pendingPrice <= NormalizeDouble(lowestSellPrice - Step * g_pointValue, g_digits) && buyLots == sellLots))
         {
            needAddOrder = true;
         }
      }
      else if(Money != 0)
      {
         if((lowestSellPrice != 0 && pendingPrice <= NormalizeDouble(lowestSellPrice - TwoStep * g_pointValue, g_digits) && hedgeCondition) ||
            (highestSellPrice != 0 && pendingPrice >= NormalizeDouble(highestSellPrice + TwoStep * g_pointValue, g_digits)))
         {
            needAddOrder = true;
         }
      }
   }

   //--- 执行挂单
   if(needAddOrder)
   {
      //--- 检查是否与上次挂单价格相同(防止重复)
      if(MathAbs(pendingPrice - g_lastSellPendingPrice) < g_pointValue * 5)
      {
         Print("⏭️ 跳过空单挂单: 价格与上次太接近 ", pendingPrice, " ≈ ", g_lastSellPendingPrice);
         return;
      }

      double orderLots = lot;
      if(sellCount > 0)
      {
         orderLots = NormalizeDouble(sellCount * PlusLot + lot * MathPow(K_Lot, sellCount), DigitsLot);
      }

      if(orderLots > MaxLot)
         orderLots = MaxLot;

      //--- 标准化手数
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

      orderLots = MathMax(minLot, MathMin(maxLot, orderLots));
      orderLots = NormalizeDouble(MathFloor(orderLots / lotStep) * lotStep, DigitsLot);

      if(sellCount > 0 || AccountInfoDouble(ACCOUNT_MARGIN_FREE) > 0)
      {
         double marginRequired = 0;
         if(OrderCalcMargin(ORDER_TYPE_SELL_STOP, _Symbol, orderLots, pendingPrice, marginRequired))
         {
            if(orderLots * 2.0 * marginRequired < AccountInfoDouble(ACCOUNT_MARGIN_FREE) || sellCount == 0)
            {
               if(trade.SellStop(orderLots, pendingPrice, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "GoldKylin"))
               {
                  Print("✅ 空单挂单成功: ", orderLots, " lots @ ", pendingPrice, " | 当前空单:", sellCount);
                  g_lastSellPendingPrice = pendingPrice;  // 记录挂单价格
               }
               else
               {
                  Print("❌ 空单挂单失败: ", trade.ResultRetcodeDescription(), " | Code:", trade.ResultRetcode());
               }
            }
            else
            {
               Print("⚠️ 保证金不足,无法挂空单");
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 检查平仓条件                                                      |
//+------------------------------------------------------------------+
void CheckCloseConditions(int buyCount, int sellCount, double buyLots, double sellLots,
                          double buyProfit, double sellProfit, double totalProfit)
{
   //--- 总盈利平仓
   if(Over && totalProfit >= CloseAll)
   {
      CloseAllPositionsByHedge();
      if(NextTime > 0)
         g_expirationTime = TimeCurrent() + NextTime;
      return;
   }

   //--- 对冲平仓(避免单边过大)
   if(!Over)
   {
      if(HomeopathyCloseAll && totalProfit >= CloseAll &&
         (buyProfit <= MaxLossCloseAll || sellProfit <= MaxLossCloseAll))
      {
         CloseAllPositionsByHedge();
         if(NextTime > 0)
            g_expirationTime = TimeCurrent() + NextTime;
         return;
      }

      //--- 单边止盈
      if(buyProfit <= MaxLossCloseAll || sellProfit <= MaxLossCloseAll)
      {
         if(Profit)
         {
            if(buyProfit > StopProfit * buyCount && buyCount > 0)
            {
               Print("多单止盈平仓: ", buyProfit);
               ClosePositionsByType(POSITION_TYPE_BUY);
               return;
            }

            if(sellProfit > StopProfit * sellCount && sellCount > 0)
            {
               Print("空单止盈平仓: ", sellProfit);
               ClosePositionsByType(POSITION_TYPE_SELL);
               return;
            }
         }
         else
         {
            if(buyProfit > StopProfit && buyCount > 0)
            {
               Print("多单止盈平仓: ", buyProfit);
               ClosePositionsByType(POSITION_TYPE_BUY);
               return;
            }

            if(sellProfit > StopProfit && sellCount > 0)
            {
               Print("空单止盈平仓: ", sellProfit);
               ClosePositionsByType(POSITION_TYPE_SELL);
               return;
            }
         }
      }
   }

   //--- 总止损
   if(StopLoss != 0 && totalProfit <= StopLoss)
   {
      Print("总止损触发: Buy=", buyProfit, " Sell=", sellProfit);
      CloseAllPositions();
      if(NextTime > 0)
         g_expirationTime = TimeCurrent() + NextTime;
      return;
   }
}

//+------------------------------------------------------------------+
//| 对冲平仓所有持仓                                                  |
//+------------------------------------------------------------------+
void CloseAllPositionsByHedge()
{
   Print("开始对冲平仓...");

   //--- MQL5中没有OrderCloseBy,需要直接平仓
   CloseAllPositions();
}

//+------------------------------------------------------------------+
//| 平仓所有持仓                                                      |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic() != Magic) continue;

      trade.PositionClose(posInfo.Ticket());
   }

   //--- 删除所有挂单
   DeleteAllPendingOrders();
}

//+------------------------------------------------------------------+
//| 按类型平仓                                                        |
//+------------------------------------------------------------------+
void ClosePositionsByType(ENUM_POSITION_TYPE posType)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic() != Magic) continue;
      if(posInfo.PositionType() != posType) continue;

      trade.PositionClose(posInfo.Ticket());
   }

   //--- 删除相应方向的挂单
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!orderInfo.SelectByIndex(i)) continue;
      if(orderInfo.Symbol() != _Symbol) continue;
      if(orderInfo.Magic() != Magic) continue;

      ENUM_ORDER_TYPE orderType = orderInfo.Type();
      if(posType == POSITION_TYPE_BUY && (orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_BUY_LIMIT))
         trade.OrderDelete(orderInfo.Ticket());
      else if(posType == POSITION_TYPE_SELL && (orderType == ORDER_TYPE_SELL_STOP || orderType == ORDER_TYPE_SELL_LIMIT))
         trade.OrderDelete(orderInfo.Ticket());
   }
}

//+------------------------------------------------------------------+
//| 删除所有挂单                                                      |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!orderInfo.SelectByIndex(i)) continue;
      if(orderInfo.Symbol() != _Symbol) continue;
      if(orderInfo.Magic() != Magic) continue;

      trade.OrderDelete(orderInfo.Ticket());
   }
}

//+------------------------------------------------------------------+
//| 更新显示                                                          |
//+------------------------------------------------------------------+
void UpdateDisplay(int buyCount, int sellCount, double buyLots, double sellLots,
                   double buyProfit, double sellProfit)
{
   string display = "\n========== 金麒麟EA MQL5 ==========\n";
   display += StringFormat("品种: %s | 点差: %d\n", _Symbol, (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
   display += StringFormat("杠杆: %d | 余额: %.2f | 净值: %.2f\n",
                          (int)AccountInfoInteger(ACCOUNT_LEVERAGE),
                          AccountInfoDouble(ACCOUNT_BALANCE),
                          AccountInfoDouble(ACCOUNT_EQUITY));
   display += "-----------------------------------\n";
   display += StringFormat("多单: %d笔 | %.2f手 | $%.2f\n", buyCount, buyLots, buyProfit);
   display += StringFormat("空单: %d笔 | %.2f手 | $%.2f\n", sellCount, sellLots, sellProfit);
   display += StringFormat("总计: %d笔 | %.2f手 | $%.2f\n",
                          buyCount + sellCount,
                          buyLots + sellLots,
                          buyProfit + sellProfit);
   display += "-----------------------------------\n";
   display += StringFormat("允许做多: %s | 允许做空: %s\n",
                          g_canTradeBuy ? "是" : "否",
                          g_canTradeSell ? "是" : "否");
   display += "===================================\n";

   Comment(display);
}
//+------------------------------------------------------------------+
