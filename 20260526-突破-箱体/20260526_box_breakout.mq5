//+------------------------------------------------------------------+
//|                                        20260526_box_breakout.mq5 |
//|                              聚合箱体突破策略 - 完整交易版本          |
//+------------------------------------------------------------------+
#property copyright "Breakout Strategy"
#property version   "1.21"
#property strict

#include <Trade\Trade.mqh>

// 手数计算方式
enum ENUM_LOT_SIZE_MODE {
    LOT_SIZE_FIXED = 0,        // 固定手数
    LOT_SIZE_RISK_PERCENT = 1  // 结余风险比例(RiskPercent)
};

// 破高/破低开仓方向
enum ENUM_BREAKOUT_DIRECTION {
    BREAKOUT_DIR_FOLLOW = 0,  // 顺势(破高多/破低空)
    BREAKOUT_DIR_REVERSE = 1  // 反向(破高空/破低多)
};

//+------------------------------------------------------------------+
//| 输入参数                                                           |
//+------------------------------------------------------------------+
input group "=== 波段识别参数 ==="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M1; // K线周期
input int      InpMAPeriod = 14;                // MA周期
input double   InpMinWavePercent = 0.1;         // 最小波段振幅百分比(%)
input double   InpMaxWavePercent = 2.0;         // 最大波段阈值百分比(%)
input double   InpPullbackTolerance = 0.05;     // 反向突破容忍度(%) 0=不容忍
input int      InpMinWaveBars = 3;              // 有效波段最少K线数

input group "=== 大波段突破机制参数 ==="
input bool     InpEnableLargeWaveTrade = true;  // 启用大波段突破机制
input ENUM_BREAKOUT_DIRECTION InpLargeWaveDirection = BREAKOUT_DIR_FOLLOW; // 开仓方向
input double   InpLargeWaveMinPercent = 0.25;   // 最小波段振幅%(>该值)
input double   InpLargeWaveMaxPercent = 2.0;    // 最大波段振幅%(<=该值)
input bool     InpLargeWaveRetryAfterStopLoss = false; // 边界止损后再挂一单
input int      InpLargeWaveStopLossPoints = 80;      // 止损点数
input int      InpLargeWaveTakeProfitPoints = 120;   // 止盈点数
input bool     InpLargeWaveUseTrailingStop = false;  // 使用移动止损

input group "=== 聚合箱体机制参数 ==="
input bool     InpEnableBoxTrade = true;        // 启用聚合箱体突破机制
input ENUM_BREAKOUT_DIRECTION InpBoxDirection = BREAKOUT_DIR_FOLLOW; // 开仓方向
input double   InpBoxWaveMinPercent = 0.1;      // 成箱波段振幅下限%(>=)
input double   InpBoxWaveMaxPercent = 0.25;     // 成箱波段振幅上限%(<=)
input int      InpBoxMinWaves = 1;              // 成箱最少有效波段数
input int      InpBoxMaxWaves = 3;              // 成箱最多有效波段数(0=不限制)
input bool     InpBoxRetryAfterStopLoss = false; // 边界止损后再挂一单
input int      InpBoxStopLossPoints = 80;       // 止损点数
input int      InpBoxTakeProfitPoints = 120;    // 止盈点数
input bool     InpBoxUseTrailingStop = false;   // 使用移动止损

input group "=== 仓位管理模式 ==="
input ENUM_LOT_SIZE_MODE InpLotSizeMode = LOT_SIZE_RISK_PERCENT; // 手数模式
input double   InpFixedLots = 0.01;             // 固定手数
input double   InpRiskPercent = 5.0;            // 每笔风险占结余%
input double   InpMaxLots = 10.0;               // 单笔最大手数

input group "=== 其他参数 ==="
input bool     InpCloseManualOrders = true;     // 禁止手工单
input int      InpMagicNumber = 20260526;       // EA魔术号
input bool     InpShowExtremeMarkers = false;   // 显示极值点标记
input bool     InpBoxShowOnChart = false;       // 显示箱体标记
input bool     InpShowLatestWaveMarker = false; // 显示最近有效波段标记

input group "=== 交易时段(北京时间) ==="
input bool     InpEnableTradeSessionFilter = false; // 启用时段过滤
input string   InpTradeSessionsBeijing = "15:00-02:00"; // 可交易时段 多段用逗号分隔

//+------------------------------------------------------------------+
//| 全局变量                                                           |
//+------------------------------------------------------------------+
#define MAX_TRADE_SESSIONS 8

struct TradeSessionSlot {
    int start_minutes;
    int end_minutes;
    bool crosses_midnight;
};

TradeSessionSlot g_trade_sessions[MAX_TRADE_SESSIONS];
int g_trade_session_count = 0;
bool g_last_tick_in_trade_session = true;
int ma_handle;                                  // MA指标句柄
CTrade trade;                                   // 交易对象

// 最新有效波段信息
struct ValidWaveInfo {
    bool exists;                                // 是否存在有效波段
    double high_price;                          // 高点价格
    double low_price;                           // 低点价格
    datetime update_time;                       // 更新时间
    bool high_used;
    bool low_used;
    bool high_sl_retry_done;
    bool low_sl_retry_done;
    double range_percent;
};

ValidWaveInfo latest_wave;

double g_sync_wave_high = 0.0;
double g_sync_wave_low = 0.0;

struct WaveSegment {
    double high_price;
    double low_price;
    datetime time_start;
    datetime time_end;
    double range_percent;
};

// 聚合交易箱体
struct AggregateBoxInfo {
    bool exists;
    double high_price;
    double low_price;
    datetime time_start;
    datetime time_end;
    int wave_count;
    bool high_used;
    bool low_used;
    bool high_sl_retry_done;
    bool low_sl_retry_done;
    double range_percent;
};

AggregateBoxInfo active_box;
double g_sync_box_high = 0.0;
double g_sync_box_low = 0.0;
int g_box_draw_id = 0;

// 极值点结构体定义
struct ExtremePoint {
    datetime time;
    double price;
    int type;
    bool is_valid;
};

