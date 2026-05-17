//+------------------------------------------------------------------+
//|                                                20260516_Trade.mq5 |
//|                                      突破交易策略 - 完整交易版本    |
//+------------------------------------------------------------------+
#property copyright "Breakout Strategy"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| 输入参数                                                           |
//+------------------------------------------------------------------+
input group "=== 波段识别参数 ==="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M1; // K线周期
input int      InpMAPeriod = 14;                // MA周期
input double   InpMinWavePercent = 0.1;         // 最小波段阈值百分比(%)
input double   InpMaxWavePercent = 1.0;         // 最大波段阈值百分比(%)
input double   InpPullbackTolerance = 0.0;      // 反向突破容忍度(%) 0=不容忍

input group "=== 风险管理参数 ==="
input double   InpStopLossPercent = 0.02;       // 止损百分比(%)
input int      InpMinStopLossPoints = 10;       // 最小止损点数
input double   InpRiskRewardRatio = 1.2;        // 盈亏比
input bool     InpUseTrailingStop = false;      // 使用移动止损
input int      InpMaxHoldingMinutes = 5;        // 最大持仓时间(分钟)

input group "=== 仓位管理参数 ==="
input bool     InpUseCompounding = true;        // 使用复利模式
input double   InpFixedLots = 0.01;             // 固定手数
input double   InpLotsPer500 = 0.05;            // 每500$开仓手数(复利模式)
input int      InpMaxPositions = 99;            // 最大开仓手数
input bool     InpOnePositionPerDirection = true; // 单方向最多持有一单

input group "=== 连续亏损保护 ==="
input int      InpConsecutiveLosses = 3;        // 连续亏损次数触发冷冻(0=禁用)
input int      InpFreezeBarCount = 60;          // 冷冻K线根数(0=禁用)

input group "=== 调试选项 ==="
input bool     InpShowDebugInfo = false;        // 显示调试信息
input bool     InpShowMarkers = true;           // 显示极值点标记
input int      InpMagicNumber = 20260516;       // EA魔术号

//+------------------------------------------------------------------+
//| 全局变量                                                           |
//+------------------------------------------------------------------+
int ma_handle;                                  // MA指标句柄
CTrade trade;                                   // 交易对象

// 最新有效波段信息
struct ValidWaveInfo {
    bool exists;                                // 是否存在有效波段
    double high_price;                          // 高点价格
    double low_price;                           // 低点价格
    datetime update_time;                       // 更新时间
    bool high_used;                             // 高点是否已使用
    bool low_used;                              // 低点是否已使用
};

ValidWaveInfo latest_wave;                      // 最新有效波段

// 连续亏损保护相关变量
int consecutive_loss_count = 0;                 // 连续亏损计数器
datetime freeze_until_time = 0;                 // 冷冻结束时间(0表示未冷冻)
int freeze_bar_index = 0;                       // 冷冻起始K线索引

// 极值点结构体定义
struct ExtremePoint {
    datetime time;
    double price;
    int type;
    bool is_valid;
};

// 函数声明
void UpdateLatestValidWave();
void DrawExtremeMarkers(ExtremePoint &extremes[]);
void DrawLatestValidWave(double high_price, datetime high_time, double low_price, datetime low_time);
int CheckBreakout(int index, const MqlRates &rates[], const double &ma[]);
void FilterBreakouts(const int &breakout_bars[], const int &breakout_types[],
                    const MqlRates &rates[], int &filtered_bars[], int &filtered_types[]);
