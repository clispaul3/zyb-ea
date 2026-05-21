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

input group "=== 仓位管理参数 ==="
input bool     InpUseCompounding = true;        // 使用复利模式
input double   InpFixedLots = 0.01;             // 固定手数
input double   InpLotsPer500 = 0.05;            // 每500$开仓手数(复利模式)
input int      InpMaxPositions = 99;            // 最大开仓手数
input bool     InpOnePositionPerDirection = true; // 单方向最多持有一单

input group "=== 连续亏损保护 ==="
input int      InpConsecutiveLosses = 3;        // 连续亏损次数触发冷冻(0=禁用)
input int      InpFreezeBarCount = 60;          // 冷冻K线根数(0=禁用)

input group "=== 补偿机制参数 ==="
input bool     InpEnableCompensation = true;    // 启用补偿机制
input int      InpMinCompensationQueueSize = 1; // 补偿队列最小长度(>=此值才开补偿单)
input double   InpMaxCompensationLots = 5.0;    // 补偿单最大手数
input int      InpCompensationStopLossPips = 100; // 补偿单止损点数
input int      InpMaxCompensationTakeProfitPips = 300; // 补偿单最大止盈点数
input int      InpMaxConsecutiveCompensations = 5; // 连续补偿次数限制(超过则重置)

input group "=== 调试选项 ==="
input bool     InpShowDebugInfo = false;        // 显示调试信息
input bool     InpShowMarkers = true;           // 显示极值点标记
input int      InpMagicNumber = 20260516;       // EA魔术号
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

// 补偿队列项结构体定义
struct CompensationItem {
    int ticket;           // 订单号
    double loss;          // 亏损金额（正数，美元）
    double lots;          // 手数
    double stopLossAmount;// 止损金额（正数，美元）
    int direction;        // 方向（1=多单，-1=空单）
    datetime closeTime;   // 平仓时间
};

// 补偿机制全局变量
CompensationItem g_compensationQueue[];         // 补偿队列（待处理）
CompensationItem g_currentCompensationSnapshot[];// 当前补偿单对应的队列快照
int g_currentCompensationTicket = -1;           // 当前补偿单ticket（-1表示无补偿单）
int g_consecutiveCompensationCount = 0;         // 连续补偿计数器

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
void CheckAndCloseManualOrders();

