//+------------------------------------------------------------------+
//|                                          20260608_scalping.mq5   |
//|                             XAU Gold Scalping Strategy (1min)    |
//+------------------------------------------------------------------+
#property copyright "XAU Scalping Strategy"
#property version   "4.00"
#property description "Gold 1min Scalping - High Reward Risk Ratio"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== 基础设置 ==="
input int      InpMagicNumber = 20260608;         // 魔术号
input bool     InpEnableTrading = true;           // 启用自动交易

input group "=== 入场信号 ==="
input int      InpFastMA = 5;                     // 快速均线周期
input int      InpSlowMA = 20;                    // 慢速均线周期
input int      InpRSIPeriod = 14;                 // RSI周期
input double   InpRSIOverbought = 65;             // RSI超买阈值
input double   InpRSIOversold = 35;               // RSI超卖阈值
input int      InpADXPeriod = 14;                 // ADX周期
input double   InpMinADX = 25;                    // 最小ADX(趋势强度)
input int      InpATRPeriod = 14;                 // ATR周期
input double   InpMinATR = 0.1;                   // 最小ATR(波动率过滤)
input int      InpMomentumPeriod = 10;            // 动量周期

input group "=== 止损止盈 ==="
input int      InpStopLossPoints = 30;            // 止损(点)
input int      InpTakeProfitPoints = 60;          // 止盈(点)
input bool     InpUseTrailing = false;            // 启用移动止损
input int      InpTrailingStartPoints = 400;      // 移动止损启动点数
input int      InpTrailingStopPoints = 250;       // 移动止损距离(点)

input group "=== 仓位管理 ==="
input double   InpFixedLots = 0.01;               // 固定手数
input double   InpRiskPercent = 1.0;              // 风险百分比(0=使用固定手数)
input int      InpMaxPositions = 1;               // 最大同时持仓数

input group "=== 时间过滤 ==="
input bool     InpEnableTimeFilter = true;        // 启用时间过滤
input string   InpTradeStartTime = "08:00";       // 交易开始时间
input string   InpTradeEndTime = "22:00";         // 交易结束时间

input group "=== 流动性过滤 ==="
input int      InpMaxSpreadPoints = 100;          // 最大点差(点)
input double   InpMinATRMultiplier = 0.5;         // 最小ATR倍数

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade trade;
int fastMA_handle;
int slowMA_handle;
int rsi_handle;
int adx_handle;
int atr_handle;
int momentum_handle;

datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    fastMA_handle = iMA(_Symbol, PERIOD_M1, InpFastMA, 0, MODE_EMA, PRICE_CLOSE);
    if(fastMA_handle == INVALID_HANDLE) {
        Print("Failed to create Fast MA");
        return INIT_FAILED;
    }

    slowMA_handle = iMA(_Symbol, PERIOD_M1, InpSlowMA, 0, MODE_EMA, PRICE_CLOSE);
    if(slowMA_handle == INVALID_HANDLE) {
        Print("Failed to create Slow MA");
        return INIT_FAILED;
    }

    rsi_handle = iRSI(_Symbol, PERIOD_M1, InpRSIPeriod, PRICE_CLOSE);
    if(rsi_handle == INVALID_HANDLE) {
        Print("Failed to create RSI");
        return INIT_FAILED;
    }

    adx_handle = iADX(_Symbol, PERIOD_M1, InpADXPeriod);
    if(adx_handle == INVALID_HANDLE) {
        Print("Failed to create ADX");
        return INIT_FAILED;
    }

    atr_handle = iATR(_Symbol, PERIOD_M1, InpATRPeriod);
    if(atr_handle == INVALID_HANDLE) {
        Print("Failed to create ATR");
        return INIT_FAILED;
    }

    momentum_handle = iMomentum(_Symbol, PERIOD_M1, InpMomentumPeriod, PRICE_CLOSE);
    if(momentum_handle == INVALID_HANDLE) {
        Print("Failed to create Momentum");
        return INIT_FAILED;
    }

    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetDeviationInPoints(50);
    trade.SetTypeFilling(ORDER_FILLING_FOK);

    Print("========================================");
    Print("XAU Gold Scalping v4.00 - RR 2:1");
    Print("Symbol: ", _Symbol, " | Period: 1min");
    Print("MA: Fast=", InpFastMA, " Slow=", InpSlowMA);
    Print("RSI: ", InpRSIOversold, "-", InpRSIOverbought, " | ADX Min=", InpMinADX);
    Print("SL=", InpStopLossPoints, " pts | TP=", InpTakeProfitPoints, " pts | RR=2:1");
    Print("========================================");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(fastMA_handle != INVALID_HANDLE) IndicatorRelease(fastMA_handle);
    if(slowMA_handle != INVALID_HANDLE) IndicatorRelease(slowMA_handle);
    if(rsi_handle != INVALID_HANDLE) IndicatorRelease(rsi_handle);
    if(adx_handle != INVALID_HANDLE) IndicatorRelease(adx_handle);
    if(atr_handle != INVALID_HANDLE) IndicatorRelease(atr_handle);
    if(momentum_handle != INVALID_HANDLE) IndicatorRelease(momentum_handle);

    Print("XAU Scalping Strategy v4.00 Stopped");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    datetime currentBarTime = iTime(_Symbol, PERIOD_M1, 0);
    bool isNewBar = (currentBarTime != lastBarTime);
    if(isNewBar) {
        lastBarTime = currentBarTime;
    }

    if(!InpEnableTrading) return;

    ManagePositions();

    if(!isNewBar) return;

    if(!PassLiquidityFilter()) return;
    if(!PassTimeFilter()) return;

    int currentPositions = CountOpenPositions();
    if(currentPositions >= InpMaxPositions) return;

    double fastMA[], slowMA[], rsi[], adx[], atr[], momentum[];
    ArraySetAsSeries(fastMA, true);
    ArraySetAsSeries(slowMA, true);
    ArraySetAsSeries(rsi, true);
    ArraySetAsSeries(adx, true);
    ArraySetAsSeries(atr, true);
    ArraySetAsSeries(momentum, true);

    if(CopyBuffer(fastMA_handle, 0, 0, 3, fastMA) != 3) return;
    if(CopyBuffer(slowMA_handle, 0, 0, 3, slowMA) != 3) return;
    if(CopyBuffer(rsi_handle, 0, 0, 3, rsi) != 3) return;
    if(CopyBuffer(adx_handle, 0, 0, 3, adx) != 3) return;
    if(CopyBuffer(atr_handle, 0, 0, 3, atr) != 3) return;
    if(CopyBuffer(momentum_handle, 0, 0, 3, momentum) != 3) return;

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // ATR波动率过滤
    if(atr[0] < InpMinATR) {
        Comment("Low Volatility - ATR=", DoubleToString(atr[0], 2));
        return;
    }

    // ADX趋势强度过滤
    if(adx[0] < InpMinADX) {
        Comment("Weak Trend - ADX=", DoubleToString(adx[0], 1));
        return;
    }

    bool buySignal = false;
    bool sellSignal = false;

    // 买入信号：严格的多重确认
    // 必须同时满足5个条件：
    // 1. EMA快线上穿慢线（金叉）
    // 2. RSI在合理区域（35-65）
    // 3. ADX显示趋势强劲（>25）
    // 4. 动量指标向上（Momentum[0] > 100）
    // 5. 快线有明显加速（FastMA[0] > FastMA[1]）
    if(fastMA[1] <= slowMA[1] && fastMA[0] > slowMA[0]) {
        if(rsi[0] >= InpRSIOversold && rsi[0] <= InpRSIOverbought) {
            if(momentum[0] > 100 && momentum[0] > momentum[1]) {
                if(fastMA[0] > fastMA[1]) {
                    buySignal = true;
                }
            }
        }
    }

    // 卖出信号：严格的多重确认
    // 必须同时满足5个条件：
    // 1. EMA快线下穿慢线（死叉）
    // 2. RSI在合理区域（35-65）
    // 3. ADX显示趋势强劲（>25）
    // 4. 动量指标向下（Momentum[0] < 100）
    // 5. 快线有明显减速（FastMA[0] < FastMA[1]）
    if(fastMA[1] >= slowMA[1] && fastMA[0] < slowMA[0]) {
        if(rsi[0] >= InpRSIOversold && rsi[0] <= InpRSIOverbought) {
            if(momentum[0] < 100 && momentum[0] < momentum[1]) {
                if(fastMA[0] < fastMA[1]) {
                    sellSignal = true;
                }
            }
        }
    }

    if(buySignal) {
        OpenPosition(true, ask);
    } else if(sellSignal) {
        OpenPosition(false, bid);
    }

    string comment = StringFormat(
        "XAU Scalping v4.00 - RR 2:1\n"
        "FastMA: %.2f | SlowMA: %.2f\n"
        "RSI: %.1f | ADX: %.1f | ATR: %.2f\n"
        "Momentum: %.2f\n"
        "SL: %d pts | TP: %d pts\n"
        "Positions: %d/%d | Signal: %s",
        fastMA[0], slowMA[0],
        rsi[0], adx[0], atr[0],
        momentum[0],
        InpStopLossPoints, InpTakeProfitPoints,
        currentPositions, InpMaxPositions,
        buySignal ? "BUY" : (sellSignal ? "SELL" : "WAIT")
    );
    Comment(comment);
}