void CheckOpenSignals();
bool OpenPosition(ENUM_ORDER_TYPE order_type, double wave_high, double wave_low, double threshold_points);
double CalculateLotSize();
void ManagePositions();
void CheckTrailingStop(ulong ticket);

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // 创建MA指标（使用指定的K线周期）
    ma_handle = iMA(_Symbol, InpTimeframe, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
    if(ma_handle == INVALID_HANDLE) {
        Print("创建MA指标失败");
        return(INIT_FAILED);
    }

    // 设置交易参数
    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetDeviationInPoints(10);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    // 初始化最新有效波段
    latest_wave.exists = false;
    latest_wave.high_price = 0;
    latest_wave.low_price = 0;
    latest_wave.update_time = 0;
    latest_wave.high_used = false;
    latest_wave.low_used = false;

    Print("========================================");
    Print("突破交易策略EA初始化成功");
    Print("品种:", _Symbol);
    Print("K线周期:", EnumToString(InpTimeframe));
    Print("MA周期:", InpMAPeriod);
    Print("波段阈值范围: ", InpMinWavePercent, "% - ", InpMaxWavePercent, "%");
    if(InpPullbackTolerance > 0)
        Print("反向突破容忍度: ", DoubleToString(InpPullbackTolerance, 1), "% (启用)");
    else
        Print("反向突破容忍度: 0% (禁用 - 保持原有逻辑)");
    Print("止损:", InpStopLossPercent, "% (最小", InpMinStopLossPoints, "点) | 盈亏比:", InpRiskRewardRatio);
    Print("移动止损:", (InpUseTrailingStop ? "启用" : "禁用"));
    Print("最大持仓时间:", InpMaxHoldingMinutes, "分钟");
    Print("最大开仓手数:", InpMaxPositions);
    Print("单方向持仓限制:", (InpOnePositionPerDirection ? "启用 (每方向最多1单)" : "禁用"));
    if(InpConsecutiveLosses > 0 && InpFreezeBarCount > 0)
        Print("连续亏损保护: 启用 (", InpConsecutiveLosses, "次亏损→冷冻", InpFreezeBarCount, "根K线)");
    else
        Print("连续亏损保护: 禁用");
    Print("手数模式:", (InpUseCompounding ? "复利" : "固定"),
          InpUseCompounding ? StringFormat(" (每500$开%.2f手)", InpLotsPer500) : StringFormat(" (%.2f手)", InpFixedLots));
    Print("========================================");

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(ma_handle != INVALID_HANDLE)
        IndicatorRelease(ma_handle);

    // 删除所有标记
    ObjectsDeleteAll(0, "ValidWave_");

    Print("突破交易策略EA已卸载");
}

//+------------------------------------------------------------------+
//| 交易事务处理函数 - 用于检测亏损单                                    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
    // 只在功能启用时处理
    if(InpConsecutiveLosses <= 0 || InpFreezeBarCount <= 0)
        return;

    // 只处理订单成交事件
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
        return;

    // 需要先选择历史记录
    if(!HistorySelect(0, TimeCurrent()))
        return;

    // 获取最新的Deal
    int total_deals = HistoryDealsTotal();
    if(total_deals <= 0)
        return;

    ulong deal_ticket = HistoryDealGetTicket(total_deals - 1);
    if(deal_ticket == 0)
        return;

    // 检查魔术号
    long deal_magic = HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);
    if(deal_magic != InpMagicNumber)
        return;

    // 检查是否是平仓交易
    ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
    if(entry != DEAL_ENTRY_OUT)
        return;

    // 获取交易详情
    double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
    double commission = HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);
    double swap = HistoryDealGetDouble(deal_ticket, DEAL_SWAP);
    double net_profit = profit + commission + swap;

    // 判断是亏损还是盈利
    if(net_profit < 0)
    {
        // 亏损：增加计数器
        consecutive_loss_count++;
        Print("【连续亏损保护】亏损 ", consecutive_loss_count, "/", InpConsecutiveLosses,
              " | 净亏损: $", DoubleToString(net_profit, 2));

        // 检查是否达到冷冻阈值
        if(consecutive_loss_count >= InpConsecutiveLosses)
        {
            // 进入冷冻期
            freeze_bar_index = Bars(_Symbol, InpTimeframe) + InpFreezeBarCount;
            freeze_until_time = TimeCurrent();

            Print("!!! 触发交易冷冻 !!! 冷冻", InpFreezeBarCount, "根K线");
        }
    }
    else if(net_profit > 0)
    {
        // 盈利：重置计数器
        if(consecutive_loss_count > 0)
        {
            Print("【连续亏损保护】盈利 - 计数器重置: ", consecutive_loss_count, " → 0 | 净盈利: $", DoubleToString(net_profit, 2));
            consecutive_loss_count = 0;
        }
    }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // 1. 更新最新有效波段
    UpdateLatestValidWave();

    // 2. 检查开仓信号
    CheckOpenSignals();

    // 3. 管理已有持仓
    ManagePositions();
}