// 补偿机制函数声明
void AddToCompensationQueue(ulong ticket);
bool OpenCompensationOrder();
void CheckCompensationOrderStatus();
void ClearCompensationQueue();

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
    Print("最大开仓手数:", InpMaxPositions);
    Print("单方向持仓限制:", (InpOnePositionPerDirection ? "启用 (每方向最多1单)" : "禁用"));
    if(InpConsecutiveLosses > 0 && InpFreezeBarCount > 0)
        Print("连续亏损保护: 启用 (", InpConsecutiveLosses, "次亏损→冷冻", InpFreezeBarCount, "根K线)");
    else
        Print("连续亏损保护: 禁用");
    Print("手数模式:", (InpUseCompounding ? "复利" : "固定"),
          InpUseCompounding ? StringFormat(" (每500$开%.2f手)", InpLotsPer500) : StringFormat(" (%.2f手)", InpFixedLots));
    Print("禁止手工单:", (InpCloseManualOrders ? "启用 (自动平掉手工单)" : "禁用"));
    if(InpEnableCompensation)
        Print("补偿机制: 启用 (队列最小长度:", InpMinCompensationQueueSize,
              " 最大手数:", InpMaxCompensationLots,
              " 止损:", InpCompensationStopLossPips, "点",
              " 最大止盈:", InpMaxCompensationTakeProfitPips, "点",
              " 连续限制:", InpMaxConsecutiveCompensations, "次)");
    else
        Print("补偿机制: 禁用");
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

    // 获取持仓ID用于补偿机制
    long position_id = HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);

    // 获取平仓原因
    ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal_ticket, DEAL_REASON);

    // 判断是亏损还是盈利（基于是否触发止损）
    if(reason == DEAL_REASON_SL)
    {
        // 检查是否是补偿单（补偿单不计入连续亏损统计）
        string comment = HistoryDealGetString(deal_ticket, DEAL_COMMENT);
        bool is_compensation = (StringFind(comment, "[补偿单]") >= 0);

        if(!is_compensation)
        {
            // 只有正常单亏损才增加计数器
            consecutive_loss_count++;
            Print("【连续亏损保护】正常单亏损 ", consecutive_loss_count, "/", InpConsecutiveLosses,
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
        else
        {
            Print("【补偿机制】补偿单亏损 - 不计入连续亏损统计 | 净亏损: $", DoubleToString(net_profit, 2));
        }

        // 补偿机制：将亏损单加入补偿队列（正常单和补偿单都加入）
        if(InpEnableCompensation)
        {
            AddToCompensationQueue(position_id);
        }
    }
    else if(reason == DEAL_REASON_TP)
    {
        // 检查是否是补偿单
        string comment = HistoryDealGetString(deal_ticket, DEAL_COMMENT);
        bool is_compensation = (StringFind(comment, "[补偿单]") >= 0);

        if(!is_compensation)
        {
            // 只有正常单盈利才重置计数器
            if(consecutive_loss_count > 0)
            {
                Print("【连续亏损保护】正常单止盈 - 计数器重置: ", consecutive_loss_count, " → 0 | 净盈利: $", DoubleToString(net_profit, 2));
                consecutive_loss_count = 0;
            }
        }
        else
        {
            Print("【补偿机制】补偿单止盈 - 不影响连续亏损计数器 | 净盈利: $", DoubleToString(net_profit, 2));
        }
    }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // 1. 检查并关闭手工单（如果启用）
    if(InpCloseManualOrders)
        CheckAndCloseManualOrders();

    // 2. 检查补偿单状态（优先处理补偿机制）
    if(InpEnableCompensation)
        CheckCompensationOrderStatus();

    // 3. 更新最新有效波段
    UpdateLatestValidWave();

    // 4. 检查开仓信号
    CheckOpenSignals();

    // 5. 管理已有持仓
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

    // 生成备注信息：盈亏比（止损点数会在设置SL后从历史记录计算）
    string comment = StringFormat("R%.1f", InpRiskRewardRatio);

    bool result = false;

    // 先以市价开仓（不带SL/TP），成交后再根据实际成交价设置SL/TP
    if(order_type == ORDER_TYPE_BUY) {
        result = trade.Buy(lots, _Symbol, 0, 0, 0, comment);
    } else {
        result = trade.Sell(lots, _Symbol, 0, 0, 0, comment);
    }

    if(!result) {
        Print("开仓失败: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
        return false;
    }

    // 等待持仓信息更新
    Sleep(100);

    // 通过符号和魔术号查找刚开的持仓
    ulong ticket = 0;
    double open_price = 0;

    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(!PositionSelectByTicket(PositionGetTicket(i)))
            continue;

        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;

        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;

        // 找到最新的持仓（没有SL/TP的）
        if(PositionGetDouble(POSITION_SL) == 0 && PositionGetDouble(POSITION_TP) == 0) {
            ticket = PositionGetTicket(i);
            open_price = PositionGetDouble(POSITION_PRICE_OPEN);
            break;
        }
    }

    if(ticket == 0) {
        Print("无法找到刚开的持仓");
        return false;
    }

    // 基于实际成交价计算止损金额
    double stop_loss_amount = open_price * InpStopLossPercent / 100.0;

    // 确保止损金额不小于最小止损点数
    double min_stop_loss = InpMinStopLossPoints * _Point;
    if(stop_loss_amount < min_stop_loss) {
        stop_loss_amount = min_stop_loss;
    }

    // 获取平台的最小止损距离
    int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double min_stop_distance = stops_level * _Point;

    // 获取当前市场价格
    double current_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double current_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    double sl = 0, tp = 0;

    if(order_type == ORDER_TYPE_BUY) {
        // 先标准化止损价
        sl = NormalizeDouble(open_price - stop_loss_amount, _Digits);
        // 根据标准化后的实际止损金额重新计算止盈金额，确保盈亏比准确
        double actual_sl_amount = open_price - sl;
        double take_profit_amount = actual_sl_amount * InpRiskRewardRatio;
        tp = NormalizeDouble(open_price + take_profit_amount, _Digits);

        // 检查止损距离（多单检查与Bid的距离）
        if(stops_level > 0 && (current_bid - sl) < min_stop_distance) {
            sl = NormalizeDouble(current_bid - min_stop_distance, _Digits);
            // 重新计算止盈
            actual_sl_amount = open_price - sl;
            take_profit_amount = actual_sl_amount * InpRiskRewardRatio;
            tp = NormalizeDouble(open_price + take_profit_amount, _Digits);
            Print("止损距离不足，已调整 - 新止损:", sl);
        }

        // 检查止盈距离
        if(stops_level > 0 && (tp - current_ask) < min_stop_distance) {
            tp = NormalizeDouble(current_ask + min_stop_distance, _Digits);
            Print("止盈距离不足，已调整 - 新止盈:", tp);
        }
    } else {
        // 先标准化止损价
        sl = NormalizeDouble(open_price + stop_loss_amount, _Digits);
        // 根据标准化后的实际止损金额重新计算止盈金额，确保盈亏比准确
        double actual_sl_amount = sl - open_price;
        double take_profit_amount = actual_sl_amount * InpRiskRewardRatio;
        tp = NormalizeDouble(open_price - take_profit_amount, _Digits);

        // 检查止损距离（空单检查与Ask的距离）
        if(stops_level > 0 && (sl - current_ask) < min_stop_distance) {
            sl = NormalizeDouble(current_ask + min_stop_distance, _Digits);
            // 重新计算止盈
            actual_sl_amount = sl - open_price;
            take_profit_amount = actual_sl_amount * InpRiskRewardRatio;
            tp = NormalizeDouble(open_price - take_profit_amount, _Digits);
            Print("止损距离不足，已调整 - 新止损:", sl);
        }

        // 检查止盈距离
        if(stops_level > 0 && (current_bid - tp) < min_stop_distance) {
            tp = NormalizeDouble(current_bid - min_stop_distance, _Digits);
            Print("止盈距离不足，已调整 - 新止盈:", tp);
        }
    }

    // 修改持仓的SL/TP
    if(!trade.PositionModify(ticket, sl, tp)) {
        Print("修改SL/TP失败 - Ticket:", ticket,
              " 错误码:", trade.ResultRetcode(),
              " 描述:", trade.ResultRetcodeDescription(),
              " 止损:", sl, " 止盈:", tp,
              " 平台最小距离:", stops_level, "点");
        return false;
    }

    Print(order_type == ORDER_TYPE_BUY ? "开多单成功" : "开空单成功",
          " - 手数:", lots,
          " 波段:H:", wave_high, " L:", wave_low,
          " 实际成交价:", open_price,
          " 止损:", sl, "(", InpStopLossPercent, "%)",
          " 止盈:", tp, "(盈亏比", InpRiskRewardRatio, ")");

    return true;
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

    // 补偿单不使用移动止损（需要达到完整止盈目标）
    string comment = PositionGetString(POSITION_COMMENT);
    if(StringFind(comment, "[补偿单]") >= 0)
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

//+------------------------------------------------------------------+
//| 将亏损单加入补偿队列                                               |
//+------------------------------------------------------------------+
void AddToCompensationQueue(ulong ticket)
{
    if(!InpEnableCompensation)
        return;

    // 需要选择历史记录才能获取已平仓订单的信息
    if(!HistorySelectByPosition(ticket))
        return;

    // 查找该持仓的平仓deal
    int total_deals = HistoryDealsTotal();
    if(total_deals <= 0)
        return;

    // 从最新的deal开始找
    for(int i = total_deals - 1; i >= 0; i--)
    {
        ulong deal_ticket = HistoryDealGetTicket(i);
        if(deal_ticket == 0)
            continue;

        // 检查是否是该持仓的平仓交易
        long deal_position = HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
        if(deal_position != (long)ticket)
            continue;

        // 检查是否是平仓
        ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
        if(entry != DEAL_ENTRY_OUT)
            continue;

        // 获取盈亏信息
        double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
        double commission = HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);
        double swap = HistoryDealGetDouble(deal_ticket, DEAL_SWAP);
        double net_profit = profit + commission + swap;

        // 获取平仓原因
        ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal_ticket, DEAL_REASON);

        // 只处理触发止损的单子
        if(reason != DEAL_REASON_SL)
            return;

        // 获取订单信息
        double lots = HistoryDealGetDouble(deal_ticket, DEAL_VOLUME);
        long deal_type = HistoryDealGetInteger(deal_ticket, DEAL_TYPE);
        int direction = (deal_type == DEAL_TYPE_BUY) ? 1 : -1;

        // 从历史记录中查找开仓和平仓价格，计算实际止损金额
        double open_price = 0;
        double close_price = 0;

        // 查找该持仓的所有deal
        int total_deals_temp = HistoryDealsTotal();
        for(int k = 0; k < total_deals_temp; k++)
        {
            ulong temp_ticket = HistoryDealGetTicket(k);
            if(HistoryDealGetInteger(temp_ticket, DEAL_POSITION_ID) == (long)ticket)
            {
                ENUM_DEAL_ENTRY temp_entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(temp_ticket, DEAL_ENTRY);
                if(temp_entry == DEAL_ENTRY_IN)
                {
                    open_price = HistoryDealGetDouble(temp_ticket, DEAL_PRICE);
                }
                else if(temp_entry == DEAL_ENTRY_OUT)
                {
                    close_price = HistoryDealGetDouble(temp_ticket, DEAL_PRICE);
                }
            }
        }

        // 计算实际止损金额 = |平仓价 - 开仓价|（亏损单的止损距离）
        double stop_loss_amount = MathAbs(close_price - open_price);

        // 加入补偿队列
        int size = ArraySize(g_compensationQueue);
        ArrayResize(g_compensationQueue, size + 1);

        g_compensationQueue[size].ticket = (int)ticket;
        g_compensationQueue[size].loss = MathAbs(net_profit);
        g_compensationQueue[size].lots = lots;
        g_compensationQueue[size].stopLossAmount = stop_loss_amount;
        g_compensationQueue[size].direction = direction;
        g_compensationQueue[size].closeTime = TimeCurrent();

        Print("【补偿机制】亏损单加入队列 - Ticket:", ticket,
              " 亏损:$", DoubleToString(MathAbs(net_profit), 2),
              " 手数:", lots,
              " 止损金额:$", DoubleToString(stop_loss_amount, 2),
              " (", (int)(stop_loss_amount / _Point), "点)",
              " 方向:", (direction == 1 ? "多单" : "空单"),
              " 开仓:", open_price, " 平仓:", close_price,
              " 队列大小:", ArraySize(g_compensationQueue));

        break;
    }
}