// 函数声明
void UpdateLatestValidWave();
int CountBarsBetweenExtremeTimes(const MqlRates &rates[], const datetime t1, const datetime t2);
bool IsValidWaveByBarCount(const MqlRates &rates[], const datetime t1, const datetime t2);
void DrawExtremeMarkers(ExtremePoint &extremes[]);
void DrawLatestValidWave(double high_price, datetime high_time, double low_price, datetime low_time);
bool IsValidWavePair(const ExtremePoint &extremes[], const MqlRates &rates[], const int i);
void BuildValidWaveSegments(const ExtremePoint &extremes[], const MqlRates &rates[],
                            WaveSegment &segments[]);
void UpdateAggregateBox(const WaveSegment &segments[]);
void DrawAggregateBox();
void DeleteAggregateBoxObjects();
double RangePercent(const double high, const double low);
bool IsLargeWaveTradeEligible();
bool IsBoxWaveSegmentPercent(const double pct);
void MarkLargeWaveHighUsed();
void MarkLargeWaveLowUsed();
void MarkBoxHighUsed();
void MarkBoxLowUsed();
void HandleStopLossRetryOnDeal(const ulong deal_ticket);
int CheckBreakout(int index, const MqlRates &rates[], const double &ma[]);
void FilterBreakouts(const int &breakout_bars[], const int &breakout_types[],
                    const MqlRates &rates[], int &filtered_bars[], int &filtered_types[]);
void SyncLargeWaveBreakoutPendingOrders();
void SyncBoxBreakoutPendingOrders();
void CancelAllEaPendingOrders();
void CancelLargeWavePendingOrders();
void CancelBoxPendingOrders();
void CancelEaPendingOrderType(const ENUM_ORDER_TYPE order_type, const string comment_prefix);
void CancelLargeWavePendingAtHigh();
void CancelLargeWavePendingAtLow();
void CancelBoxPendingAtHigh();
void CancelBoxPendingAtLow();
ulong FindEaPendingOrder(const ENUM_ORDER_TYPE order_type, const string comment_prefix);
ENUM_ORDER_TYPE PendingTypeOnHighBreakout(const ENUM_BREAKOUT_DIRECTION dir);
ENUM_ORDER_TYPE PendingTypeOnLowBreakout(const ENUM_BREAKOUT_DIRECTION dir);
long PosTypeOnHighBreakout(const ENUM_BREAKOUT_DIRECTION dir);
long PosTypeOnLowBreakout(const ENUM_BREAKOUT_DIRECTION dir);
void SyncPendingAtExtreme(const bool at_high, const double trigger_price,
                          const double range_high, const double range_low,
                          const ENUM_BREAKOUT_DIRECTION dir, const int sl_points,
                          const int tp_points, const string comment_prefix);
bool CalcPendingSlTp(const ENUM_ORDER_TYPE pending_type, const double trigger_price,
                     const int sl_points, const int tp_points, double &sl, double &tp);
bool PlaceBreakoutPendingOrder(const ENUM_ORDER_TYPE pending_type, const double trigger_price,
                               const int sl_points, const int tp_points,
                               const string comment);
double StopLossOffsetPoints(const int sl_points);
double TakeProfitOffsetPoints(const int tp_points);
int StopLossPointsFromComment(const string &comment);
bool UseTrailingStopFromComment(const string &comment);
double CalculateLotSize(const int sl_points);
double NormalizeVolumeLots(double lots);
void ManagePositions();
void CheckTrailingStop(ulong ticket);
void CheckAndCloseManualOrders();
bool ParseHHMMToMinutes(const string hhmm, int &minutes);
bool ParseTradeSessionsFromString(const string spec);
int BeijingMinutesOfDay();
bool IsWithinTradeSession();
void EnforceTradeSessionOnTick();
void LogDealFees(const ulong deal_ticket);

//+------------------------------------------------------------------+
//| 交易时段(北京时间 UTC+8)                                          |
//+------------------------------------------------------------------+
bool ParseHHMMToMinutes(const string hhmm, int &minutes)
{
    string s = hhmm;
    StringTrimLeft(s);
    StringTrimRight(s);
    const int colon = StringFind(s, ":");
    if(colon <= 0)
        return false;

    const int hour = (int)StringToInteger(StringSubstr(s, 0, colon));
    const int minute = (int)StringToInteger(StringSubstr(s, colon + 1));
    if(hour < 0 || hour > 23 || minute < 0 || minute > 59)
        return false;

    minutes = hour * 60 + minute;
    return true;
}

bool ParseTradeSessionsFromString(const string spec)
{
    g_trade_session_count = 0;

    string s = spec;
    StringTrimLeft(s);
    StringTrimRight(s);
    if(s == "")
        return false;

    string parts[];
    const int part_count = StringSplit(s, ',', parts);
    for(int i = 0; i < part_count && g_trade_session_count < MAX_TRADE_SESSIONS; i++) {
        string slot = parts[i];
        StringTrimLeft(slot);
        StringTrimRight(slot);
        if(slot == "")
            continue;

        const int dash = StringFind(slot, "-");
        if(dash <= 0)
            continue;

        string start_str = StringSubstr(slot, 0, dash);
        string end_str = StringSubstr(slot, dash + 1);
        StringTrimLeft(start_str);
        StringTrimRight(start_str);
        StringTrimLeft(end_str);
        StringTrimRight(end_str);

        int start_min = 0, end_min = 0;
        if(!ParseHHMMToMinutes(start_str, start_min) || !ParseHHMMToMinutes(end_str, end_min))
            continue;

        const int idx = g_trade_session_count;
        g_trade_sessions[idx].start_minutes = start_min;
        g_trade_sessions[idx].end_minutes = end_min;
        g_trade_sessions[idx].crosses_midnight = (start_min > end_min);
        g_trade_session_count++;
    }

    return (g_trade_session_count > 0);
}

int BeijingMinutesOfDay()
{
    MqlDateTime dt;
    TimeToStruct(TimeGMT() + 8 * 3600, dt);
    return dt.hour * 60 + dt.min;
}

bool IsWithinTradeSession()
{
    if(!InpEnableTradeSessionFilter || g_trade_session_count <= 0)
        return true;

    const int now = BeijingMinutesOfDay();
    for(int i = 0; i < g_trade_session_count; i++) {
        if(g_trade_sessions[i].crosses_midnight) {
            if(now >= g_trade_sessions[i].start_minutes ||
               now < g_trade_sessions[i].end_minutes)
                return true;
        } else if(now >= g_trade_sessions[i].start_minutes &&
                  now < g_trade_sessions[i].end_minutes) {
            return true;
        }
    }
    return false;
}