//+------------------------------------------------------------------+
//| 更新最新有效波段                                                   |
//+------------------------------------------------------------------+
void UpdateLatestValidWave()
{
    int bars = Bars(_Symbol, InpTimeframe);
    if(bars < InpMAPeriod + 2)
        return;

    // 限制处理的K线数量
    int process_bars = MathMin(bars, 500);

    // 获取价格数据（使用指定的K线周期）
    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    if(CopyRates(_Symbol, InpTimeframe, 0, process_bars, rates) <= 0)
        return;

    // 获取MA数据
    double ma_array[];
    ArraySetAsSeries(ma_array, true);
    if(CopyBuffer(ma_handle, 0, 0, process_bars, ma_array) <= 0)
        return;

    // 识别突破K线
    int breakout_bars[];
    int breakout_types[];
    ArrayResize(breakout_bars, 0);
    ArrayResize(breakout_types, 0);

    for(int i = process_bars - InpMAPeriod - 1; i >= 1; i--) {
        int breakout_type = CheckBreakout(i, rates, ma_array);
        if(breakout_type != 0) {
            int size = ArraySize(breakout_bars);
            ArrayResize(breakout_bars, size + 1);
            ArrayResize(breakout_types, size + 1);
            breakout_bars[size] = i;
            breakout_types[size] = breakout_type;
        }
    }

    // 过滤连续同向突破
    int filtered_bars[];
    int filtered_types[];
    FilterBreakouts(breakout_bars, breakout_types, rates, filtered_bars, filtered_types);

    // 计算极值点（支持反向突破容忍度）
    ExtremePoint extremes[];
    ArrayResize(extremes, 0);

    // 如果容忍度为0，使用原有逻辑（相邻突破K线之间的极值）
    if(InpPullbackTolerance <= 0.0)
    {
        for(int i = 0; i < ArraySize(filtered_bars) - 1; i++) {
            int current_bar = filtered_bars[i];
            int current_type = filtered_types[i];
            int next_bar = filtered_bars[i + 1];

            double extreme_price = 0;
            datetime extreme_time = 0;

            if(current_type == 1) {
                extreme_price = rates[current_bar].high;
                extreme_time = rates[current_bar].time;
                for(int j = current_bar; j >= next_bar; j--) {
                    if(rates[j].high > extreme_price) {
                        extreme_price = rates[j].high;
                        extreme_time = rates[j].time;
                    }
                }
            } else {
                extreme_price = rates[current_bar].low;
                extreme_time = rates[current_bar].time;
                for(int j = current_bar; j >= next_bar; j--) {
                    if(rates[j].low < extreme_price) {
                        extreme_price = rates[j].low;
                        extreme_time = rates[j].time;
                    }
                }
            }

            int size = ArraySize(extremes);
            ArrayResize(extremes, size + 1);
            extremes[size].time = extreme_time;
            extremes[size].price = extreme_price;
            extremes[size].type = current_type;
            extremes[size].is_valid = false;
        }
    }
    else
    {
        // 容忍模式：跨越反向突破K线计算波段
        for(int i = 0; i < ArraySize(filtered_bars); i++) {
            int start_bar = filtered_bars[i];
            int start_type = filtered_types[i];

            double wave_high = rates[start_bar].high;
            double wave_low = rates[start_bar].low;
            datetime wave_high_time = rates[start_bar].time;
            datetime wave_low_time = rates[start_bar].time;
            int end_bar = 0;
            bool wave_terminated = false;

            // 向后扫描，直到遇到不可容忍的反向突破
            for(int j = i + 1; j < ArraySize(filtered_bars); j++) {
                int current_bar = filtered_bars[j];
                int current_type = filtered_types[j];

                // 更新波段的高低点
                if(rates[current_bar].high > wave_high) {
                    wave_high = rates[current_bar].high;
                    wave_high_time = rates[current_bar].time;
                }
                if(rates[current_bar].low < wave_low) {
                    wave_low = rates[current_bar].low;
                    wave_low_time = rates[current_bar].time;
                }

                // 检查中间所有K线的极值
                int prev_bar = (j > 0) ? filtered_bars[j-1] : start_bar;
                for(int k = prev_bar; k >= current_bar; k--) {
                    if(rates[k].high > wave_high) {
                        wave_high = rates[k].high;
                        wave_high_time = rates[k].time;
                    }
                    if(rates[k].low < wave_low) {
                        wave_low = rates[k].low;
                        wave_low_time = rates[k].time;
                    }
                }

                // 如果遇到反向突破K线，检查回撤是否可容忍
                if(current_type != start_type) {
                    double wave_range = wave_high - wave_low;
                    double pullback_percent = 0;

                    if(start_type == 1) {
                        // 多头波段遇到空单突破K线
                        pullback_percent = ((wave_high - rates[current_bar].close) / wave_range) * 100.0;
                    } else {
                        // 空头波段遇到多单突破K线
                        pullback_percent = ((rates[current_bar].close - wave_low) / wave_range) * 100.0;
                    }

                    if(pullback_percent > InpPullbackTolerance) {
                        // 回撤超过容忍度，终止波段
                        end_bar = current_bar;
                        wave_terminated = true;
                        break;
                    }
                    // 否则继续，忽略此反向突破
                }
            }

            // 添加极值点
            if(start_type == 1) {
                // 多头波段：先低点后高点
                int size = ArraySize(extremes);
                ArrayResize(extremes, size + 1);
                extremes[size].time = wave_low_time;
                extremes[size].price = wave_low;
                extremes[size].type = -1;  // 低点
                extremes[size].is_valid = false;

                ArrayResize(extremes, size + 2);
                extremes[size + 1].time = wave_high_time;
                extremes[size + 1].price = wave_high;
                extremes[size + 1].type = 1;  // 高点
                extremes[size + 1].is_valid = false;
            } else {
                // 空头波段：先高点后低点
                int size = ArraySize(extremes);
                ArrayResize(extremes, size + 1);
                extremes[size].time = wave_high_time;
                extremes[size].price = wave_high;
                extremes[size].type = 1;  // 高点
                extremes[size].is_valid = false;

                ArrayResize(extremes, size + 2);
                extremes[size + 1].time = wave_low_time;
                extremes[size + 1].price = wave_low;
                extremes[size + 1].type = -1;  // 低点
                extremes[size + 1].is_valid = false;
            }

            // 如果波段被终止，跳到终止点继续
            if(wave_terminated) {
                // 找到end_bar在filtered_bars中的索引
                for(int k = i + 1; k < ArraySize(filtered_bars); k++) {
                    if(filtered_bars[k] == end_bar) {
                        i = k - 1;  // -1因为循环会++
                        break;
                    }
                }
            } else {
                // 波段延续到最后
                break;
            }
        }
    }

    // 判断有效波段并标记
    for(int i = 1; i < ArraySize(extremes); i++) {
        double price_diff = MathAbs(extremes[i].price - extremes[i-1].price);
        double price_diff_points = price_diff / _Point;

        // 计算阈值（百分比模式：以前一个极值点价格为基准计算百分比）
        double base_price = extremes[i-1].price;
        double min_threshold = (base_price * InpMinWavePercent / 100.0) / _Point;
        double max_threshold = (base_price * InpMaxWavePercent / 100.0) / _Point;

        // 波段必须在最小和最大阈值之间才是有效波段
        if(price_diff_points >= min_threshold && price_diff_points <= max_threshold) {
            extremes[i-1].is_valid = true;
            extremes[i].is_valid = true;
        }
    }

    // 绘制所有极值点标记
    if(InpShowMarkers) {
        DrawExtremeMarkers(extremes);
    }

    // 查找最新的有效波段
    for(int i = ArraySize(extremes) - 1; i >= 1; i--) {
        double price_diff = MathAbs(extremes[i].price - extremes[i-1].price);
        double price_diff_points = price_diff / _Point;

        // 计算阈值（百分比模式）
        double base_price = extremes[i-1].price;
        double min_threshold = (base_price * InpMinWavePercent / 100.0) / _Point;
        double max_threshold = (base_price * InpMaxWavePercent / 100.0) / _Point;

        // 波段必须在最小和最大阈值之间才是有效波段
        if(price_diff_points >= min_threshold && price_diff_points <= max_threshold) {
            // 找到最新的有效波段
            double high = MathMax(extremes[i].price, extremes[i-1].price);
            double low = MathMin(extremes[i].price, extremes[i-1].price);
            datetime high_time = (extremes[i].price > extremes[i-1].price) ? extremes[i].time : extremes[i-1].time;
            datetime low_time = (extremes[i].price < extremes[i-1].price) ? extremes[i].time : extremes[i-1].time;

            // 检查是否是新的波段
            if(latest_wave.exists == false ||
               extremes[i].time > latest_wave.update_time ||
               high != latest_wave.high_price ||
               low != latest_wave.low_price) {

                latest_wave.exists = true;
                latest_wave.high_price = high;
                latest_wave.low_price = low;
                latest_wave.update_time = extremes[i].time;
                latest_wave.high_used = false;  // 新波段，重置使用状态
                latest_wave.low_used = false;

                // 绘制最新有效波段
                if(InpShowMarkers) {
                    DrawLatestValidWave(high, high_time, low, low_time);
                }

                if(InpShowDebugInfo) {
                    Print("更新最新有效波段 - 高:", DoubleToString(high, _Digits),
                          " 低:", DoubleToString(low, _Digits),
                          " 价差:", (int)price_diff_points, "点",
                          " 阈值范围:", StringFormat("%.2f%%-%.2f%% (%.0f-%.0f点)",
                                InpMinWavePercent, InpMaxWavePercent, min_threshold, max_threshold));
                }
            }
            break;
        }
    }
}