//+------------------------------------------------------------------+
//| 开立补偿单                                                         |
//+------------------------------------------------------------------+
bool OpenCompensationOrder()
{
    if(!InpEnableCompensation)
        return false;

    // 检查补偿队列长度是否达到最小要求
    int queue_size = ArraySize(g_compensationQueue);
    if(queue_size < InpMinCompensationQueueSize)
    {
        if(queue_size > 0 && InpShowDebugInfo)
            Print("【补偿机制】队列长度不足 (", queue_size, "/", InpMinCompensationQueueSize, ") - 暂不开补偿单");
        return false;
    }

    // 检查连续补偿次数是否超限
    if(InpMaxConsecutiveCompensations > 0 && g_consecutiveCompensationCount >= InpMaxConsecutiveCompensations)
    {
        Print("【补偿机制】连续补偿次数达到限制 (", g_consecutiveCompensationCount, "/", InpMaxConsecutiveCompensations, ")");
        Print("【补偿机制】重置补偿队列和计数器，停止补偿");

        // 清空队列和快照
        ArrayResize(g_compensationQueue, 0);
        ArrayResize(g_currentCompensationSnapshot, 0);

        // 重置计数器
        g_consecutiveCompensationCount = 0;
        g_currentCompensationTicket = -1;

        return false;
    }

    // 检查是否已有补偿单在持仓（双重检查机制）
    // 如果有补偿单，则不能开新单（队列累积）
    if(g_currentCompensationTicket >= 0)
    {
        // 检查补偿单是否还在持仓中
        if(PositionSelectByTicket(g_currentCompensationTicket))
            return false;  // 还在持仓，不开新单
        else
            g_currentCompensationTicket = -1;  // 已平仓，重置
    }

    // 二次检查：遍历所有持仓，确保没有其他补偿单
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!PositionSelectByTicket(PositionGetTicket(i)))
            continue;

        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;

        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;

        // 检查是否是补偿单
        string pos_comment = PositionGetString(POSITION_COMMENT);
        if(StringFind(pos_comment, "[补偿单]") >= 0)
        {
            Print("【补偿机制】检测到已有补偿单在持仓 - Ticket:", PositionGetTicket(i), " 暂不开新单");
            g_currentCompensationTicket = (int)PositionGetTicket(i);  // 同步ticket
            return false;  // 已有补偿单，拒绝开新单
        }
    }

    // 保存当前队列快照（这些亏损单将由本次补偿单负责）
    int snapshot_size = ArraySize(g_compensationQueue);
    ArrayResize(g_currentCompensationSnapshot, snapshot_size);
    for(int i = 0; i < snapshot_size; i++)
    {
        g_currentCompensationSnapshot[i] = g_compensationQueue[i];
    }

    // 清空待处理队列（快照已保存，新的亏损会加入队列等待下一次补偿）
    ArrayResize(g_compensationQueue, 0);

    // 计算补偿单参数（基于快照，此时 g_compensationQueue 已清空）
    double lots = 0;
    double sl_pips = 0;
    double tp_price = 0;
    int direction = 0;

    // 计算补偿单参数（基于快照）
    double total_loss = 0;
    double total_lots = 0;

    for(int i = 0; i < snapshot_size; i++)
    {
        total_loss += g_currentCompensationSnapshot[i].loss;
        total_lots += g_currentCompensationSnapshot[i].lots;
    }

    // 补偿单手数 = min(队列总手数, 最大手数限制)
    lots = MathMin(total_lots, InpMaxCompensationLots);

    // 补偿单止损点数：使用固定参数
    sl_pips = InpCompensationStopLossPips;

    // 补偿单方向：最近一个亏损单的反方向
    direction = -g_currentCompensationSnapshot[snapshot_size - 1].direction;

    Print("【补偿机制】计算补偿单参数 - 快照大小:", snapshot_size,
          " 总手数:", total_lots,
          " 补偿手数:", lots, (lots < total_lots ? " (受限于最大手数)" : ""),
          " 总亏损:$", DoubleToString(total_loss, 2));

    if(lots <= 0 || direction == 0)
        return false;

    Print("【补偿机制】队列快照已保存 - 快照大小:", snapshot_size, " 待处理队列已清空");

    // 开仓
    ENUM_ORDER_TYPE order_type = (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    string comment = StringFormat("[补偿单] Q%d", snapshot_size);

    bool result = false;
    if(order_type == ORDER_TYPE_BUY) {
        result = trade.Buy(lots, _Symbol, 0, 0, 0, comment);
    } else {
        result = trade.Sell(lots, _Symbol, 0, 0, 0, comment);
    }

    if(!result) {
        Print("【补偿机制】开补偿单失败: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
        return false;
    }

    // 等待持仓更新
    Sleep(100);

    // 查找刚开的补偿单
    ulong ticket = 0;
    double open_price = 0;

    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(!PositionSelectByTicket(PositionGetTicket(i)))
            continue;

        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;

        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;

        // 查找备注包含"[补偿单]"的持仓
        string pos_comment = PositionGetString(POSITION_COMMENT);
        if(StringFind(pos_comment, "[补偿单]") >= 0 &&
           PositionGetDouble(POSITION_SL) == 0 &&
           PositionGetDouble(POSITION_TP) == 0) {
            ticket = PositionGetTicket(i);
            open_price = PositionGetDouble(POSITION_PRICE_OPEN);
            break;
        }
    }

    if(ticket == 0) {
        Print("【补偿机制】找不到刚开的补偿单");
        return false;
    }

    // 计算止损止盈价格（基于实际成交价和固定参数）
    // 止损金额 = 固定止损点数 × 点值
    double sl_amount = InpCompensationStopLossPips * _Point;

    // 计算止盈点数：需要盈利 = 快照队列总亏损
    double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double point_value = tick_value / tick_size * _Point;
    double tp_pips_needed = total_loss / (lots * point_value);

    // 限制止盈点数不超过最大值
    bool is_capped = false;
    if(tp_pips_needed > InpMaxCompensationTakeProfitPips) {
        is_capped = true;
        tp_pips_needed = InpMaxCompensationTakeProfitPips;
    }

    Print("【补偿机制】止盈计算 - 总亏损:$", DoubleToString(total_loss, 2),
          " 手数:", lots,
          " Tick价值:$", tick_value,
          " Tick大小:", tick_size,
          " Point:", _Point,
          " 每点价值:$", DoubleToString(point_value, 4),
          " 需要止盈:", (int)tp_pips_needed, "点",
          is_capped ? " (受限于最大止盈)" : "");

    double sl = 0;
    double tp = 0;

    if(order_type == ORDER_TYPE_BUY) {
        sl = NormalizeDouble(open_price - sl_amount, _Digits);
        tp = NormalizeDouble(open_price + tp_pips_needed * _Point, _Digits);
    } else {
        sl = NormalizeDouble(open_price + sl_amount, _Digits);
        tp = NormalizeDouble(open_price - tp_pips_needed * _Point, _Digits);
    }

    // 获取平台最小止损距离
    int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double min_stop_distance = stops_level * _Point;
    double current_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double current_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    // 检查并调整止损距离
    if(order_type == ORDER_TYPE_BUY) {
        if(stops_level > 0 && (current_bid - sl) < min_stop_distance) {
            sl = NormalizeDouble(current_bid - min_stop_distance, _Digits);
            Print("【补偿机制】止损距离不足，已调整 - 新止损:", sl);
        }
        if(stops_level > 0 && (tp - current_ask) < min_stop_distance) {
            tp = NormalizeDouble(current_ask + min_stop_distance, _Digits);
            Print("【补偿机制】止盈距离不足，已调整 - 新止盈:", tp);
        }
    } else {
        if(stops_level > 0 && (sl - current_ask) < min_stop_distance) {
            sl = NormalizeDouble(current_ask + min_stop_distance, _Digits);
            Print("【补偿机制】止损距离不足，已调整 - 新止损:", sl);
        }
        if(stops_level > 0 && (current_bid - tp) < min_stop_distance) {
            tp = NormalizeDouble(current_bid - min_stop_distance, _Digits);
            Print("【补偿机制】止盈距离不足，已调整 - 新止盈:", tp);
        }
    }

    // 修改止损止盈
    if(!trade.PositionModify(ticket, sl, tp)) {
        Print("【补偿机制】修改SL/TP失败 - Ticket:", ticket,
              " 错误码:", trade.ResultRetcode(),
              " 描述:", trade.ResultRetcodeDescription(),
              " 开仓价:", open_price,
              " 止损:", sl,
              " 止盈:", tp,
              " 平台最小距离:", stops_level, "点");
        return false;
    }

    // 记录当前补偿单
    g_currentCompensationTicket = (int)ticket;

    // 增加连续补偿计数器
    g_consecutiveCompensationCount++;

    Print("【补偿机制】开补偿单成功 - Ticket:", ticket,
          " 类型:", (order_type == ORDER_TYPE_BUY ? "多单" : "空单"),
          " 手数:", lots,
          " 开仓价:", open_price,
          " 止损:", sl, " (", InpCompensationStopLossPips, "点)",
          " 止盈:", tp, " (", (int)tp_pips_needed, "点)",
          " 需补偿:$", DoubleToString(total_loss, 2),
          " 连续补偿:", g_consecutiveCompensationCount, "/", InpMaxConsecutiveCompensations);

    return true;
}

