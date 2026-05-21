//+------------------------------------------------------------------+
//|                                           20260520_Breakout.mq5 |
//|                                      突破策略 - 单笔突破开仓        |
//+------------------------------------------------------------------+
#property copyright "Breakout Strategy"
#property version   "3.07"
#property strict

#include <Trade\Trade.mqh>

// 破高/破低开仓方向
enum ENUM_BREAKOUT_DIRECTION {
    BREAKOUT_DIR_FOLLOW = 0,  // 顺势(破高多/破低空)
    BREAKOUT_DIR_REVERSE = 1, // 反向(破高空/破低多)
    BREAKOUT_DIR_RANDOM = 2   // 随机(每次突破独立随机)
};

// 当前轮多空同向均达满档后的处理
enum ENUM_DUAL_FULL_ACTION {
    DUAL_FULL_CLEAR_ALL = 0,   // 清仓(平掉全部EA持仓)
    DUAL_FULL_NEW_ROUND = 1    // 不处理旧仓,开始下一轮
};

//+------------------------------------------------------------------+
//| 输入参数                                                           |
//+------------------------------------------------------------------+
input group "=== 波段识别参数 ==="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M1; // K线周期
input int      InpMAPeriod = 14;                // MA周期
input double   InpMinWavePercent = 0.1;         // 最小波段阈值百分比(%)
input double   InpMaxWavePercent = 1.0;         // 最大波段阈值百分比(%)
input double   InpPullbackTolerance = 0.05;     // 反向突破容忍度(%) 0=不容忍

input group "=== 突破交易参数 ==="
input ENUM_BREAKOUT_DIRECTION InpBreakoutDirection = BREAKOUT_DIR_FOLLOW; // 开仓方向
input double   InpTakeProfitBalancePct = 1.0;   // 止盈:持仓浮盈达结余比例(%)全部清仓,0=关
input double   InpStopLossBalancePct = 30.0;    // 止损:持仓浮亏达结余比例(%)全部清仓,0=关

input group "=== 仓位管理参数 ==="
input double   InpFixedLots = 0.5;            // 基准手数(同向首笔/每组首笔)
input double   InpMartingaleAddLotBoost = 2.0;  // 同向加码:每组+手数(0=始终基准)
input int      InpMartingaleTierInterval = 5;   // 同向加码:档间隔N(每N笔为一组)
input double   InpMaxLots = 30.0;             // 同向最大合计手数
input double   InpMinSameDirAddSpacingPercent = 0.1; // 同向最小开仓间距(%) 0=不限制
input ENUM_DUAL_FULL_ACTION InpDualFullAction = DUAL_FULL_CLEAR_ALL; // 双向满档后处理

input group "=== 调试选项 ==="
input bool     InpShowDebugInfo = false;        // 显示调试信息
input bool     InpShowMarkers = true;           // 显示极值点标记
input int      InpMagicNumber = 20260520;       // EA魔术号
input bool     InpCloseManualOrders = true;     // 禁止手工单(自动平掉)

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
    bool high_breakout_used;                    // 高点-突破开仓已用(每极值限1次)
    bool low_breakout_used;                     // 低点-突破开仓已用(每极值限1次)
};

ValidWaveInfo latest_wave;                      // 最新有效波段

datetime g_breakout_bar_time_high = 0;          // 破高:同K线限1笔
bool g_breakout_opened_on_bar_high = false;
datetime g_breakout_bar_time_low = 0;           // 破低:同K线限1笔
bool g_breakout_opened_on_bar_low = false;