//+------------------------------------------------------------------+
//| 绘制所有极值点标记                                                 |
//+------------------------------------------------------------------+
void DrawExtremeMarkers(ExtremePoint &extremes[])
{
    // 删除旧的标记
    ObjectsDeleteAll(0, "ValidWave_Extreme_");

    for(int i = 0; i < ArraySize(extremes); i++) {
        string obj_name = "ValidWave_Extreme_" + IntegerToString(i);

        if(extremes[i].type == 1) {
            // 高点 - 画下箭头
            ObjectCreate(0, obj_name, OBJ_ARROW, 0, extremes[i].time, extremes[i].price);
            ObjectSetInteger(0, obj_name, OBJPROP_ARROWCODE, 234);
            ObjectSetInteger(0, obj_name, OBJPROP_COLOR, extremes[i].is_valid ? clrRed : clrDarkRed);
            ObjectSetInteger(0, obj_name, OBJPROP_WIDTH, extremes[i].is_valid ? 3 : 1);
            ObjectSetInteger(0, obj_name, OBJPROP_ANCHOR, ANCHOR_BOTTOM);
        } else {
            // 低点 - 画上箭头
            ObjectCreate(0, obj_name, OBJ_ARROW, 0, extremes[i].time, extremes[i].price);
            ObjectSetInteger(0, obj_name, OBJPROP_ARROWCODE, 233);
            ObjectSetInteger(0, obj_name, OBJPROP_COLOR, extremes[i].is_valid ? clrLime : clrDarkGreen);
            ObjectSetInteger(0, obj_name, OBJPROP_WIDTH, extremes[i].is_valid ? 3 : 1);
            ObjectSetInteger(0, obj_name, OBJPROP_ANCHOR, ANCHOR_TOP);
        }
    }
}

