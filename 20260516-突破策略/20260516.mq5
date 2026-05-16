//+------------------------------------------------------------------+
//|                                               BreakoutMarker.mq5 |
//|                                                   突破极值点标记EA |
//|                                  用于标记突破策略中的极值点位置    |
//+------------------------------------------------------------------+
#property copyright "Breakout Strategy"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots   2

//--- 绘图设置
#property indicator_label1  "高点极值"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrRed
#property indicator_width1  3

#property indicator_label2  "低点极值"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrLime
#property indicator_width2  3

//+------------------------------------------------------------------+
//| 输入参数                                                           |
//+------------------------------------------------------------------+
input int      InpMAPeriod = 14;                // MA周期
input int      InpWaveThreshold = 1000;         // 波段阈值(点数)
input bool     InpShowDebugInfo = true;         // 显示调试信息

//+------------------------------------------------------------------+
//| 全局变量                                                           |
//+------------------------------------------------------------------+
int ma_handle;                                  // MA指标句柄
double HighExtremeBuffer[];                     // 高点极值缓冲区
double LowExtremeBuffer[];                      // 低点极值缓冲区

//+------------------------------------------------------------------+
//| 自定义指标初始化函数                                               |
//+------------------------------------------------------------------+
int OnInit()
{
    // 创建MA指标
    ma_handle = iMA(_Symbol, PERIOD_CURRENT, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
    if(ma_handle == INVALID_HANDLE) {
        Print("创建MA指标失败");
        return(INIT_FAILED);
    }

    // 设置指标缓冲区
    SetIndexBuffer(0, HighExtremeBuffer, INDICATOR_DATA);
    SetIndexBuffer(1, LowExtremeBuffer, INDICATOR_DATA);

    // 设置箭头代码
    PlotIndexSetInteger(0, PLOT_ARROW, 234);     // 下箭头(标记高点)
    PlotIndexSetInteger(1, PLOT_ARROW, 233);     // 上箭头(标记低点)

    PlotIndexSetInteger(0, PLOT_ARROW_SHIFT, -10);
    PlotIndexSetInteger(1, PLOT_ARROW_SHIFT, 10);

    // 设置数组为时间序列
    ArraySetAsSeries(HighExtremeBuffer, true);
    ArraySetAsSeries(LowExtremeBuffer, true);

    // 设置指标名称
    IndicatorSetString(INDICATOR_SHORTNAME, "突破极值点标记");

    Print("突破极值点标记EA初始化成功");
    Print("参数 - MA周期:", InpMAPeriod, ", 波段阈值:", InpWaveThreshold, "点");

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 自定义指标反初始化函数                                             |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(ma_handle != INVALID_HANDLE)
        IndicatorRelease(ma_handle);

    Print("突破极值点标记EA已卸载");
}

//+------------------------------------------------------------------+
//| 自定义指标迭代函数                                                 |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
    if(InpShowDebugInfo && prev_calculated == 0)
        Print("OnCalculate 首次调用 - rates_total:", rates_total);

    if(rates_total < InpMAPeriod + 2) {
        if(InpShowDebugInfo)
            Print("K线数量不足: ", rates_total);
        return(0);
    }

    // 设置数组为时间序列
    ArraySetAsSeries(time, true);
    ArraySetAsSeries(open, true);
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);
    ArraySetAsSeries(close, true);

    // 获取MA数据
    double ma_array[];
    ArraySetAsSeries(ma_array, true);
    int copied = CopyBuffer(ma_handle, 0, 0, rates_total, ma_array);
    if(copied <= 0) {
        if(InpShowDebugInfo)
            Print("复制MA数据失败，返回值:", copied);
        return(0);
    }

    if(InpShowDebugInfo && prev_calculated == 0)
        Print("MA数据复制成功，数量:", copied);

    // 初始化缓冲区
    ArrayInitialize(HighExtremeBuffer, 0);
    ArrayInitialize(LowExtremeBuffer, 0);

    // 识别所有突破K线
    int breakout_bars[];
    int breakout_types[];
    ArrayResize(breakout_bars, 0);
    ArrayResize(breakout_types, 0);

    for(int i = rates_total - InpMAPeriod - 1; i >= 1; i--) {
        int breakout_type = CheckBreakout(i, open, close, ma_array);
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

    // 处理突破K线并计算极值点
    ProcessBreakouts(breakout_bars, breakout_types, high, low, time);

    return(rates_total);
}