//+------------------------------------------------------------------+
//| Open Position                                                    |
//+------------------------------------------------------------------+
void OpenPosition(bool isBuy, double price)
{
    double lots = InpFixedLots;

    // 如果启用风险百分比计算
    if(InpRiskPercent > 0) {
        double balance = AccountInfoDouble(ACCOUNT_BALANCE);
        double riskMoney = balance * InpRiskPercent / 100.0;
        double slDistance = InpStopLossPoints * _Point;

        double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

        if(slDistance > 0 && tickSize > 0 && tickValue > 0) {
            double lossPerLot = (slDistance / tickSize) * tickValue;
            if(lossPerLot > 0) {
                lots = riskMoney / lossPerLot;
            }
        }
    }

    // 标准化手数
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lots = MathMax(lots, minLot);
    lots = MathMin(lots, maxLot);
    lots = MathFloor(lots / lotStep) * lotStep;
    lots = NormalizeDouble(lots, 2);

    if(lots <= 0) return;

    double sl = 0, tp = 0;
    double slDistance = InpStopLossPoints * _Point;
    double tpDistance = InpTakeProfitPoints * _Point;

    if(isBuy) {
        sl = NormalizeDouble(price - slDistance, _Digits);
        tp = NormalizeDouble(price + tpDistance, _Digits);

        if(trade.Buy(lots, _Symbol, price, sl, tp, "XAU_BUY_v3")) {
            Print("BUY: Price=", price, " SL=", sl, " TP=", tp, " Lots=", lots);
        } else {
            Print("BUY Failed: ", trade.ResultRetcodeDescription());
        }
    } else {
        sl = NormalizeDouble(price + slDistance, _Digits);
        tp = NormalizeDouble(price - tpDistance, _Digits);

        if(trade.Sell(lots, _Symbol, price, sl, tp, "XAU_SELL_v3")) {
            Print("SELL: Price=", price, " SL=", sl, " TP=", tp, " Lots=", lots);
        } else {
            Print("SELL Failed: ", trade.ResultRetcodeDescription());
        }
    }
}

//+------------------------------------------------------------------+
//| Count Open Positions                                             |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(PositionSelectByTicket(PositionGetTicket(i))) {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
                count++;
            }
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| Manage Positions (Trailing Stop)                                |
//+------------------------------------------------------------------+
void ManagePositions()
{
    if(!InpUseTrailing) return;  // 如果禁用移动止损，直接返回
    if(InpTrailingStartPoints <= 0 || InpTrailingStopPoints <= 0) return;

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(!PositionSelectByTicket(ticket)) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

        ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double currentSL = PositionGetDouble(POSITION_SL);
        double currentTP = PositionGetDouble(POSITION_TP);

        double profit = 0;
        double newSL = 0;

        if(type == POSITION_TYPE_BUY) {
            profit = (bid - openPrice) / _Point;
            if(profit >= InpTrailingStartPoints) {
                newSL = NormalizeDouble(bid - InpTrailingStopPoints * _Point, _Digits);
                if(newSL > currentSL) {
                    if(trade.PositionModify(ticket, newSL, currentTP)) {
                        Print("Trailing Stop (BUY): ", ticket, " NewSL=", newSL);
                    }
                }
            }
        } else if(type == POSITION_TYPE_SELL) {
            profit = (openPrice - ask) / _Point;
            if(profit >= InpTrailingStartPoints) {
                newSL = NormalizeDouble(ask + InpTrailingStopPoints * _Point, _Digits);
                if(newSL < currentSL || currentSL == 0) {
                    if(trade.PositionModify(ticket, newSL, currentTP)) {
                        Print("Trailing Stop (SELL): ", ticket, " NewSL=", newSL);
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Liquidity Filter                                                 |
//+------------------------------------------------------------------+
bool PassLiquidityFilter()
{
    long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    if(spread > InpMaxSpreadPoints) {
        static datetime lastWarn = 0;
        if(TimeCurrent() - lastWarn >= 60) {
            Print("Spread too high: ", spread, " > ", InpMaxSpreadPoints);
            lastWarn = TimeCurrent();
        }
        return false;
    }

    double atr[];
    ArraySetAsSeries(atr, true);
    if(CopyBuffer(atr_handle, 0, 0, 21, atr) == 21) {
        double atrCurrent = atr[0];
        double atrSum = 0;
        for(int i = 1; i <= 20; i++) atrSum += atr[i];
        double atrAvg = atrSum / 20.0;

        if(atrAvg > 0 && atrCurrent / atrAvg < InpMinATRMultiplier) {
            return false;
        }
    }

    return true;
}

//+------------------------------------------------------------------+
//| Time Filter                                                      |
//+------------------------------------------------------------------+
bool PassTimeFilter()
{
    if(!InpEnableTimeFilter) return true;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int currentMinutes = dt.hour * 60 + dt.min;

    string parts[];
    int startHour = 0, startMin = 0;
    if(StringSplit(InpTradeStartTime, ':', parts) == 2) {
        startHour = (int)StringToInteger(parts[0]);
        startMin = (int)StringToInteger(parts[1]);
    }
    int startMinutes = startHour * 60 + startMin;

    int endHour = 0, endMin = 0;
    if(StringSplit(InpTradeEndTime, ':', parts) == 2) {
        endHour = (int)StringToInteger(parts[0]);
        endMin = (int)StringToInteger(parts[1]);
    }
    int endMinutes = endHour * 60 + endMin;

    return (currentMinutes >= startMinutes && currentMinutes <= endMinutes);
}
//+------------------------------------------------------------------+