void EnforceTradeSessionOnTick()
{
    const bool in_session = IsWithinTradeSession();

    if(!in_session)
        CancelAllEaPendingOrders();

    if(in_session != g_last_tick_in_trade_session) {
        MqlDateTime dt;
        TimeToStruct(TimeGMT() + 8 * 3600, dt);
        Print("【交易时段】北京时间 ",
              StringFormat("%02d:%02d", dt.hour, dt.min),
              in_session ? " 进入可交易时段" : " 离开可交易时段(已撤EA挂单)");
        g_last_tick_in_trade_session = in_session;
    }
}

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
    latest_wave.high_sl_retry_done = false;
    latest_wave.low_sl_retry_done = false;

    active_box.exists = false;
    active_box.high_used = false;
    active_box.low_used = false;
    active_box.high_sl_retry_done = false;
    active_box.low_sl_retry_done = false;
    g_sync_box_high = 0.0;
    g_sync_box_low = 0.0;
    g_box_draw_id = 0;

    Print("========================================");
    Print("20260526_box_breakout 初始化成功");
    Print("品种:", _Symbol, " Magic:", InpMagicNumber);
    Print("结构有效波段: ", InpMinWavePercent, "% - ", InpMaxWavePercent, "%");
    Print("大波段突破:", (InpEnableLargeWaveTrade ? "开" : "关"),
          " (", InpLargeWaveMinPercent, "%, ", InpLargeWaveMaxPercent, "%]");
    Print("聚合箱体:", (InpEnableBoxTrade ? "开" : "关"),
          " 成箱波段 [", InpBoxWaveMinPercent, "%, ", InpBoxWaveMaxPercent, "%] 段数",
          InpBoxMinWaves, "-", (InpBoxMaxWaves > 0 ? IntegerToString(InpBoxMaxWaves) : "不限"));
    if(InpBoxMaxWaves > 0 && InpBoxMaxWaves < InpBoxMinWaves)
        Print("【参数警告】成箱最多段数 < 最少段数, 将无法成箱");
    if(InpEnableTradeSessionFilter) {
        if(ParseTradeSessionsFromString(InpTradeSessionsBeijing))
            Print("交易时段过滤: 开 北京时间 [", InpTradeSessionsBeijing, "]");
        else
            Print("【参数警告】可交易时段解析失败, 时段过滤不生效");
    } else {
        Print("交易时段过滤: 关");
    }
    g_last_tick_in_trade_session = IsWithinTradeSession();
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
    DeleteAggregateBoxObjects();
    CancelAllEaPendingOrders();

    Print("突破交易策略EA已卸载");
}

//+------------------------------------------------------------------+
//| 日志：成交手续费/库存费/净利(来自测试器或券商 deal 记录)              |
//+------------------------------------------------------------------+
void LogDealFees(const ulong deal_ticket)
{
    if(!HistoryDealSelect(deal_ticket))
        return;

    const string comment = HistoryDealGetString(deal_ticket, DEAL_COMMENT);
    if(StringFind(comment, "LW") != 0 && StringFind(comment, "BX") != 0)
        return;

    const ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
    string entry_label = "成交";
    if(entry == DEAL_ENTRY_IN)
        entry_label = "开仓";
    else if(entry == DEAL_ENTRY_OUT)
        entry_label = "平仓";

    const double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
    const double commission = HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);
    const double swap = HistoryDealGetDouble(deal_ticket, DEAL_SWAP);
    const double net = profit + commission + swap;
    const double volume = HistoryDealGetDouble(deal_ticket, DEAL_VOLUME);
    const double price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
    const ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal_ticket, DEAL_REASON);

    Print("【成交费用】", entry_label,
          " deal=", deal_ticket,
          " ", comment,
          " 手=", DoubleToString(volume, 2),
          " 价=", DoubleToString(price, _Digits),
          " 原因=", EnumToString(reason),
          " 毛利=", DoubleToString(profit, 2),
          " 手续费=", DoubleToString(commission, 2),
          " 库存费=", DoubleToString(swap, 2),
          " 净利=", DoubleToString(net, 2));
}

//+------------------------------------------------------------------+
//| 交易事务处理函数 - 用于检测亏损单                                    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
        return;
    if(!HistoryDealSelect(trans.deal))
        return;
    if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
        return;
    if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber)
        return;

    LogDealFees(trans.deal);

    const ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
    if(entry == DEAL_ENTRY_IN) {
        const string deal_comment = HistoryDealGetString(trans.deal, DEAL_COMMENT);
        const ENUM_DEAL_TYPE deal_type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
        if(StringFind(deal_comment, "LW") == 0) {
            if(deal_type == DEAL_TYPE_BUY) {
                if(PosTypeOnHighBreakout(InpLargeWaveDirection) == POSITION_TYPE_BUY)
                    MarkLargeWaveHighUsed();
                else if(PosTypeOnLowBreakout(InpLargeWaveDirection) == POSITION_TYPE_BUY)
                    MarkLargeWaveLowUsed();
            } else if(deal_type == DEAL_TYPE_SELL) {
                if(PosTypeOnHighBreakout(InpLargeWaveDirection) == POSITION_TYPE_SELL)
                    MarkLargeWaveHighUsed();
                else if(PosTypeOnLowBreakout(InpLargeWaveDirection) == POSITION_TYPE_SELL)
                    MarkLargeWaveLowUsed();
            }
        } else if(StringFind(deal_comment, "BX") == 0) {
            if(deal_type == DEAL_TYPE_BUY) {
                if(PosTypeOnHighBreakout(InpBoxDirection) == POSITION_TYPE_BUY)
                    MarkBoxHighUsed();
                else if(PosTypeOnLowBreakout(InpBoxDirection) == POSITION_TYPE_BUY)
                    MarkBoxLowUsed();
            } else if(deal_type == DEAL_TYPE_SELL) {
                if(PosTypeOnHighBreakout(InpBoxDirection) == POSITION_TYPE_SELL)
                    MarkBoxHighUsed();
                else if(PosTypeOnLowBreakout(InpBoxDirection) == POSITION_TYPE_SELL)
                    MarkBoxLowUsed();
            }
        }
    } else if(entry == DEAL_ENTRY_OUT) {
        HandleStopLossRetryOnDeal(trans.deal);
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

    // 2. 更新最新有效波段
    UpdateLatestValidWave();

    // 3. 时段过滤(北京时间): 时段外撤挂单, 时段内才挂突破单
    EnforceTradeSessionOnTick();
    if(InpEnableTradeSessionFilter && !IsWithinTradeSession()) {
        ManagePositions();
        return;
    }

    // 4. 大波段/箱体突破挂单(两套逻辑互不影响)
    SyncLargeWaveBreakoutPendingOrders();
    SyncBoxBreakoutPendingOrders();

    // 5. 管理已有持仓
    ManagePositions();
}