//+------------------------------------------------------------------+
//| 绘制最新有效波段                                                   |
//+------------------------------------------------------------------+
void DrawLatestValidWave(double high_price, datetime high_time, double low_price, datetime low_time)
{
    // 删除旧的最新波段标记
    ObjectDelete(0, "ValidWave_Latest_High");
    ObjectDelete(0, "ValidWave_Latest_Low");
    ObjectDelete(0, "ValidWave_Latest_Line");

    // 标记最新有效波段的高点（更大更亮的箭头）
    ObjectCreate(0, "ValidWave_Latest_High", OBJ_ARROW, 0, high_time, high_price);
    ObjectSetInteger(0, "ValidWave_Latest_High", OBJPROP_ARROWCODE, 234);
    ObjectSetInteger(0, "ValidWave_Latest_High", OBJPROP_COLOR, clrYellow);
    ObjectSetInteger(0, "ValidWave_Latest_High", OBJPROP_WIDTH, 4);
    ObjectSetInteger(0, "ValidWave_Latest_High", OBJPROP_ANCHOR, ANCHOR_BOTTOM);

    // 标记最新有效波段的低点
    ObjectCreate(0, "ValidWave_Latest_Low", OBJ_ARROW, 0, low_time, low_price);
    ObjectSetInteger(0, "ValidWave_Latest_Low", OBJPROP_ARROWCODE, 233);
    ObjectSetInteger(0, "ValidWave_Latest_Low", OBJPROP_COLOR, clrYellow);
    ObjectSetInteger(0, "ValidWave_Latest_Low", OBJPROP_WIDTH, 4);
    ObjectSetInteger(0, "ValidWave_Latest_Low", OBJPROP_ANCHOR, ANCHOR_TOP);

    // 绘制连接线
    ObjectCreate(0, "ValidWave_Latest_Line", OBJ_TREND, 0, high_time, high_price, low_time, low_price);
    ObjectSetInteger(0, "ValidWave_Latest_Line", OBJPROP_COLOR, clrYellow);
    ObjectSetInteger(0, "ValidWave_Latest_Line", OBJPROP_WIDTH, 2);
    ObjectSetInteger(0, "ValidWave_Latest_Line", OBJPROP_STYLE, STYLE_SOLID);
    ObjectSetInteger(0, "ValidWave_Latest_Line", OBJPROP_RAY_RIGHT, false);
    ObjectSetInteger(0, "ValidWave_Latest_Line", OBJPROP_BACK, true);
}