//+------------------------------------------------------------------+
//| 检查补偿单状态                                                     |
//+------------------------------------------------------------------+
void CheckCompensationOrderStatus()
{
    if(!InpEnableCompensation)
        return;

    // 如果没有补偿单在追踪，尝试开单
    if(g_currentCompensationTicket < 0)
    {
        // OpenCompensationOrder 内部会检查队列长度是否达到最小要求
        OpenCompensationOrder();
        return;
    }

    // 检查补偿单是否还在持仓
    if(PositionSelectByTicket(g_currentCompensationTicket))
        return;  // 还在持仓

    // 补偿单已平仓，检查盈亏
    if(!HistorySelectByPosition(g_currentCompensationTicket))
    {
        g_currentCompensationTicket = -1;
        return;
    }

    // 查找平仓deal
    int total_deals = HistoryDealsTotal();
    for(int i = total_deals - 1; i >= 0; i--)
    {
        ulong deal_ticket = HistoryDealGetTicket(i);
        if(deal_ticket == 0)
            continue;

        long deal_position = HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
        if(deal_position != g_currentCompensationTicket)
            continue;

        ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
        if(entry != DEAL_ENTRY_OUT)
            continue;

        // 获取盈亏
        double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
        double commission = HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);
        double swap = HistoryDealGetDouble(deal_ticket, DEAL_SWAP);
        double net_profit = profit + commission + swap;

        // 获取平仓原因
        ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal_ticket, DEAL_REASON);

        if(reason == DEAL_REASON_TP)
        {
            // 补偿单止盈：快照队列成功补偿，清空快照，重置计数器
            Print("【补偿机制】补偿单止盈 - 盈利:$", DoubleToString(net_profit, 2),
                  " 快照队列已补偿完成 (", ArraySize(g_currentCompensationSnapshot), "单)",
                  " 待处理队列:", ArraySize(g_compensationQueue), "单");
            ArrayResize(g_currentCompensationSnapshot, 0);

            // 止盈成功，重置连续补偿计数器
            Print("【补偿机制】补偿成功，重置连续补偿计数器: ", g_consecutiveCompensationCount, " → 0");
            g_consecutiveCompensationCount = 0;
        }
        else if(reason == DEAL_REASON_SL)
        {
            // 补偿单止损：快照队列需要重新补偿 + 补偿单本身也亏损了
            Print("【补偿机制】补偿单止损 - 亏损:$", DoubleToString(MathAbs(net_profit), 2),
                  " 快照队列 (", ArraySize(g_currentCompensationSnapshot), "单) 将重新加入待处理队列");

            // 1. 先把快照队列重新加入待处理队列
            int current_queue_size = ArraySize(g_compensationQueue);
            int snapshot_size = ArraySize(g_currentCompensationSnapshot);
            ArrayResize(g_compensationQueue, current_queue_size + snapshot_size);

            for(int j = 0; j < snapshot_size; j++)
            {
                g_compensationQueue[current_queue_size + j] = g_currentCompensationSnapshot[j];
            }

            // 2. 补偿单本身的亏损也加入队列
            AddToCompensationQueue(g_currentCompensationTicket);

            // 3. 清空快照
            ArrayResize(g_currentCompensationSnapshot, 0);

            Print("【补偿机制】待处理队列更新 - 当前大小:", ArraySize(g_compensationQueue), "单");
        }

        g_currentCompensationTicket = -1;
        break;
    }
}

//+------------------------------------------------------------------+
//| 清空补偿队列                                                       |
//+------------------------------------------------------------------+
void ClearCompensationQueue()
{
    ArrayResize(g_compensationQueue, 0);
    Print("【补偿机制】补偿队列已清空");
}