//+------------------------------------------------------------------+
//| 更新最新有效波段                                                   |
//+------------------------------------------------------------------+
int CountBarsBetweenExtremeTimes(const MqlRates &rates[], const datetime t1, const datetime t2)
{
    const datetime t_lo = (t1 <= t2) ? t1 : t2;
    const datetime t_hi = (t1 >= t2) ? t1 : t2;
    int count = 0;
    const int n = ArraySize(rates);
    for(int j = 0; j < n; j++) {
        if(rates[j].time >= t_lo && rates[j].time <= t_hi)
            count++;
    }
    return count;
}

bool IsValidWaveByBarCount(const MqlRates &rates[], const datetime t1, const datetime t2)
{
    if(InpMinWaveBars <= 1)
        return true;
    return (CountBarsBetweenExtremeTimes(rates, t1, t2) >= InpMinWaveBars);
}

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
        if(IsValidWavePair(extremes, rates, i)) {
            extremes[i-1].is_valid = true;
            extremes[i].is_valid = true;
        }
    }

    // 绘制所有极值点标记
    if(InpShowExtremeMarkers)
        DrawExtremeMarkers(extremes);

    // 查找最新的有效波段
    for(int i = ArraySize(extremes) - 1; i >= 1; i--) {
        if(IsValidWavePair(extremes, rates, i)) {
            const double price_diff = MathAbs(extremes[i].price - extremes[i-1].price);
            const double price_diff_points = price_diff / _Point;
            const double base_price = extremes[i-1].price;
            const double min_threshold = (base_price * InpMinWavePercent / 100.0) / _Point;
            const double max_threshold = (base_price * InpMaxWavePercent / 100.0) / _Point;
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
                latest_wave.range_percent = RangePercent(high, low);

                if(high != prev_high) {
                    latest_wave.high_used = false;
                    latest_wave.high_sl_retry_done = false;
                }
                if(low != prev_low) {
                    latest_wave.low_used = false;
                    latest_wave.low_sl_retry_done = false;
                }

                if(InpShowLatestWaveMarker)
                    DrawLatestValidWave(high, high_time, low, low_time);
            }
            break;
        }
    }

    if(latest_wave.exists)
        latest_wave.range_percent = RangePercent(latest_wave.high_price, latest_wave.low_price);
    else
        latest_wave.range_percent = 0.0;

    WaveSegment segments[];
    BuildValidWaveSegments(extremes, rates, segments);
    UpdateAggregateBox(segments);
}

//+------------------------------------------------------------------+
//| 有效波段判定(相邻两极值)                                            |
//+------------------------------------------------------------------+
bool IsValidWavePair(const ExtremePoint &extremes[], const MqlRates &rates[], const int i)
{
    if(i < 1 || i >= ArraySize(extremes))
        return false;

    const double price_diff = MathAbs(extremes[i].price - extremes[i-1].price);
    const double price_diff_points = price_diff / _Point;
    const double base_price = extremes[i-1].price;
    const double min_threshold = (base_price * InpMinWavePercent / 100.0) / _Point;
    const double max_threshold = (base_price * InpMaxWavePercent / 100.0) / _Point;

    return (price_diff_points >= min_threshold && price_diff_points <= max_threshold &&
            IsValidWaveByBarCount(rates, extremes[i - 1].time, extremes[i].time));
}

//+------------------------------------------------------------------+
//| 收集全部有效波段(时间正序:旧→新)                                    |
//+------------------------------------------------------------------+
void BuildValidWaveSegments(const ExtremePoint &extremes[], const MqlRates &rates[],
                            WaveSegment &segments[])
{
    ArrayResize(segments, 0);

    for(int i = 1; i < ArraySize(extremes); i++) {
        if(!IsValidWavePair(extremes, rates, i))
            continue;

        const int size = ArraySize(segments);
        ArrayResize(segments, size + 1);
        segments[size].high_price = MathMax(extremes[i].price, extremes[i-1].price);
        segments[size].low_price = MathMin(extremes[i].price, extremes[i-1].price);
        segments[size].time_start = extremes[i-1].time;
        segments[size].time_end = extremes[i].time;
        segments[size].range_percent = RangePercent(segments[size].high_price, segments[size].low_price);
    }
}