//+------------------------------------------------------------------+
//| 检查是否是突破K线                                                  |
//+------------------------------------------------------------------+
int CheckBreakout(int index, const MqlRates &rates[], const double &ma[])
{
    if(rates[index].open < ma[index] && rates[index].close > ma[index])
        return 1;
    if(rates[index].open > ma[index] && rates[index].close < ma[index])
        return -1;
    return 0;
}

//+------------------------------------------------------------------+
//| 过滤连续同向突破                                                   |
//+------------------------------------------------------------------+
void FilterBreakouts(const int &breakout_bars[], const int &breakout_types[],
                    const MqlRates &rates[], int &filtered_bars[], int &filtered_types[])
{
    int total = ArraySize(breakout_bars);
    ArrayResize(filtered_bars, 0);
    ArrayResize(filtered_types, 0);

    for(int i = 0; i < total; i++) {
        int current_bar = breakout_bars[i];
        int current_type = breakout_types[i];

        bool skip = false;
        for(int j = i + 1; j < total; j++) {
            if(breakout_types[j] != current_type)
                break;

            if(current_type == 1) {
                if(rates[breakout_bars[j]].low < rates[current_bar].low) {
                    skip = true;
                    break;
                }
            } else {
                if(rates[breakout_bars[j]].high > rates[current_bar].high) {
                    skip = true;
                    break;
                }
            }
        }

        if(!skip) {
            int size = ArraySize(filtered_bars);
            ArrayResize(filtered_bars, size + 1);
            ArrayResize(filtered_types, size + 1);
            filtered_bars[size] = current_bar;
            filtered_types[size] = current_type;
        }
    }
}