int g_trade_round = 1;                          // 当前交易轮次(新轮仅统计该轮持仓)
bool g_dual_full_handled = false;               // 本轮双向满档是否已处理

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
ENUM_ORDER_TYPE RandomBreakoutOrderType();
int ParseRoundFromComment(const string &comment);
bool IsEaBreakoutComment(const string &comment);
string FormatBreakoutComment(const int round);
int CountBreakoutPositions(const long pos_type_filter = -1);
int CountAllBreakoutPositions();
double TotalLotsInDirection(const long pos_type);
bool IsDirectionFullActive(const long pos_type);
void ResetBreakoutWaveEntryFlags();
void CheckDualSideFullCapacity();
double NormalizeVolume(double lots);
double LotForSameDirectionTier(const int tier_index, const double base_lot);
double CalculateLotSize(const long pos_type);
long PosTypeOnHighBreakout();
long PosTypeOnLowBreakout();
void CheckBreakoutSignals();
ENUM_ORDER_TYPE OrderTypeOnHighBreakout();
ENUM_ORDER_TYPE OrderTypeOnLowBreakout();
void CheckAndCloseManualOrders();
double TotalBreakoutFloatingPL();
bool CloseAllBreakoutPositions(const string reason);
void CheckBreakoutBalanceExit();
bool OpenBreakoutPosition(ENUM_ORDER_TYPE order_type, double wave_high, double wave_low,
                          const bool from_high_extreme);
void SyncBreakoutBarLock(const bool for_high_extreme);
bool IsBreakoutBarOpenAllowed(const bool for_high_extreme);
void MarkBreakoutBarOpened(const bool for_high_extreme);
bool GetLastSameDirectionOpenPrice(const long pos_type, double &last_open);
bool IsSameDirMinSpacingSatisfied(const long pos_type);

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
    latest_wave.high_breakout_used = false;
    latest_wave.low_breakout_used = false;

    MathSrand((int)(TimeLocal() ^ GetTickCount()));

    g_trade_round = 1;
    g_dual_full_handled = false;

    Print("========================================");
    Print("突破EA初始化成功 (极值点突破开仓)");
    Print("品种:", _Symbol);
    Print("K线周期:", EnumToString(InpTimeframe));
    Print("MA周期:", InpMAPeriod);
    Print("波段阈值范围: ", InpMinWavePercent, "% - ", InpMaxWavePercent, "%");
    if(InpPullbackTolerance > 0)
        Print("反向突破容忍度: ", DoubleToString(InpPullbackTolerance, 1), "% (启用)");
    else
        Print("反向突破容忍度: 0% (禁用)");
    if(InpBreakoutDirection == BREAKOUT_DIR_FOLLOW)
        Print("开仓方向: 顺势(破高多/破低空)");
    else if(InpBreakoutDirection == BREAKOUT_DIR_REVERSE)
        Print("开仓方向: 反向(破高空/破低多)");
    else
        Print("开仓方向: 随机(每次突破独立随机)");
    Print("开仓限制: 每个极值点(破高/破低)各最多1笔,可多笔并存");
    Print("止盈(结余%):", InpTakeProfitBalancePct, " (0=关闭,达标全部清仓)");
    Print("止损(结余%):", InpStopLossBalancePct, " (0=关闭,达标全部清仓)");
    Print("同向手数: 基准=", InpFixedLots, " 档间隔=", InpMartingaleTierInterval,
          " 每组+", InpMartingaleAddLotBoost, " 同向上限=", InpMaxLots);
    if(InpMinSameDirAddSpacingPercent > 0.0)
        Print("同向最小间距%:", InpMinSameDirAddSpacingPercent,
              " (多:现价须≤上一笔×(1-%); 空:现价须≥上一笔×(1+%))");
    else
        Print("同向最小间距%: 0 (不限制)");
    if(InpDualFullAction == DUAL_FULL_CLEAR_ALL)
        Print("双向满档后: 清仓");
    else
        Print("双向满档后: 不处理旧仓,开始下一轮(备注带轮次)");
    Print("禁止手工单:", (InpCloseManualOrders ? "启用 (自动平掉手工单)" : "禁用"));
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

    Print("突破EA已卸载");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // 1. 检查并关闭手工单（如果启用）
    if(InpCloseManualOrders)
        CheckAndCloseManualOrders();

    // 2. 更新最新有效波段
    UpdateLatestValidWave();

    // 3. 结余比例止盈/止损(全部持仓,含历史轮)
    CheckBreakoutBalanceExit();

    // 4. 当前轮双向同向均满档 → 清仓或开新轮
    CheckDualSideFullCapacity();

    // 5. 突破信号(破极值开仓,每极值点各限1笔)
    CheckBreakoutSignals();
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

                const double prev_high = latest_wave.high_price;
                const double prev_low = latest_wave.low_price;

                latest_wave.exists = true;
                latest_wave.high_price = high;
                latest_wave.low_price = low;
                latest_wave.update_time = extremes[i].time;

                // 极值价格更新 → 该侧可再开1笔(与是否已有其它持仓无关)
                if(high != prev_high)
                    latest_wave.high_breakout_used = false;
                if(low != prev_low)
                    latest_wave.low_breakout_used = false;

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