//+------------------------------------------------------------------+
//| 聚合箱体: 从新到旧纳入成箱振幅内的小波段                              |
//+------------------------------------------------------------------+
void UpdateAggregateBox(const WaveSegment &segments[])
{
    if(!InpEnableBoxTrade && !InpBoxShowOnChart) {
        if(active_box.exists) {
            active_box.exists = false;
            DeleteAggregateBoxObjects();
        }
        return;
    }

    const int total = ArraySize(segments);
    if(total <= 0) {
        if(active_box.exists) {
            active_box.exists = false;
            DeleteAggregateBoxObjects();
        }
        return;
    }

    const int newest_idx = total - 1;
    if(!IsBoxWaveSegmentPercent(segments[newest_idx].range_percent)) {
        if(active_box.exists) {
            active_box.exists = false;
            DeleteAggregateBoxObjects();
        }
        return;
    }

    double box_high = segments[newest_idx].high_price;
    double box_low = segments[newest_idx].low_price;
    datetime time_start = segments[newest_idx].time_start;
    datetime time_end = segments[newest_idx].time_end;
    int wave_count = 1;

    for(int i = newest_idx - 1; i >= 0; i--) {
        if(!IsBoxWaveSegmentPercent(segments[i].range_percent))
            break;
        if(InpBoxMaxWaves > 0 && wave_count >= InpBoxMaxWaves)
            break;

        box_high = MathMax(box_high, segments[i].high_price);
        box_low = MathMin(box_low, segments[i].low_price);
        time_start = segments[i].time_start;
        wave_count++;
    }

    if(wave_count < InpBoxMinWaves) {
        if(active_box.exists) {
            active_box.exists = false;
            DeleteAggregateBoxObjects();
        }
        return;
    }

    const bool prev_exists = active_box.exists;
    const double prev_high = active_box.high_price;
    const double prev_low = active_box.low_price;
    const bool box_replaced = prev_exists &&
        (MathAbs(box_high - prev_high) > _Point * 0.5 ||
         MathAbs(box_low - prev_low) > _Point * 0.5);

    active_box.exists = true;
    active_box.high_price = box_high;
    active_box.low_price = box_low;
    active_box.time_start = time_start;
    active_box.time_end = time_end;
    active_box.wave_count = wave_count;
    active_box.range_percent = RangePercent(box_high, box_low);

    if(!prev_exists || box_replaced) {
        active_box.high_used = false;
        active_box.low_used = false;
        active_box.high_sl_retry_done = false;
        active_box.low_sl_retry_done = false;
        g_box_draw_id++;
    }

    if(InpBoxShowOnChart)
        DrawAggregateBox();
}

//+------------------------------------------------------------------+
//| 振幅 / 交易资格 / 已用标记                                          |
//+------------------------------------------------------------------+
double RangePercent(const double high, const double low)
{
    const double mid = (high + low) * 0.5;
    if(mid <= 0.0)
        return 0.0;
    return (high - low) / mid * 100.0;
}

bool IsLargeWaveTradeEligible()
{
    if(!InpEnableLargeWaveTrade || !latest_wave.exists)
        return false;
    return (latest_wave.range_percent > InpLargeWaveMinPercent &&
            latest_wave.range_percent <= InpLargeWaveMaxPercent);
}

bool IsBoxWaveSegmentPercent(const double pct)
{
    return (pct >= InpBoxWaveMinPercent && pct <= InpBoxWaveMaxPercent);
}

void MarkLargeWaveHighUsed()
{
    latest_wave.high_used = true;
}

void MarkLargeWaveLowUsed()
{
    latest_wave.low_used = true;
}

void MarkBoxHighUsed()
{
    if(active_box.exists)
        active_box.high_used = true;
}

void MarkBoxLowUsed()
{
    if(active_box.exists)
        active_box.low_used = true;
}

//+------------------------------------------------------------------+
//| 止损出局后按机制允许同边界再挂一次                                    |
//+------------------------------------------------------------------+
void HandleStopLossRetryOnDeal(const ulong deal_ticket)
{
    if(!HistoryDealSelect(deal_ticket))
        return;
    if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
        return;

    const ENUM_DEAL_REASON close_reason =
        (ENUM_DEAL_REASON)HistoryDealGetInteger(deal_ticket, DEAL_REASON);
    if(close_reason != DEAL_REASON_SL)
        return;

    const ulong position_id = (ulong)HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
    if(position_id == 0 || !HistorySelectByPosition(position_id))
        return;

    long entry_pos_type = -1;
    ENUM_BREAKOUT_DIRECTION entry_dir = InpLargeWaveDirection;
    string entry_comment = "";
    for(int i = 0; i < HistoryDealsTotal(); i++) {
        const ulong in_ticket = HistoryDealGetTicket(i);
        if(in_ticket == 0)
            continue;
        if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(in_ticket, DEAL_ENTRY) != DEAL_ENTRY_IN)
            continue;
        const ENUM_DEAL_TYPE in_type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(in_ticket, DEAL_TYPE);
        if(in_type == DEAL_TYPE_BUY)
            entry_pos_type = POSITION_TYPE_BUY;
        else if(in_type == DEAL_TYPE_SELL)
            entry_pos_type = POSITION_TYPE_SELL;
        entry_comment = HistoryDealGetString(in_ticket, DEAL_COMMENT);
        if(StringFind(entry_comment, "BX") == 0)
            entry_dir = InpBoxDirection;
        else
            entry_dir = InpLargeWaveDirection;
        break;
    }
    if(entry_pos_type < 0 || entry_comment == "")
        return;

    const bool at_high = (entry_pos_type == PosTypeOnHighBreakout(entry_dir));
    const bool at_low = (entry_pos_type == PosTypeOnLowBreakout(entry_dir));
    if(!at_high && !at_low)
        return;

    if(StringFind(entry_comment, "LW") == 0) {
        if(!InpLargeWaveRetryAfterStopLoss)
            return;
        if(at_high) {
            if(latest_wave.high_sl_retry_done)
                return;
            latest_wave.high_used = false;
            latest_wave.high_sl_retry_done = true;
        } else {
            if(latest_wave.low_sl_retry_done)
                return;
            latest_wave.low_used = false;
            latest_wave.low_sl_retry_done = true;
        }
        Print("【大波段】止损出局,允许边界再挂一次");
        return;
    }

    if(StringFind(entry_comment, "BX") == 0) {
        if(!InpBoxRetryAfterStopLoss || !active_box.exists)
            return;
        if(at_high) {
            if(active_box.high_sl_retry_done)
                return;
            active_box.high_used = false;
            active_box.high_sl_retry_done = true;
        } else {
            if(active_box.low_sl_retry_done)
                return;
            active_box.low_used = false;
            active_box.low_sl_retry_done = true;
        }
        Print("【聚合箱体】止损出局,允许边界再挂一次");
    }
}

void DeleteAggregateBoxObjects()
{
    ObjectsDeleteAll(0, "TradeBox_");
}

