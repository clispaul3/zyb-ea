//+------------------------------------------------------------------+
//|                              20260606_breakout_reverse.mq5       |
//|                    极值识别框架 - 波段极值池                        |
//+------------------------------------------------------------------+
#property copyright "Extreme Point Framework"
#property version   "3.13"
#property description "极值池 + 斐波回调挂单 + 统损统盈"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| 输入参数                                                           |
//+------------------------------------------------------------------+
input group "=== 交易极值池 ==="
input int      InpRecentValidHighCount = 3;       // 保留最近N个有效高点(独立计数)
input int      InpRecentValidLowCount = 3;        // 保留最近N个有效低点(独立计数)
input int      InpMinExtremeDistancePoints = 500; // 极值点最小间距(点数,0=不过滤)

input group "=== 波段识别参数 ==="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT; // K线周期
input int      InpMAPeriod = 14;                // MA周期
input double   InpMinWavePercent = 0.5;          // 最小波段振幅百分比(%)
input double   InpMaxWavePercent = 2.0;         // 最大波段阈值百分比(%)
input double   InpPullbackTolerance = 0.05;     // 假突破容忍度(%) 0=不容忍
input int      InpMinWaveBars = 3;              // 有效波段最少K线数

input group "=== 显示参数 ==="
input bool     InpShowExtremeMarkers = false;     // 显示极值点标记
input bool     InpHighlightRecentValid = true;    // 高亮最近N个有效极值(交易池)
input bool     InpShowFibLevels = true;           // 显示当前波段斐波水平线

input group "=== 斐波回调开仓 ==="
input bool     InpEnableFibEntry = true;           // 启用斐波回调开仓
input int      InpMagicNumber = 20260606;         // EA魔术号
input double   InpLotsFib236 = 0.01;              // 0.236位置手数(0=不开)
input double   InpLotsFib382 = 0.01;              // 0.382位置手数(0=不开)
input double   InpLotsFib500 = 0.01;              // 0.500位置手数(0=不开)
input double   InpLotsFib618 = 0.01;              // 0.618位置手数(0=不开)
input int      InpBatchStopLossPoints = 0;        // 统损点数(0.618位±该值,0=不设)
input int      InpBatchTakeProfitPoints = 0;      // 统盈点数(目标极值±该值,0=不设)

//+------------------------------------------------------------------+
//| 全局变量                                                           |
//+------------------------------------------------------------------+
struct ExtremePoint {
    datetime time;
    double price;
    int type;       // 1=高点(多单突破MA), -1=低点(空单突破MA)
    bool is_valid;  // 是否属于有效波段极值
};

int ma_handle;
CTrade trade;

ExtremePoint g_recent_valid_highs[];
ExtremePoint g_recent_valid_lows[];

struct WaveFibState {
    datetime high_time;
    datetime low_time;
    double   high_price;
    double   low_price;
    int      direction;   // 1=低→高后回调做多, -1=高→低后反弹做空
};

WaveFibState g_wave_fib_state;
bool         g_wave_fib_initialized = false;
bool         g_fib_level_handled[4];
datetime     g_last_fib_place_bar = 0;

const double FIB_RATIOS[4] = {0.236, 0.382, 0.500, 0.618};
const string FIB_TAGS[4]   = {"236", "382", "500", "618"};

//+------------------------------------------------------------------+
//| 函数声明                                                           |
//+------------------------------------------------------------------+
void UpdateExtremePoints();
int CountBarsBetweenExtremeTimes(const datetime t1, const datetime t2);
bool IsValidWaveByBarCount(const datetime t1, const datetime t2);
bool IsValidWavePair(const ExtremePoint &extremes[], const int i);
void MergeSameDirectionExtremes(ExtremePoint &extremes[]);
bool FindBarExtremumInShiftRange(const int shift_old, const int shift_new, const bool find_high,
                                 double &price, datetime &time);
void RefineOneExtreme(ExtremePoint &ep, const datetime t_lo, const datetime t_hi);
void RefineValidWaveExtremes(ExtremePoint &extremes[]);
void MarkValidWaveExtremes(ExtremePoint &extremes[]);
void UpdateRecentValidExtremePool(const ExtremePoint &extremes[]);
void FilterExtremesByMinDistance(ExtremePoint &extremes[], const bool is_high);
bool IsSameExtremePoint(const ExtremePoint &a, const ExtremePoint &b);
bool IsExtremeInPool(const ExtremePoint &ep);
void DrawExtremeMarkers(ExtremePoint &extremes[]);
void DrawRecentValidExtremeHighlights();
int CheckBreakout(int index, const MqlRates &rates[], const double &ma[]);
void FilterBreakouts(const int &breakout_bars[], const int &breakout_types[],
                    const MqlRates &rates[], int &filtered_bars[], int &filtered_types[]);