//+------------------------------------------------------------------+
//| 检查开仓信号                                                       |
//+------------------------------------------------------------------+
void CheckOpenSignals()
{
    if(!latest_wave.exists)
        return;

    // 检查是否处于冷冻期
    if(InpConsecutiveLosses > 0 && InpFreezeBarCount > 0 && freeze_bar_index > 0)
    {
        int current_bars = Bars(_Symbol, InpTimeframe);
        if(current_bars < freeze_bar_index)
        {
            // 仍在冷冻期内 - 静默拒绝开仓
            return;
        }
        else
        {
            // 冷冻期结束
            if(freeze_bar_index > 0)
            {
                Print("【连续亏损保护】冷冻解除，恢复交易");
                consecutive_loss_count = 0;
                freeze_bar_index = 0;
                freeze_until_time = 0;
            }
        }
    }

    // 检查当前持仓数量和方向
    int total_positions = 0;
    int buy_positions = 0;   // 多单数量
    int sell_positions = 0;  // 空单数量

    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(!PositionSelectByTicket(PositionGetTicket(i)))
            continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;

        total_positions++;

        // 统计各方向持仓数量
        ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        if(pos_type == POSITION_TYPE_BUY)
            buy_positions++;
        else if(pos_type == POSITION_TYPE_SELL)
            sell_positions++;
    }

    if(total_positions >= InpMaxPositions) {
        if(InpShowDebugInfo)
            Print("已达最大持仓数量限制: ", total_positions, "/", InpMaxPositions);
        return;
    }

    double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // 计算当前波段的实际阈值（百分比模式：取高低点的平均值作为基准）
    double base_price = (latest_wave.high_price + latest_wave.low_price) / 2.0;
    double wave_threshold_points = (base_price * InpMinWavePercent / 100.0) / _Point;

    // 检查多单信号：突破高点（且该高点未使用过）
    if(!latest_wave.high_used && current_price > latest_wave.high_price) {
        // 如果启用了单方向持仓限制，检查多单数量
        if(InpOnePositionPerDirection && buy_positions >= 1) {
            if(InpShowDebugInfo)
                Print("多单信号被忽略 - 已有多单持仓: ", buy_positions);
        } else {
            if(InpShowDebugInfo)
                Print("检测到多单信号 - 价格:", current_price, " 突破高点:", latest_wave.high_price);

            if(OpenPosition(ORDER_TYPE_BUY, latest_wave.high_price, latest_wave.low_price, wave_threshold_points)) {
                latest_wave.high_used = true;  // 标记高点已使用，该波段高点失效
                if(InpShowDebugInfo)
                    Print("高点已使用，等待新的有效波段");
            }
        }
    }

    // 检查空单信号：突破低点（且该低点未使用过）
    if(!latest_wave.low_used && current_price < latest_wave.low_price) {
        // 如果启用了单方向持仓限制，检查空单数量
        if(InpOnePositionPerDirection && sell_positions >= 1) {
            if(InpShowDebugInfo)
                Print("空单信号被忽略 - 已有空单持仓: ", sell_positions);
        } else {
            if(InpShowDebugInfo)
                Print("检测到空单信号 - 价格:", current_price, " 突破低点:", latest_wave.low_price);

            if(OpenPosition(ORDER_TYPE_SELL, latest_wave.high_price, latest_wave.low_price, wave_threshold_points)) {
                latest_wave.low_used = true;  // 标记低点已使用，该波段低点失效
                if(InpShowDebugInfo)
                    Print("低点已使用，等待新的有效波段");
            }
        }
    }
}

//+------------------------------------------------------------------+
//| 开仓                                                               |
//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE order_type, double wave_high, double wave_low, double threshold_points)
{
    double lots = CalculateLotSize();
    if(lots <= 0)
        return false;

    double current_price = (order_type == ORDER_TYPE_BUY) ?
                          SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
                          SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // 计算止损和止盈（基于开仓价的百分比）
    double stop_loss_amount = current_price * InpStopLossPercent / 100.0;

    // 确保止损金额不小于最小止损点数
    double min_stop_loss = InpMinStopLossPoints * _Point;
    if(stop_loss_amount < min_stop_loss) {
        stop_loss_amount = min_stop_loss;
    }

    double take_profit_amount = stop_loss_amount * InpRiskRewardRatio;

    double sl = 0, tp = 0;
    bool result = false;

    // 生成包含有效波段信息的注释
    string comment = StringFormat("%s H%.0f L%.0f T%.0f",
                                 (order_type == ORDER_TYPE_BUY ? "B" : "S"),
                                 wave_high,
                                 wave_low,
                                 threshold_points);

    if(order_type == ORDER_TYPE_BUY) {
        sl = current_price - stop_loss_amount;
        tp = current_price + take_profit_amount;

        result = trade.Buy(lots, _Symbol, 0, sl, tp, comment);
        if(result) {
            Print("开多单成功 - 手数:", lots,
                  " 波段:H:", wave_high, " L:", wave_low,
                  " 开仓价:", current_price,
                  " 止损:", sl, "(", InpStopLossPercent, "%)",
                  " 止盈:", tp, "(盈亏比", InpRiskRewardRatio, ")");
        }
    } else {
        sl = current_price + stop_loss_amount;
        tp = current_price - take_profit_amount;

        result = trade.Sell(lots, _Symbol, 0, sl, tp, comment);
        if(result) {
            Print("开空单成功 - 手数:", lots,
                  " 波段:H:", wave_high, " L:", wave_low,
                  " 开仓价:", current_price,
                  " 止损:", sl, "(", InpStopLossPercent, "%)",
                  " 止盈:", tp, "(盈亏比", InpRiskRewardRatio, ")");
        }
    }

    return result;
}