//+------------------------------------------------------------------+
//| 图表绘制聚合箱体(矩形+上下沿)                                       |
//+------------------------------------------------------------------+
void DrawAggregateBox()
{
    if(!active_box.exists || !InpBoxShowOnChart)
        return;

    const string prefix = "TradeBox_" + IntegerToString(g_box_draw_id) + "_";
    const datetime time_right = iTime(_Symbol, InpTimeframe, 0);
    if(time_right == 0)
        return;

    datetime time_left = active_box.time_start;
    if(time_left <= 0 || time_left >= time_right)
        time_left = active_box.time_end;
    if(time_left <= 0 || time_left >= time_right)
        time_left = time_right - (datetime)(PeriodSeconds(InpTimeframe) * 20);

    const double box_high = active_box.high_price;
    const double box_low = active_box.low_price;

    string rect_name = prefix + "Rect";
    if(ObjectFind(0, rect_name) < 0)
        ObjectCreate(0, rect_name, OBJ_RECTANGLE, 0, time_left, box_high, time_right, box_low);
    else {
        ObjectSetInteger(0, rect_name, OBJPROP_TIME, 0, time_left);
        ObjectSetDouble(0, rect_name, OBJPROP_PRICE, 0, box_high);
        ObjectSetInteger(0, rect_name, OBJPROP_TIME, 1, time_right);
        ObjectSetDouble(0, rect_name, OBJPROP_PRICE, 1, box_low);
    }
    ObjectSetInteger(0, rect_name, OBJPROP_COLOR, clrDodgerBlue);
    ObjectSetInteger(0, rect_name, OBJPROP_STYLE, STYLE_SOLID);
    ObjectSetInteger(0, rect_name, OBJPROP_WIDTH, 1);
    ObjectSetInteger(0, rect_name, OBJPROP_FILL, true);
    ObjectSetInteger(0, rect_name, OBJPROP_BACK, true);
    ObjectSetInteger(0, rect_name, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, rect_name, OBJPROP_HIDDEN, true);

    const string high_line = prefix + "High";
    if(ObjectFind(0, high_line) < 0)
        ObjectCreate(0, high_line, OBJ_HLINE, 0, 0, box_high);
    else
        ObjectSetDouble(0, high_line, OBJPROP_PRICE, box_high);
    ObjectSetInteger(0, high_line, OBJPROP_COLOR, clrDodgerBlue);
    ObjectSetInteger(0, high_line, OBJPROP_STYLE, STYLE_DASH);
    ObjectSetInteger(0, high_line, OBJPROP_WIDTH, 2);
    ObjectSetInteger(0, high_line, OBJPROP_SELECTABLE, false);

    const string low_line = prefix + "Low";
    if(ObjectFind(0, low_line) < 0)
        ObjectCreate(0, low_line, OBJ_HLINE, 0, 0, box_low);
    else
        ObjectSetDouble(0, low_line, OBJPROP_PRICE, box_low);
    ObjectSetInteger(0, low_line, OBJPROP_COLOR, clrDodgerBlue);
    ObjectSetInteger(0, low_line, OBJPROP_STYLE, STYLE_DASH);
    ObjectSetInteger(0, low_line, OBJPROP_WIDTH, 2);
    ObjectSetInteger(0, low_line, OBJPROP_SELECTABLE, false);

    const string label_name = prefix + "Label";
    const double mid = (box_high + box_low) * 0.5;
    if(ObjectFind(0, label_name) < 0)
        ObjectCreate(0, label_name, OBJ_TEXT, 0, time_right, mid);
    else {
        ObjectSetInteger(0, label_name, OBJPROP_TIME, 0, time_right);
        ObjectSetDouble(0, label_name, OBJPROP_PRICE, 0, mid);
    }
    const double range_pct = (mid > 0.0) ? (box_high - box_low) / mid * 100.0 : 0.0;
    ObjectSetString(0, label_name, OBJPROP_TEXT,
                    StringFormat("箱×%d %.2f%%", active_box.wave_count, range_pct));
    ObjectSetInteger(0, label_name, OBJPROP_COLOR, clrDodgerBlue);
    ObjectSetInteger(0, label_name, OBJPROP_FONTSIZE, 8);
    ObjectSetInteger(0, label_name, OBJPROP_ANCHOR, ANCHOR_LEFT);
    ObjectSetInteger(0, label_name, OBJPROP_SELECTABLE, false);

    // 删除旧箱体对象(保留当前 id)
    const int total = ObjectsTotal(0, 0, -1);
    for(int i = total - 1; i >= 0; i--) {
        const string name = ObjectName(0, i, 0, -1);
        if(StringFind(name, "TradeBox_") == 0 && StringFind(name, prefix) != 0)
            ObjectDelete(0, name);
    }

    ChartRedraw(0);
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
//| 突破挂单管理                                                       |
//+------------------------------------------------------------------+
long PosTypeOnHighBreakout(const ENUM_BREAKOUT_DIRECTION dir)
{
    if(dir == BREAKOUT_DIR_REVERSE)
        return POSITION_TYPE_SELL;
    return POSITION_TYPE_BUY;
}

long PosTypeOnLowBreakout(const ENUM_BREAKOUT_DIRECTION dir)
{
    if(dir == BREAKOUT_DIR_REVERSE)
        return POSITION_TYPE_BUY;
    return POSITION_TYPE_SELL;
}

ENUM_ORDER_TYPE PendingTypeOnHighBreakout(const ENUM_BREAKOUT_DIRECTION dir)
{
    if(dir == BREAKOUT_DIR_REVERSE)
        return ORDER_TYPE_SELL_LIMIT;
    return ORDER_TYPE_BUY_STOP;
}

ENUM_ORDER_TYPE PendingTypeOnLowBreakout(const ENUM_BREAKOUT_DIRECTION dir)
{
    if(dir == BREAKOUT_DIR_REVERSE)
        return ORDER_TYPE_BUY_LIMIT;
    return ORDER_TYPE_SELL_STOP;
}

void CancelEaPendingOrderType(const ENUM_ORDER_TYPE order_type, const string comment_prefix)
{
    const ulong ticket = FindEaPendingOrder(order_type, comment_prefix);
    if(ticket > 0)
        trade.OrderDelete(ticket);
}

void CancelLargeWavePendingAtHigh()
{
    CancelEaPendingOrderType(ORDER_TYPE_BUY_STOP, "LW");
    CancelEaPendingOrderType(ORDER_TYPE_SELL_LIMIT, "LW");
}

void CancelLargeWavePendingAtLow()
{
    CancelEaPendingOrderType(ORDER_TYPE_SELL_STOP, "LW");
    CancelEaPendingOrderType(ORDER_TYPE_BUY_LIMIT, "LW");
}

void CancelBoxPendingAtHigh()
{
    CancelEaPendingOrderType(ORDER_TYPE_BUY_STOP, "BX");
    CancelEaPendingOrderType(ORDER_TYPE_SELL_LIMIT, "BX");
}

void CancelBoxPendingAtLow()
{
    CancelEaPendingOrderType(ORDER_TYPE_SELL_STOP, "BX");
    CancelEaPendingOrderType(ORDER_TYPE_BUY_LIMIT, "BX");
}

void CancelLargeWavePendingOrders()
{
    CancelLargeWavePendingAtHigh();
    CancelLargeWavePendingAtLow();
}

void CancelBoxPendingOrders()
{
    CancelBoxPendingAtHigh();
    CancelBoxPendingAtLow();
}

void CancelAllEaPendingOrders()
{
    CancelLargeWavePendingOrders();
    CancelBoxPendingOrders();
}

ulong FindEaPendingOrder(const ENUM_ORDER_TYPE order_type, const string comment_prefix)
{
    for(int i = OrdersTotal() - 1; i >= 0; i--) {
        const ulong ticket = OrderGetTicket(i);
        if(ticket == 0 || !OrderSelect(ticket))
            continue;
        if(OrderGetString(ORDER_SYMBOL) != _Symbol)
            continue;
        if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
            continue;
        if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != order_type)
            continue;
        const string comment = OrderGetString(ORDER_COMMENT);
        if(StringFind(comment, comment_prefix) == 0)
            return ticket;
    }
    return 0;
}