ENUM_ORDER_TYPE RandomBreakoutOrderType()
{
    return ((MathRand() & 1) != 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
}

int ParseRoundFromComment(const string &comment)
{
    const string prefix = "[突破-R";
    const int i = StringFind(comment, prefix);
    if(i == 0) {
        const int start = i + StringLen(prefix);
        const int end_br = StringFind(comment, "]", start);
        if(end_br > start)
            return (int)StringToInteger(StringSubstr(comment, start, end_br - start));
    }
    if(StringFind(comment, "[突破]") == 0)
        return 1;
    return 0;
}

bool IsEaBreakoutComment(const string &comment)
{
    return (ParseRoundFromComment(comment) > 0);
}

string FormatBreakoutComment(const int round)
{
    if(round <= 1)
        return "[突破]";
    return StringFormat("[突破-R%d]", round);
}

void ResetBreakoutWaveEntryFlags()
{
    latest_wave.high_breakout_used = false;
    latest_wave.low_breakout_used = false;
}

int CountAllBreakoutPositions()
{
    int count = 0;
    const int total = PositionsTotal();
    for(int i = 0; i < total; i++) {
        if(!PositionSelectByTicket(PositionGetTicket(i)))
            continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;
        if(!IsEaBreakoutComment(PositionGetString(POSITION_COMMENT)))
            continue;
        count++;
    }
    return count;
}

int CountBreakoutPositions(const long pos_type_filter)
{
    int count = 0;
    const int total = PositionsTotal();
    for(int i = 0; i < total; i++) {
        if(!PositionSelectByTicket(PositionGetTicket(i)))
            continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;
        const string c = PositionGetString(POSITION_COMMENT);
        if(ParseRoundFromComment(c) != g_trade_round)
            continue;
        if(pos_type_filter >= 0 && PositionGetInteger(POSITION_TYPE) != pos_type_filter)
            continue;
        count++;
    }
    return count;
}

double TotalLotsInDirection(const long pos_type)
{
    double sum = 0.0;
    const int total = PositionsTotal();
    for(int i = 0; i < total; i++) {
        if(!PositionSelectByTicket(PositionGetTicket(i)))
            continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;
        if(PositionGetInteger(POSITION_TYPE) != pos_type)
            continue;
        if(ParseRoundFromComment(PositionGetString(POSITION_COMMENT)) != g_trade_round)
            continue;
        sum += PositionGetDouble(POSITION_VOLUME);
    }
    return sum;
}

bool IsDirectionFullActive(const long pos_type)
{
    const double cur = TotalLotsInDirection(pos_type);
    if(cur >= InpMaxLots - 1e-8)
        return true;
    // 按下一笔实际加码手数判断(非仅基准手): 如19.5手+下一笔4.5>20亦视为满档
    const double next_lot = CalculateLotSize(pos_type);
    if(next_lot <= 0.0)
        return (cur > 0.0);
    return (cur + next_lot > InpMaxLots + 1e-8);
}

void CheckDualSideFullCapacity()
{
    const bool buy_full = IsDirectionFullActive(POSITION_TYPE_BUY);
    const bool sell_full = IsDirectionFullActive(POSITION_TYPE_SELL);

    if(!buy_full || !sell_full) {
        g_dual_full_handled = false;
        return;
    }

    if(g_dual_full_handled)
        return;

    g_dual_full_handled = true;

    const double buy_lots = TotalLotsInDirection(POSITION_TYPE_BUY);
    const double sell_lots = TotalLotsInDirection(POSITION_TYPE_SELL);

    if(InpDualFullAction == DUAL_FULL_CLEAR_ALL) {
        CloseAllBreakoutPositions(
            StringFormat("双向满档清仓 本轮多%.2f空%.2f上限%.2f", buy_lots, sell_lots, InpMaxLots));
        g_trade_round = 1;
        ResetBreakoutWaveEntryFlags();
        g_breakout_opened_on_bar_high = false;
        g_breakout_opened_on_bar_low = false;
        return;
    }

    g_trade_round++;
    ResetBreakoutWaveEntryFlags();
    g_breakout_opened_on_bar_high = false;
    g_breakout_opened_on_bar_low = false;
    Print("【突破】双向满档 开始第", g_trade_round, "轮 (旧仓保留,本轮从基准手数重计 多",
          DoubleToString(buy_lots, 2), " 空", DoubleToString(sell_lots, 2), " 上限", InpMaxLots, ")");
}

long PosTypeOnHighBreakout()
{
    return (InpBreakoutDirection == BREAKOUT_DIR_REVERSE) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
}

long PosTypeOnLowBreakout()
{
    return (InpBreakoutDirection == BREAKOUT_DIR_REVERSE) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
}

ENUM_ORDER_TYPE OrderTypeOnHighBreakout()
{
    return (ENUM_ORDER_TYPE)PosTypeOnHighBreakout();
}

ENUM_ORDER_TYPE OrderTypeOnLowBreakout()
{
    return (ENUM_ORDER_TYPE)PosTypeOnLowBreakout();
}

//+------------------------------------------------------------------+
//| 突破信号：破极值开仓(每极值点各限1笔,可多笔并存)                        |
//+------------------------------------------------------------------+
void CheckBreakoutSignals()
{
    if(!latest_wave.exists)
        return;

    const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    if(ask > latest_wave.high_price) {
        if(!latest_wave.high_breakout_used && IsBreakoutBarOpenAllowed(true)) {
            ENUM_ORDER_TYPE ot;
            if(InpBreakoutDirection == BREAKOUT_DIR_RANDOM)
                ot = RandomBreakoutOrderType();
            else
                ot = OrderTypeOnHighBreakout();
            if(InpShowDebugInfo)
                Print("【突破】破高开仓 ", (ot == ORDER_TYPE_BUY ? "多" : "空"),
                      " Ask:", ask, " 高点:", latest_wave.high_price);
            if(OpenBreakoutPosition(ot, latest_wave.high_price, latest_wave.low_price, true))
                latest_wave.high_breakout_used = true;
        }
    }

    if(bid < latest_wave.low_price) {
        if(!latest_wave.low_breakout_used && IsBreakoutBarOpenAllowed(false)) {
            ENUM_ORDER_TYPE ot;
            if(InpBreakoutDirection == BREAKOUT_DIR_RANDOM)
                ot = RandomBreakoutOrderType();
            else
                ot = OrderTypeOnLowBreakout();
            if(InpShowDebugInfo)
                Print("【突破】破低开仓 ", (ot == ORDER_TYPE_BUY ? "多" : "空"),
                      " Bid:", bid, " 低点:", latest_wave.low_price);
            if(OpenBreakoutPosition(ot, latest_wave.high_price, latest_wave.low_price, false))
                latest_wave.low_breakout_used = true;
        }
    }
}

//+------------------------------------------------------------------+
//| 手数规范化                                                         |
//+------------------------------------------------------------------+
double NormalizeVolume(double lots)
{
    const double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    const double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    const double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    if(lots < min_lot)
        lots = min_lot;
    if(lots > max_lot)
        lots = max_lot;
    if(lot_step > 0.0)
        lots = MathFloor(lots / lot_step) * lot_step;
    return lots;
}

// tier_index: 0=该方向首笔, 1=第2笔…；grp=tier/N，组内手数相同，每组=基准+grp×加码
double LotForSameDirectionTier(const int tier_index, const double base_lot)
{
    if(tier_index < 0 || base_lot <= 0.0)
        return 0.0;
    const int n = MathMax(1, InpMartingaleTierInterval);
    const int grp = tier_index / n;
    if(InpMartingaleAddLotBoost <= 0.0)
        return NormalizeVolume(base_lot);
    double vol = base_lot + (double)grp * InpMartingaleAddLotBoost;
    return NormalizeVolume(MathMin(vol, InpMaxLots));
}

//+------------------------------------------------------------------+
//| 按同向持仓笔数(档)计算本笔手数                                       |
//+------------------------------------------------------------------+
double CalculateLotSize(const long pos_type)
{
    const int tier = CountBreakoutPositions(pos_type);
    return LotForSameDirectionTier(tier, InpFixedLots);
}

bool GetLastSameDirectionOpenPrice(const long pos_type, double &last_open)
{
    last_open = 0.0;
    datetime last_tm = 0;
    bool found = false;
    const int total = PositionsTotal();
    for(int i = 0; i < total; i++) {
        if(!PositionSelectByTicket(PositionGetTicket(i)))
            continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;
        if(PositionGetInteger(POSITION_TYPE) != pos_type)
            continue;
        if(ParseRoundFromComment(PositionGetString(POSITION_COMMENT)) != g_trade_round)
            continue;
        const datetime tm = (datetime)PositionGetInteger(POSITION_TIME);
        if(!found || tm >= last_tm) {
            last_tm = tm;
            last_open = PositionGetDouble(POSITION_PRICE_OPEN);
            found = true;
        }
    }
    return found;
}

bool IsSameDirMinSpacingSatisfied(const long pos_type)
{
    if(InpMinSameDirAddSpacingPercent <= 0.0)
        return true;

    if(CountBreakoutPositions(pos_type) <= 0)
        return true;

    double last_open = 0.0;
    if(!GetLastSameDirectionOpenPrice(pos_type, last_open))
        return true;

    const double ratio = InpMinSameDirAddSpacingPercent / 100.0;
    if(pos_type == POSITION_TYPE_BUY) {
        const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        const double need = last_open * (1.0 - ratio);
        return (ask <= need);
    }
    const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    const double need = last_open * (1.0 + ratio);
    return (bid >= need);
}

double TotalBreakoutFloatingPL()
{
    double sum = 0.0;
    const int total = PositionsTotal();
    for(int i = 0; i < total; i++) {
        if(!PositionSelectByTicket(PositionGetTicket(i)))
            continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;
        if(!IsEaBreakoutComment(PositionGetString(POSITION_COMMENT)))
            continue;
        sum += PositionGetDouble(POSITION_PROFIT);
        sum += PositionGetDouble(POSITION_SWAP);
    }
    return sum;
}

bool CloseAllBreakoutPositions(const string reason)
{
    ulong tickets[];
    int n = 0;
    const int total = PositionsTotal();
    for(int i = 0; i < total; i++) {
        if(!PositionSelectByTicket(PositionGetTicket(i)))
            continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;
        if(!IsEaBreakoutComment(PositionGetString(POSITION_COMMENT)))
            continue;
        ArrayResize(tickets, n + 1);
        tickets[n++] = PositionGetTicket(i);
    }
    bool ok = true;
    for(int j = 0; j < n; j++) {
        if(!trade.PositionClose(tickets[j]))
            ok = false;
    }
    if(ok && n > 0) {
        g_trade_round = 1;
        g_dual_full_handled = false;
        ResetBreakoutWaveEntryFlags();
        Print("【突破】全部清仓 笔数=", n, " 原因:", reason);
    }
    return ok && n > 0;
}

void CheckBreakoutBalanceExit()
{
    if(CountAllBreakoutPositions() == 0)
        return;

    const double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    if(balance <= 0.0)
        return;

    const double fpl = TotalBreakoutFloatingPL();

    if(InpTakeProfitBalancePct > 0.0) {
        const double tp_need = balance * (InpTakeProfitBalancePct / 100.0);
        if(fpl >= tp_need) {
            CloseAllBreakoutPositions(
                StringFormat("止盈:浮盈%.2f达结余%.2f%%", fpl, InpTakeProfitBalancePct));
            return;
        }
    }

    if(InpStopLossBalancePct > 0.0) {
        const double sl_need = balance * (InpStopLossBalancePct / 100.0);
        if(fpl <= -sl_need) {
            CloseAllBreakoutPositions(
                StringFormat("止损:浮亏%.2f达结余%.2f%%", fpl, InpStopLossBalancePct));
        }
    }
}

void SyncBreakoutBarLock(const bool for_high_extreme)
{
    const datetime bar_time = iTime(_Symbol, InpTimeframe, 0);
    if(bar_time == 0)
        return;

    if(for_high_extreme) {
        if(bar_time != g_breakout_bar_time_high) {
            g_breakout_bar_time_high = bar_time;
            g_breakout_opened_on_bar_high = false;
        }
    } else {
        if(bar_time != g_breakout_bar_time_low) {
            g_breakout_bar_time_low = bar_time;
            g_breakout_opened_on_bar_low = false;
        }
    }
}

bool IsBreakoutBarOpenAllowed(const bool for_high_extreme)
{
    SyncBreakoutBarLock(for_high_extreme);
    if(for_high_extreme)
        return !g_breakout_opened_on_bar_high;
    return !g_breakout_opened_on_bar_low;
}

void MarkBreakoutBarOpened(const bool for_high_extreme)
{
    SyncBreakoutBarLock(for_high_extreme);
    if(for_high_extreme)
        g_breakout_opened_on_bar_high = true;
    else
        g_breakout_opened_on_bar_low = true;
}

bool OpenBreakoutPosition(ENUM_ORDER_TYPE order_type, double wave_high, double wave_low,
                          const bool from_high_extreme)
{
    if(!IsBreakoutBarOpenAllowed(from_high_extreme))
        return false;

    const long pos_type = (order_type == ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
    const double lots = CalculateLotSize(pos_type);
    if(lots <= 0.0)
        return false;

    const double cur_lots = TotalLotsInDirection(pos_type);
    if(cur_lots + lots > InpMaxLots + 1e-8) {
        Print("【突破】开仓跳过 - 同向合计将超上限 ", InpMaxLots,
              " 当前:", cur_lots, " 拟开:", lots);
        return false;
    }

    if(!IsSameDirMinSpacingSatisfied(pos_type)) {
        if(InpShowDebugInfo) {
            double last_open = 0.0;
            GetLastSameDirectionOpenPrice(pos_type, last_open);
            Print("【突破】开仓跳过 - 未达同向最小间距% ", InpMinSameDirAddSpacingPercent,
                  " 上一笔:", last_open, " 当前:",
                  (pos_type == POSITION_TYPE_BUY ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                                 : SymbolInfoDouble(_Symbol, SYMBOL_BID)));
        }
        return false;
    }

    const string comment = FormatBreakoutComment(g_trade_round);
    bool result = false;
    if(order_type == ORDER_TYPE_BUY)
        result = trade.Buy(lots, _Symbol, 0, 0, 0, comment);
    else
        result = trade.Sell(lots, _Symbol, 0, 0, 0, comment);

    if(!result) {
        Print("【突破】开仓失败: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
        return false;
    }

    MarkBreakoutBarOpened(from_high_extreme);
    const int tier = CountBreakoutPositions(pos_type) - 1;
    const int grp = (tier >= 0) ? (tier / MathMax(1, InpMartingaleTierInterval)) : 0;
    Print("【突破】开仓成功 ", (order_type == ORDER_TYPE_BUY ? "多" : "空"),
          " 手数:", lots, " 轮次:", g_trade_round, " 同向第", (tier + 1), "笔/组", (grp + 1),
          " 备注:", comment, " 波段 H:", wave_high, " L:", wave_low);
    return true;
}

//+------------------------------------------------------------------+
//| 检查并关闭手工单                                                   |
//+------------------------------------------------------------------+
void CheckAndCloseManualOrders()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(!PositionSelectByTicket(PositionGetTicket(i)))
            continue;

        // 只处理本品种
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;

        // 检查magic number：0表示手工单
        long magic = PositionGetInteger(POSITION_MAGIC);
        if(magic == 0) {
            ulong ticket = PositionGetTicket(i);

            // 平仓手工单
            if(trade.PositionClose(ticket)) {
                Print("【禁止手工单】已平掉手工单 - Ticket:", ticket,
                      " 类型:", (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "多单" : "空单"));
            } else {
                Print("【禁止手工单】平仓失败 - Ticket:", ticket, " 错误:", GetLastError());
            }
        }
    }
}