//+------------------------------------------------------------------+
//| 计算开仓手数                                                       |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
    double lots = 0;

    if(InpUseCompounding) {
        // 复利模式
        double balance = AccountInfoDouble(ACCOUNT_BALANCE);
        lots = NormalizeDouble((balance / 500.0) * InpLotsPer500, 2);
    } else {
        // 固定手数模式
        lots = InpFixedLots;
    }

    // 检查手数限制
    double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    if(lots < min_lot) lots = min_lot;
    if(lots > max_lot) lots = max_lot;

    lots = MathFloor(lots / lot_step) * lot_step;

    return lots;
}

//+------------------------------------------------------------------+
//| 管理持仓                                                           |
//+------------------------------------------------------------------+
void ManagePositions()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(!PositionSelectByTicket(PositionGetTicket(i)))
            continue;

        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;

        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;

        // 检查最大持仓时间
        datetime open_time = (datetime)PositionGetInteger(POSITION_TIME);
        int holding_minutes = (int)((TimeCurrent() - open_time) / 60);

        if(holding_minutes >= InpMaxHoldingMinutes) {
            ulong ticket = PositionGetTicket(i);
            trade.PositionClose(ticket);
            Print("持仓时间超限，平仓 - Ticket:", ticket, " 持仓时长:", holding_minutes, "分钟");
            continue;
        }

        // 检查移动止损
        ulong ticket = PositionGetTicket(i);
        CheckTrailingStop(ticket);
    }
}

//+------------------------------------------------------------------+
//| 检查移动止损                                                       |
//+------------------------------------------------------------------+
void CheckTrailingStop(ulong ticket)
{
    // 如果未开启移动止损，直接返回
    if(!InpUseTrailingStop)
        return;

    if(!PositionSelectByTicket(ticket))
        return;

    double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
    double current_sl = PositionGetDouble(POSITION_SL);
    ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double current_price = (pos_type == POSITION_TYPE_BUY) ?
                           SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                           SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    // 计算止损金额（开仓价的百分比）
    double stop_loss_amount = open_price * InpStopLossPercent / 100.0;

    // 确保止损金额不小于最小止损点数
    double min_stop_loss = InpMinStopLossPoints * _Point;
    if(stop_loss_amount < min_stop_loss) {
        stop_loss_amount = min_stop_loss;
    }

    // 计算浮盈
    double profit_amount = 0;
    if(pos_type == POSITION_TYPE_BUY) {
        profit_amount = current_price - open_price;
    } else {
        profit_amount = open_price - current_price;
    }

    // 浮盈达到止损金额，移动止损至成本价
    if(profit_amount >= stop_loss_amount) {
        double new_sl = open_price;

        // 检查是否需要更新
        bool need_update = false;
        if(pos_type == POSITION_TYPE_BUY && (current_sl < new_sl || current_sl == 0)) {
            need_update = true;
        } else if(pos_type == POSITION_TYPE_SELL && (current_sl > new_sl || current_sl == 0)) {
            need_update = true;
        }

        if(need_update) {
            double tp = PositionGetDouble(POSITION_TP);
            if(trade.PositionModify(ticket, new_sl, tp)) {
                Print("移动止损至成本价 - Ticket:", ticket, " 新止损:", new_sl);
            }
        }
    }
}