bool CalcPendingSlTp(const ENUM_ORDER_TYPE pending_type, const double trigger_price,
                     const int sl_points, const int tp_points, double &sl, double &tp)
{
    const double stop_loss_amount = StopLossOffsetPoints(sl_points);
    const double take_profit_amount = TakeProfitOffsetPoints(tp_points);
    const int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    const double min_stop_distance = stops_level * _Point;

    sl = 0.0;
    tp = 0.0;

    if(pending_type == ORDER_TYPE_BUY_STOP || pending_type == ORDER_TYPE_BUY_LIMIT) {
        sl = NormalizeDouble(trigger_price - stop_loss_amount, _Digits);
        tp = NormalizeDouble(trigger_price + take_profit_amount, _Digits);
        if(stops_level > 0) {
            if(trigger_price - sl < min_stop_distance)
                sl = NormalizeDouble(trigger_price - min_stop_distance, _Digits);
            if(tp - trigger_price < min_stop_distance)
                tp = NormalizeDouble(trigger_price + min_stop_distance, _Digits);
        }
    } else if(pending_type == ORDER_TYPE_SELL_STOP || pending_type == ORDER_TYPE_SELL_LIMIT) {
        sl = NormalizeDouble(trigger_price + stop_loss_amount, _Digits);
        tp = NormalizeDouble(trigger_price - take_profit_amount, _Digits);
        if(stops_level > 0) {
            if(sl - trigger_price < min_stop_distance)
                sl = NormalizeDouble(trigger_price + min_stop_distance, _Digits);
            if(trigger_price - tp < min_stop_distance)
                tp = NormalizeDouble(trigger_price - min_stop_distance, _Digits);
        }
    } else {
        return false;
    }
    return true;
}

