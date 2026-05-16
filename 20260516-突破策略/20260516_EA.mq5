//+------------------------------------------------------------------+
//|                                                   20260516_EA.mq5 |
//|                                      突破极值点标记EA (Expert Advisor版本) |
//+------------------------------------------------------------------+
#property copyright "Breakout Strategy"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| 输入参数                                                           |
//+------------------------------------------------------------------+
input int      InpMAPeriod = 14;                // MA周期
input int      InpWaveThreshold = 1000;         // 波段阈值(点数)
input bool     InpShowDebugInfo = true;         // 显示调试信息
input color    InpHighExtremeColor = clrRed;    // 高点极值颜色
input color    InpLowExtremeColor = clrLime;    // 低点极值颜色

//+------------------------------------------------------------------+
//| 全局变量                                                           |
//+------------------------------------------------------------------+
int ma_handle;                                  // MA指标句柄
datetime last_process_time = 0;                 // 上次处理时间

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // 创建MA指标
    ma_handle = iMA(_Symbol, PERIOD_CURRENT, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
    if(ma_handle == INVALID_HANDLE) {
        Print("创建MA指标失败");
        return(INIT_FAILED);
    }

    Print("========================================");
    Print("突破极值点标记EA初始化成功");
    Print("品种:", _Symbol);
    Print("周期:", EnumToString(Period()));
    Print("MA周期:", InpMAPeriod);
    Print("波段阈值:", InpWaveThreshold, "点 (", InpWaveThreshold/100.0, "美元)");
    Print("========================================");

    // 删除旧的标记对象
    ObjectsDeleteAll(0, "Extreme_");

    // 处理历史数据
    ProcessHistory();

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(ma_handle != INVALID_HANDLE)
        IndicatorRelease(ma_handle);

    Print("突破极值点标记EA已卸载");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // 每根新K线处理一次
    datetime current_time = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(current_time == last_process_time)
        return;

    last_process_time = current_time;

    // 重新处理历史数据
    ProcessHistory();
}

//+------------------------------------------------------------------+
//| 处理历史数据                                                       |
//+------------------------------------------------------------------+
void ProcessHistory()
{
    int bars = Bars(_Symbol, PERIOD_CURRENT);
    if(bars < InpMAPeriod + 2) {
        Print("K线数量不足: ", bars);
        return;
    }

    // 限制处理的K线数量以提高性能
    int process_bars = MathMin(bars, 5000);

    if(InpShowDebugInfo)
        Print("开始处理历史数据 - 总K线:", bars, ", 处理数量:", process_bars);

    // 获取价格数据
    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    int copied = CopyRates(_Symbol, PERIOD_CURRENT, 0, process_bars, rates);
    if(copied <= 0) {
        Print("复制价格数据失败");
        return;
    }

    // 获取MA数据
    double ma_array[];
    ArraySetAsSeries(ma_array, true);
    copied = CopyBuffer(ma_handle, 0, 0, process_bars, ma_array);
    if(copied <= 0) {
        Print("复制MA数据失败");
        return;
    }

    if(InpShowDebugInfo)
        Print("数据准备完成 - 开始识别突破K线");

    // 识别所有突破K线
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

    if(InpShowDebugInfo)
        Print("共检测到 ", ArraySize(breakout_bars), " 个突破K线");

    if(ArraySize(breakout_bars) == 0) {
        Print("未检测到任何突破K线，请检查MA参数或数据");
        return;
    }

    // 处理突破K线并标记极值点
    ProcessBreakouts(breakout_bars, breakout_types, rates);
}

//+------------------------------------------------------------------+
//| 检查是否是突破K线                                                  |
//+------------------------------------------------------------------+
int CheckBreakout(int index, const MqlRates &rates[], const double &ma[])
{
    // 多单突破: 开盘 < MA, 收盘 > MA
    if(rates[index].open < ma[index] && rates[index].close > ma[index])
        return 1;

    // 空单突破: 开盘 > MA, 收盘 < MA
    if(rates[index].open > ma[index] && rates[index].close < ma[index])
        return -1;

    return 0;
}