//+------------------------------------------------------------------+
//| 检查是否是突破K线                                                  |
//+------------------------------------------------------------------+
int CheckBreakout(int index, const double &open[], const double &close[], const double &ma[])
{
    // 多单突破: 开盘 < MA, 收盘 > MA
    if(open[index] < ma[index] && close[index] > ma[index])
        return 1;

    // 空单突破: 开盘 > MA, 收盘 < MA
    if(open[index] > ma[index] && close[index] < ma[index])
        return -1;

    return 0;
}

//+------------------------------------------------------------------+
//| 处理所有突破K线并计算极值点                                        |
//+------------------------------------------------------------------+
void ProcessBreakouts(int &breakout_bars[], int &breakout_types[],
                     const double &high[], const double &low[],
                     const datetime &time[])
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
                break;  // 遇到反向突破，停止检查

            // 比较哪个更极端
            if(current_type == 1) {  // 多单突破，保留最低价更低的
                if(low[breakout_bars[j]] < low[current_bar]) {
                    skip = true;
                    break;
                }
            } else {  // 空单突破，保留最高价更高的
                if(high[breakout_bars[j]] > high[current_bar]) {
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

    if(InpShowDebugInfo)
        Print("过滤后剩余 ", ArraySize(filtered_bars), " 个有效突破K线");

    // 计算极值点并应用波段阈值过滤
    double last_extreme_price = 0;
    int last_extreme_bar = -1;
    int last_extreme_type = 0;

    for(int i = 0; i < ArraySize(filtered_bars) - 1; i++) {
        int current_bar = filtered_bars[i];
        int current_type = filtered_types[i];
        int next_bar = filtered_bars[i + 1];

        // 计算当前段的极值
        double extreme_price = 0;
        int extreme_bar = current_bar;

        if(current_type == 1) {  // 多单突破后找最高价
            extreme_price = high[current_bar];
            for(int j = current_bar; j >= next_bar; j--) {
                if(high[j] > extreme_price) {
                    extreme_price = high[j];
                    extreme_bar = j;
                }
            }
        } else {  // 空单突破后找最低价
            extreme_price = low[current_bar];
            for(int j = current_bar; j >= next_bar; j--) {
                if(low[j] < extreme_price) {
                    extreme_price = low[j];
                    extreme_bar = j;
                }
            }
        }

        // 应用波段阈值过滤
        if(last_extreme_price != 0) {
            double price_diff = MathAbs(extreme_price - last_extreme_price);
            double price_diff_points = price_diff / _Point;

            if(InpShowDebugInfo) {
                Print("索引 ", i, " - 极值:", extreme_price,
                      ", 价差:", (int)price_diff_points, "点",
                      ", 时间:", TimeToString(time[extreme_bar]));
            }

            if(price_diff_points >= InpWaveThreshold) {
                // 标记上一个极值点
                MarkExtreme(last_extreme_bar, last_extreme_price, last_extreme_type, high, low);

                // 更新为当前极值点
                last_extreme_price = extreme_price;
                last_extreme_bar = extreme_bar;
                last_extreme_type = current_type;
            }
            // 如果不满足阈值，不更新last_extreme，继续用原极值点比较
        } else {
            // 第一个极值点，直接记录
            last_extreme_price = extreme_price;
            last_extreme_bar = extreme_bar;
            last_extreme_type = current_type;
        }
    }

    // 标记最后一个极值点
    if(last_extreme_bar >= 0) {
        MarkExtreme(last_extreme_bar, last_extreme_price, last_extreme_type, high, low);
    }
}

//+------------------------------------------------------------------+
//| 标记极值点                                                         |
//+------------------------------------------------------------------+
void MarkExtreme(int bar, double price, int type, const double &high[], const double &low[])
{
    if(type == 1) {  // 多单突破形成的高点
        HighExtremeBuffer[bar] = price;
        if(InpShowDebugInfo)
            Print("标记高点极值 - 索引:", bar, ", 价格:", price);
    } else {  // 空单突破形成的低点
        LowExtremeBuffer[bar] = price;
        if(InpShowDebugInfo)
            Print("标记低点极值 - 索引:", bar, ", 价格:", price);
    }
}