bool PlaceBreakoutPendingOrder(const ENUM_ORDER_TYPE pending_type, const double trigger_price,
                               const int sl_points, const int tp_points,
                               const string comment)
{
    const double lots = CalculateLotSize(sl_points);
    if(lots <= 0.0)
        return false;

    double sl = 0.0, tp = 0.0;
    if(!CalcPendingSlTp(pending_type, trigger_price, sl_points, tp_points, sl, tp))
        return false;

    trade.SetExpertMagicNumber(InpMagicNumber);

    bool result = false;
    if(pending_type == ORDER_TYPE_BUY_STOP)
        result = trade.BuyStop(lots, trigger_price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
    else if(pending_type == ORDER_TYPE_SELL_STOP)
        result = trade.SellStop(lots, trigger_price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
    else if(pending_type == ORDER_TYPE_BUY_LIMIT)
        result = trade.BuyLimit(lots, trigger_price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
    else if(pending_type == ORDER_TYPE_SELL_LIMIT)
        result = trade.SellLimit(lots, trigger_price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);

    if(!result) {
        Print("挂单失败 ", comment, " ", EnumToString(pending_type),
              " 错误:", trade.ResultRetcode());
        return false;
    }
    return true;
}

void SyncPendingAtExtreme(const bool at_high, const double trigger_price,
                          const double range_high, const double range_low,
                          const ENUM_BREAKOUT_DIRECTION dir, const int sl_points,
                          const int tp_points, const string comment_prefix)
{
    const ENUM_ORDER_TYPE pending_type = at_high ?
        PendingTypeOnHighBreakout(dir) : PendingTypeOnLowBreakout(dir);
    const ENUM_ORDER_TYPE stale_type = at_high ?
        (pending_type == ORDER_TYPE_BUY_STOP ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_BUY_STOP) :
        (pending_type == ORDER_TYPE_SELL_STOP ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_STOP);
    CancelEaPendingOrderType(stale_type, comment_prefix);

    const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    const bool price_crossed = at_high ?
        (ask >= trigger_price - _Point * 0.5) :
        (bid <= trigger_price + _Point * 0.5);

    if(price_crossed) {
        if(StringCompare(comment_prefix, "LW") == 0) {
            if(at_high)
                CancelLargeWavePendingAtHigh();
            else
                CancelLargeWavePendingAtLow();
        } else {
            if(at_high)
                CancelBoxPendingAtHigh();
            else
                CancelBoxPendingAtLow();
        }
        return;
    }

    const int range_pts = (int)MathRound(MathAbs(range_high - range_low) / _Point);
    const double pending_price = NormalizeDouble(trigger_price, _Digits);
    const string comment = StringFormat("%s%d@%.*f", comment_prefix, range_pts, _Digits, pending_price);

    double expected_sl = 0.0, expected_tp = 0.0;
    if(!CalcPendingSlTp(pending_type, trigger_price, sl_points, tp_points, expected_sl, expected_tp))
        return;

    ulong ticket = FindEaPendingOrder(pending_type, comment_prefix);
    if(ticket > 0 && OrderSelect(ticket)) {
        const double existing_price = OrderGetDouble(ORDER_PRICE_OPEN);
        const double lots = CalculateLotSize(sl_points);
        if(MathAbs(existing_price - trigger_price) > _Point * 0.5 ||
           MathAbs(OrderGetDouble(ORDER_VOLUME_CURRENT) - lots) > 1e-8 ||
           MathAbs(OrderGetDouble(ORDER_SL) - expected_sl) > _Point * 0.5 ||
           MathAbs(OrderGetDouble(ORDER_TP) - expected_tp) > _Point * 0.5) {
            trade.OrderDelete(ticket);
            ticket = 0;
        }
    }
    if(ticket == 0)
        PlaceBreakoutPendingOrder(pending_type, trigger_price, sl_points, tp_points, comment);
}

void SyncLargeWaveBreakoutPendingOrders()
{
    if(!IsLargeWaveTradeEligible()) {
        CancelLargeWavePendingOrders();
        g_sync_wave_high = 0.0;
        g_sync_wave_low = 0.0;
        return;
    }

    if(MathAbs(latest_wave.high_price - g_sync_wave_high) > _Point * 0.5 ||
       MathAbs(latest_wave.low_price - g_sync_wave_low) > _Point * 0.5) {
        CancelLargeWavePendingOrders();
        g_sync_wave_high = latest_wave.high_price;
        g_sync_wave_low = latest_wave.low_price;
    }

    const double wh = latest_wave.high_price;
    const double wl = latest_wave.low_price;

    if(!latest_wave.high_used) {
        SyncPendingAtExtreme(true, wh, wh, wl, InpLargeWaveDirection,
                             InpLargeWaveStopLossPoints, InpLargeWaveTakeProfitPoints, "LW");
    } else {
        CancelLargeWavePendingAtHigh();
    }

    if(!latest_wave.low_used) {
        SyncPendingAtExtreme(false, wl, wh, wl, InpLargeWaveDirection,
                             InpLargeWaveStopLossPoints, InpLargeWaveTakeProfitPoints, "LW");
    } else {
        CancelLargeWavePendingAtLow();
    }
}

void SyncBoxBreakoutPendingOrders()
{
    if(!InpEnableBoxTrade || !active_box.exists) {
        CancelBoxPendingOrders();
        g_sync_box_high = 0.0;
        g_sync_box_low = 0.0;
        return;
    }

    if(MathAbs(active_box.high_price - g_sync_box_high) > _Point * 0.5 ||
       MathAbs(active_box.low_price - g_sync_box_low) > _Point * 0.5) {
        CancelBoxPendingOrders();
        g_sync_box_high = active_box.high_price;
        g_sync_box_low = active_box.low_price;
    }

    const double bh = active_box.high_price;
    const double bl = active_box.low_price;

    if(!active_box.high_used) {
        SyncPendingAtExtreme(true, bh, bh, bl, InpBoxDirection,
                             InpBoxStopLossPoints, InpBoxTakeProfitPoints, "BX");
    } else {
        CancelBoxPendingAtHigh();
    }

    if(!active_box.low_used) {
        SyncPendingAtExtreme(false, bl, bh, bl, InpBoxDirection,
                             InpBoxStopLossPoints, InpBoxTakeProfitPoints, "BX");
    } else {
        CancelBoxPendingAtLow();
    }
}

//+------------------------------------------------------------------+
//| 止损/止盈距离(点数)                                                |
//+------------------------------------------------------------------+
double StopLossOffsetPoints(const int sl_points)
{
    if(sl_points <= 0)
        return 0.0;
    return (double)sl_points * _Point;
}

double TakeProfitOffsetPoints(const int tp_points)
{
    if(tp_points <= 0)
        return 0.0;
    return (double)tp_points * _Point;
}

int StopLossPointsFromComment(const string &comment)
{
    if(StringFind(comment, "BX") == 0)
        return InpBoxStopLossPoints;
    return InpLargeWaveStopLossPoints;
}

bool UseTrailingStopFromComment(const string &comment)
{
    if(StringFind(comment, "BX") == 0)
        return InpBoxUseTrailingStop;
    return InpLargeWaveUseTrailingStop;
}

//+------------------------------------------------------------------+
//| 手数规范化                                                         |
//+------------------------------------------------------------------+
double NormalizeVolumeLots(double lots)
{
    const double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    const double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    const double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    if(InpMaxLots > 0.0)
        lots = MathMin(lots, InpMaxLots);
    if(lots < min_lot)
        lots = min_lot;
    if(lots > max_lot)
        lots = max_lot;
    if(lot_step > 0.0)
        lots = MathFloor(lots / lot_step) * lot_step;
    return lots;
}

//+------------------------------------------------------------------+
//| 计算开仓手数                                                       |
//+------------------------------------------------------------------+
double CalculateLotSize(const int sl_points)
{
    double lots = InpFixedLots;

    if(InpLotSizeMode == LOT_SIZE_RISK_PERCENT && InpRiskPercent > 0.0) {
        const double stop_loss_dist = StopLossOffsetPoints(sl_points);
        const double balance = AccountInfoDouble(ACCOUNT_BALANCE);
        const double risk_money = balance * InpRiskPercent / 100.0;

        const double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        const double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        if(stop_loss_dist > 0.0 && tick_size > 0.0 && tick_value > 0.0 && risk_money > 0.0) {
            const double loss_per_lot = (stop_loss_dist / tick_size) * tick_value;
            if(loss_per_lot > 0.0)
                lots = risk_money / loss_per_lot;
        }
    }

    return NormalizeVolumeLots(lots);
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

        CheckTrailingStop(PositionGetTicket(i));
    }
}

//+------------------------------------------------------------------+
//| 检查移动止损                                                       |
//+------------------------------------------------------------------+
void CheckTrailingStop(ulong ticket)
{
    if(!PositionSelectByTicket(ticket))
        return;

    const string comment = PositionGetString(POSITION_COMMENT);
    if(!UseTrailingStopFromComment(comment))
        return;

    double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
    double current_sl = PositionGetDouble(POSITION_SL);
    ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double current_price = (pos_type == POSITION_TYPE_BUY) ?
                           SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                           SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    const double stop_loss_amount = StopLossOffsetPoints(StopLossPointsFromComment(comment));

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