//+------------------------------------------------------------------+
//| 处理所有突破K线并计算极值点                                        |
//+------------------------------------------------------------------+
void ProcessBreakouts(int &breakout_bars[], int &breakout_types[],
                     const MqlRates &rates[])
{
    int total = ArraySize(breakout_bars);
    if(total < 2) return;

    // 过滤连续同向突破
    int filtered_bars[];
    int filtered_types[];
    ArrayResize(filtered_bars, 0);
    ArrayResize(filtered_types, 0);

    for(int i = 0; i < total; i++) {
        int current_bar = breakout_bars[i];
        int current_type = breakout_types[i];

        // 检查是否有后续同向突破
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

    Print("过滤后剩余 ", ArraySize(filtered_bars), " 个有效突破K线（经过同向突破合并）");

    // 删除旧的极值点标记
    ObjectsDeleteAll(0, "Extreme_");

    // 计算所有极值点
    struct ExtremeInfo {
        datetime time;
        double price;
        int type;
        bool is_valid_wave;  // 是否构成有效波段
    };

    ExtremeInfo extremes[];
    ArrayResize(extremes, 0);

    // 先计算所有极值点
    for(int i = 0; i < ArraySize(filtered_bars) - 1; i++) {
        int current_bar = filtered_bars[i];
        int current_type = filtered_types[i];
        int next_bar = filtered_bars[i + 1];

        // 计算当前段的极值
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

        // 添加到极值点数组
        int size = ArraySize(extremes);
        ArrayResize(extremes, size + 1);
        extremes[size].time = extreme_time;
        extremes[size].price = extreme_price;
        extremes[size].type = current_type;
        extremes[size].is_valid_wave = false;
    }

    Print("共计算出 ", ArraySize(extremes), " 个极值点");

    // 判断哪些是有效波段
    // 策略：检查每个极值点与其前一个极值点是否能构成有效波段
    // 如果构成有效波段，则两个极值点都标记为有效
    if(ArraySize(extremes) > 0) {
        // 先全部标记为无效
        for(int i = 0; i < ArraySize(extremes); i++) {
            extremes[i].is_valid_wave = false;
        }

        int valid_wave_count = 0;

        for(int i = 1; i < ArraySize(extremes); i++) {
            // 检查与前一个极值点的价差
            double price_diff = MathAbs(extremes[i].price - extremes[i-1].price);
            double price_diff_points = price_diff / _Point;

            if(InpShowDebugInfo) {
                Print("检查极值点 #", i, " 与 #", i-1, " - 价差:", (int)price_diff_points, "点(",
                      DoubleToString(price_diff_points/100, 2), "美元)");
            }

            // 有效波段条件：与前一个极值点价差≥阈值
            if(price_diff_points >= InpWaveThreshold) {
                // 标记这两个极值点都为有效波段
                extremes[i-1].is_valid_wave = true;
                extremes[i].is_valid_wave = true;
                valid_wave_count++;
                if(InpShowDebugInfo)
                    Print("  ✓ 极值点 #", i-1, " 和 #", i, " 构成有效波段");
            } else {
                if(InpShowDebugInfo)
                    Print("  ✗ 价差不足(需要", InpWaveThreshold, "点)");
            }
        }

        Print(">>> 识别到 ", valid_wave_count, " 个有效波段");
    }

    // 标记所有极值点
    int valid_count = 0;
    for(int i = 0; i < ArraySize(extremes); i++) {
        DrawExtreme(extremes[i].time, extremes[i].price, extremes[i].type, i, extremes[i].is_valid_wave);
        if(extremes[i].is_valid_wave)
            valid_count++;
    }

    Print("========================================");
    Print("处理完成 - 总极值点:", ArraySize(extremes), ", 有效波段极值点:", valid_count);
    Print("========================================");
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| 在图表上绘制极值点                                                 |
//+------------------------------------------------------------------+
void DrawExtreme(datetime time, double price, int type, int index, bool is_valid_wave)
{
    string obj_name = "Extreme_" + IntegerToString(index);

    if(type == 1) {
        // 多单突破形成的高点 - 画下箭头
        ObjectCreate(0, obj_name, OBJ_ARROW, 0, time, price);
        ObjectSetInteger(0, obj_name, OBJPROP_ARROWCODE, 234);
        ObjectSetInteger(0, obj_name, OBJPROP_COLOR, is_valid_wave ? InpHighExtremeColor : clrDarkRed);
        ObjectSetInteger(0, obj_name, OBJPROP_WIDTH, is_valid_wave ? 3 : 2);
        ObjectSetInteger(0, obj_name, OBJPROP_ANCHOR, ANCHOR_BOTTOM);
    } else {
        // 空单突破形成的低点 - 画上箭头
        ObjectCreate(0, obj_name, OBJ_ARROW, 0, time, price);
        ObjectSetInteger(0, obj_name, OBJPROP_ARROWCODE, 233);
        ObjectSetInteger(0, obj_name, OBJPROP_COLOR, is_valid_wave ? InpLowExtremeColor : clrDarkGreen);
        ObjectSetInteger(0, obj_name, OBJPROP_WIDTH, is_valid_wave ? 3 : 2);
        ObjectSetInteger(0, obj_name, OBJPROP_ANCHOR, ANCHOR_TOP);
    }

    if(InpShowDebugInfo)
        Print("标记极值点 #", index, " - 类型:", (type == 1 ? "高点" : "低点"),
              ", 时间:", TimeToString(time), ", 价格:", DoubleToString(price, _Digits),
              ", 有效波段:", (is_valid_wave ? "是" : "否"));
}