bool GetLatestTradingWave(ExtremePoint &high, ExtremePoint &low, int &direction);
bool IsValidTradingWavePair(const ExtremePoint &high, const ExtremePoint &low);
bool IsSameWaveKey(const WaveFibState &a, const WaveFibState &b);
double CalcFibLevelPrice(const int direction, const double high, const double low, const double ratio);
double NormalizeVolumeLots(double lots);
double GetFibLevelLots(const int level_idx);
void CalcBatchSlTp(const WaveFibState &wave, const double entry_price, double &sl, double &tp);
bool IsEaFibComment(const string &comment);
string BuildFibComment(const int direction, const int level_idx,
                       const datetime high_time, const datetime low_time);
bool HasFibLevelExposure(const int direction, const double fib_price);
bool IsValidFibLimitPrice(const int direction, const double fib_price);
void CancelFibPendingOrders();
void DrawFibLevelLines(const WaveFibState &wave);
void DeleteFibLevelLines();
void PlaceFibPendingOrdersOnce();
void CheckFibEntrySignals();

//+------------------------------------------------------------------+
int OnInit()
{
    ma_handle = iMA(_Symbol, InpTimeframe, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
    if(ma_handle == INVALID_HANDLE) {
        Print("创建MA指标失败");
        return(INIT_FAILED);
    }

    if(InpRecentValidHighCount < 0 || InpRecentValidLowCount < 0) {
        Print("【参数错误】最近有效高/低点数量不能为负");
        return(INIT_PARAMETERS_INCORRECT);
    }

    Print("========================================");
    Print("20260606_breakout_reverse 初始化成功 v3.13");
    Print("品种:", _Symbol, " 周期:", EnumToString(InpTimeframe), " MA:", InpMAPeriod);
    Print("有效波段振幅: ", InpMinWavePercent, "% - ", InpMaxWavePercent, "%");
    Print("有效波段最少K线数(含两端): ", InpMinWaveBars);
    Print("交易极值池: 最近有效高点=", InpRecentValidHighCount,
          " 最近有效低点=", InpRecentValidLowCount, " (高/低独立计数)");
    Print("极值点去重: 最小间距=", InpMinExtremeDistancePoints, "点",
          (InpMinExtremeDistancePoints > 0 ? " (过近极值仅保留更极端价格)" : " (不过滤)"));
    Print("显示极值标记:", (InpShowExtremeMarkers ? "开" : "关"));
    Print("高亮交易池极值:", (InpHighlightRecentValid ? "开" : "关"));
    Print("斐波回调开仓:", (InpEnableFibEntry ? "开" : "关"),
          " 手数236/382/500/618=",
          DoubleToString(InpLotsFib236, 2), "/",
          DoubleToString(InpLotsFib382, 2), "/",
          DoubleToString(InpLotsFib500, 2), "/",
          DoubleToString(InpLotsFib618, 2));
    Print("统损/统盈: 0.618±", InpBatchStopLossPoints, "点 / 极值+",
          InpBatchTakeProfitPoints, "点 (0=不设)");
    Print("斐波水平线:", (InpShowFibLevels ? "开" : "关"), " Magic:", InpMagicNumber);
    Print("========================================");

    trade.SetExpertMagicNumber(InpMagicNumber);
    g_wave_fib_initialized = false;
    ArrayInitialize(g_fib_level_handled, false);
    g_last_fib_place_bar = 0;

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(ma_handle != INVALID_HANDLE)
        IndicatorRelease(ma_handle);

    ObjectsDeleteAll(0, "RevExt_");
    ObjectsDeleteAll(0, "RevAct_");
    DeleteFibLevelLines();
    CancelFibPendingOrders();
    Print("极值识别框架EA已卸载");
}

//+------------------------------------------------------------------+
void OnTick()
{
    UpdateExtremePoints();

    if(InpEnableFibEntry)
        CheckFibEntrySignals();
}

//+------------------------------------------------------------------+
int CountBarsBetweenExtremeTimes(const datetime t1, const datetime t2)
{
    if(t1 == t2)
        return 1;

    const datetime t_lo = (t1 <= t2) ? t1 : t2;
    const datetime t_hi = (t1 >= t2) ? t1 : t2;

    const int shift_lo = iBarShift(_Symbol, InpTimeframe, t_lo);
    const int shift_hi = iBarShift(_Symbol, InpTimeframe, t_hi);
    if(shift_lo < 0 || shift_hi < 0)
        return 0;

    return MathAbs(shift_lo - shift_hi) + 1;
}

//+------------------------------------------------------------------+
bool IsValidWaveByBarCount(const datetime t1, const datetime t2)
{
    if(InpMinWaveBars <= 1)
        return true;

    const int span = CountBarsBetweenExtremeTimes(t1, t2);
    return (span >= InpMinWaveBars);
}

//+------------------------------------------------------------------+
bool IsValidWavePair(const ExtremePoint &extremes[], const int i)
{
    if(i < 1 || i >= ArraySize(extremes))
        return false;

    const double price_diff = MathAbs(extremes[i].price - extremes[i-1].price);
    const double price_diff_points = price_diff / _Point;
    const double base_price = extremes[i-1].price;
    const double min_threshold = (base_price * InpMinWavePercent / 100.0) / _Point;
    const double max_threshold = (base_price * InpMaxWavePercent / 100.0) / _Point;

    return (price_diff_points >= min_threshold && price_diff_points <= max_threshold &&
            IsValidWaveByBarCount(extremes[i - 1].time, extremes[i].time));
}

//+------------------------------------------------------------------+
//| 合并相邻同向极值: 高点取更高, 低点取更低                              |
//+------------------------------------------------------------------+
void MergeSameDirectionExtremes(ExtremePoint &extremes[])
{
    const int n = ArraySize(extremes);
    if(n <= 1)
        return;

    ExtremePoint merged[];
    ArrayResize(merged, 0);

    for(int i = 0; i < n; i++) {
        const int m = ArraySize(merged);
        if(m == 0) {
            ArrayResize(merged, 1);
            merged[0] = extremes[i];
            merged[0].is_valid = false;
            continue;
        }

        if(extremes[i].type != merged[m - 1].type) {
            ArrayResize(merged, m + 1);
            merged[m] = extremes[i];
            merged[m].is_valid = false;
            continue;
        }

        if(extremes[i].type == 1) {
            if(extremes[i].price > merged[m - 1].price) {
                merged[m - 1] = extremes[i];
                merged[m - 1].is_valid = false;
            }
        } else if(extremes[i].price < merged[m - 1].price) {
            merged[m - 1] = extremes[i];
            merged[m - 1].is_valid = false;
        }
    }

    ArrayResize(extremes, ArraySize(merged));
    for(int i = 0; i < ArraySize(merged); i++)
        extremes[i] = merged[i];
}

//+------------------------------------------------------------------+
bool FindBarExtremumInShiftRange(const int shift_old, const int shift_new, const bool find_high,
                                 double &price, datetime &time)
{
    if(shift_old < 0 || shift_new < 0)
        return false;

    const int s_from = MathMax(shift_old, shift_new);
    const int s_to = MathMin(shift_old, shift_new);

    bool found = false;
    for(int s = s_from; s >= s_to; s--) {
        const double v = find_high ?
            iHigh(_Symbol, InpTimeframe, s) :
            iLow(_Symbol, InpTimeframe, s);
        const datetime bar_time = iTime(_Symbol, InpTimeframe, s);

        if(!found || (find_high ? (v > price) : (v < price))) {
            price = v;
            time = bar_time;
            found = true;
        }
    }
    return found;
}

//+------------------------------------------------------------------+
void RefineOneExtreme(ExtremePoint &ep, const datetime t_lo, const datetime t_hi)
{
    datetime left = t_lo;
    datetime right = t_hi;
    if(left > right) {
        const datetime tmp = left;
        left = right;
        right = tmp;
    }

    const int shift_lo = iBarShift(_Symbol, InpTimeframe, left);
    const int shift_hi = iBarShift(_Symbol, InpTimeframe, right);
    if(shift_lo < 0 || shift_hi < 0)
        return;

    double price = ep.price;
    datetime time = ep.time;
    const bool find_high = (ep.type == 1);
    if(FindBarExtremumInShiftRange(shift_lo, shift_hi, find_high, price, time)) {
        ep.price = price;
        ep.time = time;
    }
}

//+------------------------------------------------------------------+
//| 有效波段: 在相邻反向极值之间的K线内重扫真实高/低点                    |
//+------------------------------------------------------------------+
void RefineValidWaveExtremes(ExtremePoint &extremes[])
{
    const int n = ArraySize(extremes);
    for(int i = 1; i < n; i++) {
        if(!IsValidWavePair(extremes, i))
            continue;

        const datetime left_bound = (i >= 2) ? extremes[i - 2].time : extremes[i - 1].time;
        RefineOneExtreme(extremes[i - 1], left_bound, extremes[i].time);

        const datetime right_bound = (i + 1 < n) ? extremes[i + 1].time : extremes[i].time;
        RefineOneExtreme(extremes[i], extremes[i - 1].time, right_bound);
    }
}

//+------------------------------------------------------------------+
void MarkValidWaveExtremes(ExtremePoint &extremes[])
{
    for(int i = 0; i < ArraySize(extremes); i++)
        extremes[i].is_valid = false;

    for(int i = 1; i < ArraySize(extremes); i++) {
        if(IsValidWavePair(extremes, i)) {
            extremes[i - 1].is_valid = true;
            extremes[i].is_valid = true;
        }
    }
}

//+------------------------------------------------------------------+
bool IsSameExtremePoint(const ExtremePoint &a, const ExtremePoint &b)
{
    return (a.type == b.type &&
            a.time == b.time &&
            MathAbs(a.price - b.price) <= _Point * 0.5);
}

bool IsExtremeInPool(const ExtremePoint &ep)
{
    if(ep.type == 1) {
        for(int i = 0; i < ArraySize(g_recent_valid_highs); i++) {
            if(IsSameExtremePoint(g_recent_valid_highs[i], ep))
                return true;
        }
    } else if(ep.type == -1) {
        for(int i = 0; i < ArraySize(g_recent_valid_lows); i++) {
            if(IsSameExtremePoint(g_recent_valid_lows[i], ep))
                return true;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| 按最小间距过滤极值点: 间距过近时仅保留价格更极端的                    |
//| is_high=true: 过滤高点(保留更高价格)                                 |
//| is_high=false: 过滤低点(保留更低价格)                                |
//+------------------------------------------------------------------+
void FilterExtremesByMinDistance(ExtremePoint &extremes[], const bool is_high)
{
    if(InpMinExtremeDistancePoints <= 0)
        return;

    const int n = ArraySize(extremes);
    if(n <= 1)
        return;

    const double min_distance = InpMinExtremeDistancePoints * _Point;
    ExtremePoint filtered[];
    ArrayResize(filtered, 0);

    for(int i = 0; i < n; i++) {
        const int m = ArraySize(filtered);

        // 第一个极值点直接加入
        if(m == 0) {
            ArrayResize(filtered, 1);
            filtered[0] = extremes[i];
            continue;
        }

        // 检查与已过滤列表中所有点的距离
        bool too_close = false;
        int close_index = -1;

        for(int j = 0; j < m; j++) {
            double price_diff = MathAbs(extremes[i].price - filtered[j].price);

            if(price_diff < min_distance) {
                too_close = true;
                close_index = j;
                break;
            }
        }

        if(!too_close) {
            // 距离足够远,直接加入
            ArrayResize(filtered, m + 1);
            filtered[m] = extremes[i];
        } else {
            // 距离太近,比较价格,保留更极端的
            if(is_high) {
                // 高点: 保留价格更高的
                if(extremes[i].price > filtered[close_index].price) {
                    Print("【极值去重】高点过近,保留更高价格: 旧=",
                          DoubleToString(filtered[close_index].price, _Digits),
                          " 新=", DoubleToString(extremes[i].price, _Digits),
                          " 间距=", DoubleToString((extremes[i].price - filtered[close_index].price) / _Point, 1), "点");
                    filtered[close_index] = extremes[i];
                }
            } else {
                // 低点: 保留价格更低的
                if(extremes[i].price < filtered[close_index].price) {
                    Print("【极值去重】低点过近,保留更低价格: 旧=",
                          DoubleToString(filtered[close_index].price, _Digits),
                          " 新=", DoubleToString(extremes[i].price, _Digits),
                          " 间距=", DoubleToString((filtered[close_index].price - extremes[i].price) / _Point, 1), "点");
                    filtered[close_index] = extremes[i];
                }
            }
        }
    }

    // 将过滤后的结果复制回原数组
    ArrayResize(extremes, ArraySize(filtered));
    for(int i = 0; i < ArraySize(filtered); i++)
        extremes[i] = filtered[i];
}

//+------------------------------------------------------------------+
//| 从最新向历史扫描, 高/低各自保留最近 N 个有效极值                      |
//| g_recent_valid_highs[0] / g_recent_valid_lows[0] = 最新一个          |
//+------------------------------------------------------------------+
void UpdateRecentValidExtremePool(const ExtremePoint &extremes[])
{
    ArrayResize(g_recent_valid_highs, 0);
    ArrayResize(g_recent_valid_lows, 0);

    if(InpRecentValidHighCount == 0 && InpRecentValidLowCount == 0)
        return;

    for(int i = ArraySize(extremes) - 1; i >= 0; i--) {
        if(!extremes[i].is_valid)
            continue;

        if(extremes[i].type == 1 && InpRecentValidHighCount > 0 &&
           ArraySize(g_recent_valid_highs) < InpRecentValidHighCount) {
            const int sz = ArraySize(g_recent_valid_highs);
            ArrayResize(g_recent_valid_highs, sz + 1);
            g_recent_valid_highs[sz] = extremes[i];
        }

        if(extremes[i].type == -1 && InpRecentValidLowCount > 0 &&
           ArraySize(g_recent_valid_lows) < InpRecentValidLowCount) {
            const int sz = ArraySize(g_recent_valid_lows);
            ArrayResize(g_recent_valid_lows, sz + 1);
            g_recent_valid_lows[sz] = extremes[i];
        }

        const bool highs_full = (InpRecentValidHighCount <= 0 ||
                                 ArraySize(g_recent_valid_highs) >= InpRecentValidHighCount);
        const bool lows_full = (InpRecentValidLowCount <= 0 ||
                                ArraySize(g_recent_valid_lows) >= InpRecentValidLowCount);
        if(highs_full && lows_full)
            break;
    }

    // 按最小间距过滤极值点(去除过近的极值点)
    FilterExtremesByMinDistance(g_recent_valid_highs, true);   // 高点
    FilterExtremesByMinDistance(g_recent_valid_lows, false);   // 低点
}

//+------------------------------------------------------------------+
void UpdateExtremePoints()
{
    int bars = Bars(_Symbol, InpTimeframe);
    if(bars < InpMAPeriod + 2)
        return;

    const int process_bars = MathMin(bars, 500);

    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    if(CopyRates(_Symbol, InpTimeframe, 0, process_bars, rates) <= 0)
        return;

    double ma_array[];
    ArraySetAsSeries(ma_array, true);
    if(CopyBuffer(ma_handle, 0, 0, process_bars, ma_array) <= 0)
        return;

    int breakout_bars[];
    int breakout_types[];
    ArrayResize(breakout_bars, 0);
    ArrayResize(breakout_types, 0);

    for(int i = process_bars - InpMAPeriod - 1; i >= 1; i--) {
        const int breakout_type = CheckBreakout(i, rates, ma_array);
        if(breakout_type != 0) {
            const int size = ArraySize(breakout_bars);
            ArrayResize(breakout_bars, size + 1);
            ArrayResize(breakout_types, size + 1);
            breakout_bars[size] = i;
            breakout_types[size] = breakout_type;
        }
    }

    int filtered_bars[];
    int filtered_types[];
    FilterBreakouts(breakout_bars, breakout_types, rates, filtered_bars, filtered_types);

    ExtremePoint extremes[];
    ArrayResize(extremes, 0);

    if(InpPullbackTolerance <= 0.0) {
        for(int i = 0; i < ArraySize(filtered_bars) - 1; i++) {
            const int current_bar = filtered_bars[i];
            const int current_type = filtered_types[i];
            const int next_bar = filtered_bars[i + 1];

            double extreme_price = 0.0;
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

            const int size = ArraySize(extremes);
            ArrayResize(extremes, size + 1);
            extremes[size].time = extreme_time;
            extremes[size].price = extreme_price;
            extremes[size].type = current_type;
            extremes[size].is_valid = false;
        }
    } else {
        for(int i = 0; i < ArraySize(filtered_bars); i++) {
            const int start_bar = filtered_bars[i];
            const int start_type = filtered_types[i];

            double wave_high = rates[start_bar].high;
            double wave_low = rates[start_bar].low;
            datetime wave_high_time = rates[start_bar].time;
            datetime wave_low_time = rates[start_bar].time;
            int end_bar = 0;
            bool wave_terminated = false;

            for(int j = i + 1; j < ArraySize(filtered_bars); j++) {
                const int current_bar = filtered_bars[j];
                const int current_type = filtered_types[j];

                if(rates[current_bar].high > wave_high) {
                    wave_high = rates[current_bar].high;
                    wave_high_time = rates[current_bar].time;
                }
                if(rates[current_bar].low < wave_low) {
                    wave_low = rates[current_bar].low;
                    wave_low_time = rates[current_bar].time;
                }

                const int prev_bar = (j > 0) ? filtered_bars[j - 1] : start_bar;
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

                if(current_type != start_type) {
                    const double wave_range = wave_high - wave_low;
                    double pullback_percent = 0.0;

                    if(start_type == 1)
                        pullback_percent = ((wave_high - rates[current_bar].close) / wave_range) * 100.0;
                    else
                        pullback_percent = ((rates[current_bar].close - wave_low) / wave_range) * 100.0;

                    if(pullback_percent > InpPullbackTolerance) {
                        end_bar = current_bar;
                        wave_terminated = true;
                        break;
                    }
                }
            }

            if(start_type == 1) {
                int size = ArraySize(extremes);
                ArrayResize(extremes, size + 1);
                extremes[size].time = wave_low_time;
                extremes[size].price = wave_low;
                extremes[size].type = -1;
                extremes[size].is_valid = false;

                ArrayResize(extremes, size + 2);
                extremes[size + 1].time = wave_high_time;
                extremes[size + 1].price = wave_high;
                extremes[size + 1].type = 1;
                extremes[size + 1].is_valid = false;
            } else {
                int size = ArraySize(extremes);
                ArrayResize(extremes, size + 1);
                extremes[size].time = wave_high_time;
                extremes[size].price = wave_high;
                extremes[size].type = 1;
                extremes[size].is_valid = false;

                ArrayResize(extremes, size + 2);
                extremes[size + 1].time = wave_low_time;
                extremes[size + 1].price = wave_low;
                extremes[size + 1].type = -1;
                extremes[size + 1].is_valid = false;
            }

            if(wave_terminated) {
                for(int k = i + 1; k < ArraySize(filtered_bars); k++) {
                    if(filtered_bars[k] == end_bar) {
                        i = k - 1;
                        break;
                    }
                }
            } else {
                break;
            }
        }
    }

    MergeSameDirectionExtremes(extremes);
    MarkValidWaveExtremes(extremes);
    RefineValidWaveExtremes(extremes);
    MergeSameDirectionExtremes(extremes);
    MarkValidWaveExtremes(extremes);

    UpdateRecentValidExtremePool(extremes);

    if(InpShowExtremeMarkers)
        DrawExtremeMarkers(extremes);
    else
        ObjectsDeleteAll(0, "RevExt_");

    if(InpHighlightRecentValid)
        DrawRecentValidExtremeHighlights();
    else
        ObjectsDeleteAll(0, "RevAct_");
}

//+------------------------------------------------------------------+
void DrawExtremeMarkers(ExtremePoint &extremes[])
{
    ObjectsDeleteAll(0, "RevExt_");

    int marker_idx = 0;
    for(int i = 0; i < ArraySize(extremes); i++) {
        if(!extremes[i].is_valid)
            continue;

        const string obj_name = "RevExt_" + IntegerToString(marker_idx);
        marker_idx++;

        if(extremes[i].type == 1) {
            ObjectCreate(0, obj_name, OBJ_ARROW, 0, extremes[i].time, extremes[i].price);
            ObjectSetInteger(0, obj_name, OBJPROP_ARROWCODE, 234);
            ObjectSetInteger(0, obj_name, OBJPROP_COLOR, clrRed);
            ObjectSetInteger(0, obj_name, OBJPROP_WIDTH, 3);
            ObjectSetInteger(0, obj_name, OBJPROP_ANCHOR, ANCHOR_BOTTOM);
        } else {
            ObjectCreate(0, obj_name, OBJ_ARROW, 0, extremes[i].time, extremes[i].price);
            ObjectSetInteger(0, obj_name, OBJPROP_ARROWCODE, 233);
            ObjectSetInteger(0, obj_name, OBJPROP_COLOR, clrLime);
            ObjectSetInteger(0, obj_name, OBJPROP_WIDTH, 3);
            ObjectSetInteger(0, obj_name, OBJPROP_ANCHOR, ANCHOR_TOP);
        }
    }
}

//+------------------------------------------------------------------+
void DrawRecentValidExtremeHighlights()
{
    ObjectsDeleteAll(0, "RevAct_");

    for(int i = 0; i < ArraySize(g_recent_valid_highs); i++) {
        const string obj_name = "RevAct_H_" + IntegerToString(i);
        ObjectCreate(0, obj_name, OBJ_ARROW, 0,
                     g_recent_valid_highs[i].time, g_recent_valid_highs[i].price);
        ObjectSetInteger(0, obj_name, OBJPROP_ARROWCODE, 234);
        ObjectSetInteger(0, obj_name, OBJPROP_COLOR, clrYellow);
        ObjectSetInteger(0, obj_name, OBJPROP_WIDTH, 5);
        ObjectSetInteger(0, obj_name, OBJPROP_ANCHOR, ANCHOR_BOTTOM);
    }

    for(int i = 0; i < ArraySize(g_recent_valid_lows); i++) {
        const string obj_name = "RevAct_L_" + IntegerToString(i);
        ObjectCreate(0, obj_name, OBJ_ARROW, 0,
                     g_recent_valid_lows[i].time, g_recent_valid_lows[i].price);
        ObjectSetInteger(0, obj_name, OBJPROP_ARROWCODE, 233);
        ObjectSetInteger(0, obj_name, OBJPROP_COLOR, clrYellow);
        ObjectSetInteger(0, obj_name, OBJPROP_WIDTH, 5);
        ObjectSetInteger(0, obj_name, OBJPROP_ANCHOR, ANCHOR_TOP);
    }
}

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
void FilterBreakouts(const int &breakout_bars[], const int &breakout_types[],
                    const MqlRates &rates[], int &filtered_bars[], int &filtered_types[])
{
    const int total = ArraySize(breakout_bars);
    ArrayResize(filtered_bars, 0);
    ArrayResize(filtered_types, 0);

    for(int i = 0; i < total; i++) {
        const int current_bar = breakout_bars[i];
        const int current_type = breakout_types[i];

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
            const int size = ArraySize(filtered_bars);
            ArrayResize(filtered_bars, size + 1);
            ArrayResize(filtered_types, size + 1);
            filtered_bars[size] = current_bar;
            filtered_types[size] = current_type;
        }
    }
}

//+------------------------------------------------------------------+
//| 斐波回调开仓                                                        |
//+------------------------------------------------------------------+
bool GetLatestTradingWave(ExtremePoint &high, ExtremePoint &low, int &direction)
{
    direction = 0;
    if(ArraySize(g_recent_valid_highs) < 1 || ArraySize(g_recent_valid_lows) < 1)
        return false;

    high = g_recent_valid_highs[0];
    low = g_recent_valid_lows[0];

    if(high.price <= low.price + _Point * 0.5)
        return false;

    if(high.time >= low.time)
        direction = 1;   // 低点在前、高点在后 → 上涨波段结束, 等回调做多
    else
        direction = -1;  // 高点在前、低点在后 → 下跌波段结束, 等反弹做空

    return true;
}

bool IsValidTradingWavePair(const ExtremePoint &high, const ExtremePoint &low)
{
    const double range = high.price - low.price;
    if(range <= _Point * 0.5)
        return false;

    const double min_threshold = low.price * InpMinWavePercent / 100.0;
    const double max_threshold = low.price * InpMaxWavePercent / 100.0;
    if(range < min_threshold || range > max_threshold)
        return false;

    return IsValidWaveByBarCount(high.time, low.time);
}

bool IsSameWaveKey(const WaveFibState &a, const WaveFibState &b)
{
    return (a.high_time == b.high_time && a.low_time == b.low_time);
}

double CalcFibLevelPrice(const int direction, const double high, const double low, const double ratio)
{
    const double range = high - low;
    if(direction == 1)
        return NormalizeDouble(high - ratio * range, _Digits);
    return NormalizeDouble(low + ratio * range, _Digits);
}

double NormalizeVolumeLots(double lots)
{
    if(lots <= 0.0)
        return 0.0;

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

double GetFibLevelLots(const int level_idx)
{
    if(level_idx == 0) return InpLotsFib236;
    if(level_idx == 1) return InpLotsFib382;
    if(level_idx == 2) return InpLotsFib500;
    if(level_idx == 3) return InpLotsFib618;
    return 0.0;
}

void CalcBatchSlTp(const WaveFibState &wave, const double entry_price, double &sl, double &tp)
{
    sl = 0.0;
    tp = 0.0;

    const double fib618 = CalcFibLevelPrice(wave.direction, wave.high_price, wave.low_price, 0.618);

    if(InpBatchStopLossPoints > 0) {
        if(wave.direction == 1)
            sl = NormalizeDouble(fib618 - InpBatchStopLossPoints * _Point, _Digits);
        else
            sl = NormalizeDouble(fib618 + InpBatchStopLossPoints * _Point, _Digits);
    }

    if(InpBatchTakeProfitPoints > 0) {
        if(wave.direction == 1)
            tp = NormalizeDouble(wave.high_price + InpBatchTakeProfitPoints * _Point, _Digits);
        else
            tp = NormalizeDouble(wave.low_price + InpBatchTakeProfitPoints * _Point, _Digits);
    }

    const int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    if(stops_level <= 0)
        return;

    const double min_dist = stops_level * _Point;

    if(wave.direction == 1) {
        if(sl > 0.0 && entry_price - sl < min_dist)
            sl = NormalizeDouble(entry_price - min_dist, _Digits);
        if(tp > 0.0 && tp - entry_price < min_dist)
            tp = NormalizeDouble(entry_price + min_dist, _Digits);
    } else {
        if(sl > 0.0 && sl - entry_price < min_dist)
            sl = NormalizeDouble(entry_price + min_dist, _Digits);
        if(tp > 0.0 && entry_price - tp < min_dist)
            tp = NormalizeDouble(entry_price - min_dist, _Digits);
    }
}

bool IsEaFibComment(const string &comment)
{
    return (StringFind(comment, "Fib|") == 0);
}

string BuildFibComment(const int direction, const int level_idx,
                       const datetime high_time, const datetime low_time)
{
    return StringFormat("Fib|%d|%s|%s|%s",
                        direction,
                        FIB_TAGS[level_idx],
                        IntegerToString((long)high_time),
                        IntegerToString((long)low_time));
}

double FibPriceTolerance(const double fib_price)
{
    const int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    const double min_dist = (stops_level > 0) ? stops_level * _Point : _Point * 5;
    return MathMax(min_dist, fib_price * 0.00005);
}

bool HasFibLevelExposure(const int direction, const double fib_price)
{
    const double tol = FibPriceTolerance(fib_price);
    const ENUM_POSITION_TYPE want_pos = (direction == 1) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
    const ENUM_ORDER_TYPE want_ord = (direction == 1) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;

    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        const ulong ticket = PositionGetTicket(i);
        if(ticket == 0 || !PositionSelectByTicket(ticket))
            continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;
        if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != want_pos)
            continue;
        const double open_px = PositionGetDouble(POSITION_PRICE_OPEN);
        if(MathAbs(open_px - fib_price) <= tol)
            return true;
    }

    for(int i = OrdersTotal() - 1; i >= 0; i--) {
        const ulong ticket = OrderGetTicket(i);
        if(ticket == 0 || !OrderSelect(ticket))
            continue;
        if(OrderGetString(ORDER_SYMBOL) != _Symbol)
            continue;
        if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
            continue;
        if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != want_ord)
            continue;
        const double order_px = OrderGetDouble(ORDER_PRICE_OPEN);
        if(MathAbs(order_px - fib_price) <= tol)
            return true;
    }
    return false;
}

bool IsValidFibLimitPrice(const int direction, const double fib_price)
{
    const int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    const double min_dist = (stops_level > 0) ? stops_level * _Point : _Point;

    if(direction == 1) {
        const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        return (fib_price < ask - min_dist);
    }

    const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    return (fib_price > bid + min_dist);
}

void CancelFibPendingOrders()
{
    for(int i = OrdersTotal() - 1; i >= 0; i--) {
        const ulong ticket = OrderGetTicket(i);
        if(ticket == 0 || !OrderSelect(ticket))
            continue;
        if(OrderGetString(ORDER_SYMBOL) != _Symbol)
            continue;
        if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
            continue;
        if(!IsEaFibComment(OrderGetString(ORDER_COMMENT)))
            continue;
        trade.OrderDelete(ticket);
    }
}

void DeleteFibLevelLines()
{
    ObjectsDeleteAll(0, "RevFib_");
}

void DrawFibLevelLines(const WaveFibState &wave)
{
    DeleteFibLevelLines();

    if(!InpShowFibLevels)
        return;

    const datetime t2 = TimeCurrent();
    const datetime t1 = (wave.high_time <= wave.low_time) ? wave.high_time : wave.low_time;

    for(int i = 0; i < 4; i++) {
        const double price = CalcFibLevelPrice(wave.direction, wave.high_price, wave.low_price, FIB_RATIOS[i]);
        const string obj_name = "RevFib_" + FIB_TAGS[i];
        ObjectCreate(0, obj_name, OBJ_TREND, 0, t1, price, t2, price);
        ObjectSetInteger(0, obj_name, OBJPROP_COLOR, (wave.direction == 1) ? clrDodgerBlue : clrOrangeRed);
        ObjectSetInteger(0, obj_name, OBJPROP_STYLE, STYLE_DOT);
        ObjectSetInteger(0, obj_name, OBJPROP_WIDTH, 1);
        ObjectSetInteger(0, obj_name, OBJPROP_RAY_RIGHT, true);
        ObjectSetString(0, obj_name, OBJPROP_TEXT, "Fib " + FIB_TAGS[i]);
    }
}

bool PlaceFibLimitOrder(const WaveFibState &wave, const int level_idx, const double price, const double lots)
{
    const string comment = BuildFibComment(wave.direction, level_idx, wave.high_time, wave.low_time);
    trade.SetExpertMagicNumber(InpMagicNumber);

    double sl = 0.0, tp = 0.0;
    CalcBatchSlTp(wave, price, sl, tp);

    const bool result = (wave.direction == 1) ?
        trade.BuyLimit(lots, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment) :
        trade.SellLimit(lots, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);

    if(!result) {
        Print("【Fib】挂单失败 ", comment, " 价=", DoubleToString(price, _Digits),
              " 手数=", DoubleToString(lots, 2),
              " SL=", DoubleToString(sl, _Digits),
              " TP=", DoubleToString(tp, _Digits),
              " 错误:", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
        return false;
    }

    Print("【Fib】挂单 ", comment, " ",
          (wave.direction == 1 ? "BuyLimit" : "SellLimit"),
          " 波段高=", DoubleToString(wave.high_price, _Digits),
          " 低=", DoubleToString(wave.low_price, _Digits),
          " 回调位=", DoubleToString(price, _Digits),
          " 手数=", DoubleToString(lots, 2),
          " SL=", DoubleToString(sl, _Digits),
          " TP=", DoubleToString(tp, _Digits));
    return true;
}

void PlaceFibPendingOrdersOnce()
{
    const WaveFibState wave = g_wave_fib_state;

    for(int i = 0; i < 4; i++) {
        if(g_fib_level_handled[i])
            continue;

        const double lots = NormalizeVolumeLots(GetFibLevelLots(i));
        if(lots <= 0.0) {
            g_fib_level_handled[i] = true;
            continue;
        }

        const double fib_price = CalcFibLevelPrice(wave.direction, wave.high_price, wave.low_price, FIB_RATIOS[i]);

        if(HasFibLevelExposure(wave.direction, fib_price)) {
            g_fib_level_handled[i] = true;
            continue;
        }

        if(!IsValidFibLimitPrice(wave.direction, fib_price)) {
            g_fib_level_handled[i] = true;
            continue;
        }

        if(PlaceFibLimitOrder(wave, i, fib_price, lots))
            g_fib_level_handled[i] = true;
    }
}

void CheckFibEntrySignals()
{
    ExtremePoint high, low;
    int direction = 0;
    if(!GetLatestTradingWave(high, low, direction))
        return;
    if(!IsValidTradingWavePair(high, low))
        return;

    WaveFibState wave;
    wave.high_time = high.time;
    wave.low_time = low.time;
    wave.high_price = high.price;
    wave.low_price = low.price;
    wave.direction = direction;

    const bool wave_key_changed = (!g_wave_fib_initialized || !IsSameWaveKey(wave, g_wave_fib_state));

    if(wave_key_changed) {
        CancelFibPendingOrders();
        g_wave_fib_state = wave;
        g_wave_fib_initialized = true;
        ArrayInitialize(g_fib_level_handled, false);
        g_last_fib_place_bar = 0;

        Print("【Fib】新波段 ",
              (direction == 1 ? "低→高回调做多" : "高→低反弹做空"),
              " 高=", DoubleToString(wave.high_price, _Digits),
              "@", TimeToString(wave.high_time, TIME_DATE | TIME_MINUTES),
              " 低=", DoubleToString(wave.low_price, _Digits),
              "@", TimeToString(wave.low_time, TIME_DATE | TIME_MINUTES),
              " 振幅=", DoubleToString((wave.high_price - wave.low_price) / wave.low_price * 100.0, 3), "%");
    } else {
        g_wave_fib_state.high_price = wave.high_price;
        g_wave_fib_state.low_price = wave.low_price;
        g_wave_fib_state.direction = wave.direction;
    }

    if(InpShowFibLevels)
        DrawFibLevelLines(g_wave_fib_state);
    else
        DeleteFibLevelLines();

    const datetime bar_time = iTime(_Symbol, InpTimeframe, 0);
    if(bar_time == 0)
        return;

    if(!wave_key_changed && bar_time == g_last_fib_place_bar)
        return;

    g_last_fib_place_bar = bar_time;
    PlaceFibPendingOrdersOnce();
}

//+------------------------------------------------------------------+
