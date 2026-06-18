//+------------------------------------------------------------------+
//|                              20260526_box_breakout_v2.mq5        |
//|                    聚合箱体突破策略 V2 - 收盘确认突破              |
//+------------------------------------------------------------------+
#property copyright "Breakout Strategy"
#property version   "2.02"
#property description "V2: 收盘价突破极值后市价开仓, 成交后设SL/TP"

#include <Trade\Trade.mqh>

// 手数计算方式
enum ENUM_LOT_SIZE_MODE {
    LOT_SIZE_FIXED = 0,        // 固定手数
    LOT_SIZE_RISK_PERCENT = 1  // 结余风险比例(RiskPercent)
};

// 破高/破低开仓方向
enum ENUM_BREAKOUT_DIRECTION {
    BREAKOUT_DIR_FOLLOW = 0,  // 顺势(破高多/破低空)
    BREAKOUT_DIR_REVERSE = 1, // 反向(破高空/破低多)
    BREAKOUT_DIR_RANDOM = 2   // 随机(每段结构随机顺势/反向)
};

// 止盈模式
enum ENUM_TP_MODE {
    TP_MODE_FIXED_POINTS = 0,  // 固定点数
    TP_MODE_RISK_REWARD = 1    // 盈亏比
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
input bool     InpLargeWaveRetryAfterStopLoss = false; // 边界止损后再开一单
input int      InpLargeWaveSlBarOffsetPoints = 30;     // 止损相对确认K高/低偏移(点)
input ENUM_TP_MODE InpLargeWaveTpMode = TP_MODE_FIXED_POINTS; // 止盈模式
input int      InpLargeWaveTakeProfitPoints = 120;     // 止盈点数(固定模式)
input double   InpLargeWaveRiskRewardRatio = 2.0;      // 盈亏比(TP距离=SL距离×该值)
input bool     InpLargeWaveUseTrailingStop = false;  // 使用移动止损
input int      InpLargeWaveTrailingStopPoints = 500; // 移动止损点数(启动后跟踪距离)

input group "=== 聚合箱体机制参数 ==="
input bool     InpEnableBoxTrade = true;        // 启用聚合箱体突破机制
input ENUM_BREAKOUT_DIRECTION InpBoxDirection = BREAKOUT_DIR_FOLLOW; // 开仓方向
input double   InpBoxWaveMinPercent = 0.1;      // 成箱波段振幅下限%(>=)
input double   InpBoxWaveMaxPercent = 0.25;     // 成箱波段振幅上限%(<=)
input int      InpBoxMinWaves = 1;              // 成箱最少有效波段数
input int      InpBoxMaxWaves = 3;              // 成箱最多有效波段数(0=不限制)
input bool     InpBoxRetryAfterStopLoss = false; // 边界止损后再开一单
input int      InpBoxSlBarOffsetPoints = 30;   // 止损相对确认K高/低偏移(点)
input ENUM_TP_MODE InpBoxTpMode = TP_MODE_FIXED_POINTS; // 止盈模式
input int      InpBoxTakeProfitPoints = 120;   // 止盈点数(固定模式)
input double   InpBoxRiskRewardRatio = 2.0;    // 盈亏比(TP距离=SL距离×该值)
input bool     InpBoxUseTrailingStop = false;   // 使用移动止损
input int      InpBoxTrailingStopPoints = 500;  // 移动止损点数(启动后跟踪距离)

input group "=== 仓位管理模式 ==="
input ENUM_LOT_SIZE_MODE InpLotSizeMode = LOT_SIZE_RISK_PERCENT; // 手数模式
input double   InpFixedLots = 0.01;             // 固定手数
input double   InpRiskPercent = 5.0;            // 每笔风险占结余%
input double   InpMaxLots = 10.0;               // 单笔最大手数

input group "=== 其他参数 ==="
input bool     InpCloseManualOrders = true;     // 禁止手工单
input int      InpMagicNumber = 20260528;       // EA魔术号
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
ENUM_BREAKOUT_DIRECTION g_lw_resolved_dir = BREAKOUT_DIR_FOLLOW;
ENUM_BREAKOUT_DIRECTION g_box_resolved_dir = BREAKOUT_DIR_FOLLOW;
datetime g_last_bar_time = 0;

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
long PosTypeOnHighBreakout(const ENUM_BREAKOUT_DIRECTION dir);
long PosTypeOnLowBreakout(const ENUM_BREAKOUT_DIRECTION dir);
string BreakoutDirectionInputLabel(const ENUM_BREAKOUT_DIRECTION dir);
void RollRandomLargeWaveDirection();
void RollRandomBoxDirection();
ENUM_BREAKOUT_DIRECTION EffectiveLargeWaveDirection();
ENUM_BREAKOUT_DIRECTION EffectiveBoxDirection();
bool IsEaTradeComment(const string &comment);
bool IsBoxTradeComment(const string &comment);
bool CalcV2SlTp(const ENUM_POSITION_TYPE pos_type, const double open_price,
                const double bar_high, const double bar_low, const bool is_box,
                double &sl, double &tp);
void ClampV2SlTpForModify(const ENUM_POSITION_TYPE pos_type, double &sl, double &tp);
bool V2ProtectionApplied(const double current_sl, const double current_tp);
void ApplyV2ProtectionToPosition(const ulong ticket);
double CalculateLotSizeFromSlDistance(const double sl_distance);
double NormalizeVolumeLots(double lots);
void ManagePositions();
void CheckTrailingStop(ulong ticket);
bool UseTrailingStopFromComment(const string &comment);
int TrailingStopPointsFromComment(const string &comment);
double PointsToPriceDistance(const int points);
string TpModeLabel(const ENUM_TP_MODE mode);
void CheckAndCloseManualOrders();
bool ParseHHMMToMinutes(const string hhmm, int &minutes);
bool ParseTradeSessionsFromString(const string spec);
int BeijingMinutesOfDay();
bool IsWithinTradeSession();
void EnforceTradeSessionOnTick();
void LogDealFees(const ulong deal_ticket);
void MarkExtremeUsedFromComment(const string &comment);
bool CheckNewBarAndProcessCloseBreakouts();
void EnsureLargeWaveStructureSynced();
void EnsureBoxStructureSynced();
bool TryCloseBreakoutAtExtreme(const bool at_high, const double extreme_price,
                               const double range_high, const double range_low,
                               const double bar_close, const double bar_high,
                               const double bar_low, const ENUM_BREAKOUT_DIRECTION dir,
                               const bool is_box);
void MarkExtremeInvalidated(const bool at_high, const bool is_box);
bool OpenBreakoutMarket(const ENUM_POSITION_TYPE pos_type, const double lots,
                        const string &comment);
bool ParseV2BarFromComment(const string &comment, double &bar_high, double &bar_low);
bool ParseExtremeSideFromComment(const string &comment, bool &at_high);
string BuildV2TradeComment(const string &prefix, const int range_pts, const bool at_high,
                           const double extreme_price, const double bar_high,
                           const double bar_low);
double EstimateV2SlDistance(const ENUM_POSITION_TYPE pos_type, const double entry_price,
                            const double bar_high, const double bar_low, const bool is_box);

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

    if(in_session != g_last_tick_in_trade_session) {
        MqlDateTime dt;
        TimeToStruct(TimeGMT() + 8 * 3600, dt);
        Print("【交易时段】北京时间 ",
              StringFormat("%02d:%02d", dt.hour, dt.min),
              in_session ? " 进入可交易时段" : " 离开可交易时段");
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
    MathSrand((uint)(TimeLocal() ^ InpMagicNumber ^ ChartID()));

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
    g_lw_resolved_dir = BREAKOUT_DIR_FOLLOW;
    g_box_resolved_dir = BREAKOUT_DIR_FOLLOW;
    g_last_bar_time = iTime(_Symbol, InpTimeframe, 0);

    Print("========================================");
    Print("20260526_box_breakout_v2 初始化成功");
    Print("品种:", _Symbol, " Magic:", InpMagicNumber);
    Print("入场: 收盘价突破极值后, 同tick市价开仓");
    Print("结构有效波段: ", InpMinWavePercent, "% - ", InpMaxWavePercent, "%");
    Print("大波段突破:", (InpEnableLargeWaveTrade ? "开" : "关"),
          " (", InpLargeWaveMinPercent, "%, ", InpLargeWaveMaxPercent, "%] 方向:",
          BreakoutDirectionInputLabel(InpLargeWaveDirection),
          " SL偏移:", InpLargeWaveSlBarOffsetPoints, "点 TP:",
          TpModeLabel(InpLargeWaveTpMode));
    Print("聚合箱体:", (InpEnableBoxTrade ? "开" : "关"),
          " 成箱波段 [", InpBoxWaveMinPercent, "%, ", InpBoxWaveMaxPercent, "%] 段数",
          InpBoxMinWaves, "-", (InpBoxMaxWaves > 0 ? IntegerToString(InpBoxMaxWaves) : "不限"),
          " 方向:", BreakoutDirectionInputLabel(InpBoxDirection),
          " SL偏移:", InpBoxSlBarOffsetPoints, "点 TP:",
          TpModeLabel(InpBoxTpMode));
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

    Print("突破交易策略EA V2已卸载");
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
        if(IsEaTradeComment(deal_comment))
            MarkExtremeUsedFromComment(deal_comment);
        if(trans.position > 0)
            ApplyV2ProtectionToPosition(trans.position);
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

    // 3. 时段过滤(北京时间)
    EnforceTradeSessionOnTick();
    if(InpEnableTradeSessionFilter && !IsWithinTradeSession()) {
        ManagePositions();
        return;
    }

    // 4. K线收盘确认突破 → 市价开仓
    CheckNewBarAndProcessCloseBreakouts();

    // 5. 管理已有持仓(成交后设SL/TP重试)
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
//| 止损出局后按机制允许同边界再开一次                                    |
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
        break;
    }
    if(entry_pos_type < 0 || entry_comment == "")
        return;

    bool at_high = false;
    if(!ParseExtremeSideFromComment(entry_comment, at_high))
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
        Print("【大波段】止损出局,允许边界再开一次");
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
        Print("【聚合箱体】止损出局,允许边界再开一次");
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
//| 收盘确认突破 → 市价开仓                                              |
//+------------------------------------------------------------------+
string BreakoutDirectionInputLabel(const ENUM_BREAKOUT_DIRECTION dir)
{
    if(dir == BREAKOUT_DIR_REVERSE)
        return "反向";
    if(dir == BREAKOUT_DIR_RANDOM)
        return "随机";
    return "顺势";
}

void RollRandomLargeWaveDirection()
{
    g_lw_resolved_dir = ((MathRand() & 1) != 0) ? BREAKOUT_DIR_FOLLOW : BREAKOUT_DIR_REVERSE;
    Print("【大波段】随机开仓方向: ", BreakoutDirectionInputLabel(g_lw_resolved_dir));
}

void RollRandomBoxDirection()
{
    g_box_resolved_dir = ((MathRand() & 1) != 0) ? BREAKOUT_DIR_FOLLOW : BREAKOUT_DIR_REVERSE;
    Print("【聚合箱体】随机开仓方向: ", BreakoutDirectionInputLabel(g_box_resolved_dir));
}

ENUM_BREAKOUT_DIRECTION EffectiveLargeWaveDirection()
{
    if(InpLargeWaveDirection != BREAKOUT_DIR_RANDOM)
        return InpLargeWaveDirection;
    return g_lw_resolved_dir;
}

ENUM_BREAKOUT_DIRECTION EffectiveBoxDirection()
{
    if(InpBoxDirection != BREAKOUT_DIR_RANDOM)
        return InpBoxDirection;
    return g_box_resolved_dir;
}

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

string TpModeLabel(const ENUM_TP_MODE mode)
{
    if(mode == TP_MODE_RISK_REWARD)
        return "盈亏比";
    return "固定点数";
}

bool IsEaTradeComment(const string &comment)
{
    return (StringFind(comment, "LW") == 0 || StringFind(comment, "BX") == 0);
}

bool IsBoxTradeComment(const string &comment)
{
    return (StringFind(comment, "BX") == 0);
}

string BuildV2TradeComment(const string &prefix, const int range_pts, const bool at_high,
                           const double extreme_price, const double bar_high,
                           const double bar_low)
{
    return StringFormat("%s%d%c@%.*f#%.*f,%.*f",
                        prefix, range_pts, (at_high ? 'H' : 'L'),
                        _Digits, extreme_price,
                        _Digits, bar_high,
                        _Digits, bar_low);
}

bool ParseExtremeSideFromComment(const string &comment, bool &at_high)
{
    const int at_pos = StringFind(comment, "@");
    if(at_pos < 3)
        return false;
    const ushort ch = StringGetCharacter(comment, at_pos - 1);
    if(ch == 'H') {
        at_high = true;
        return true;
    }
    if(ch == 'L') {
        at_high = false;
        return true;
    }
    return false;
}

bool ParseV2BarFromComment(const string &comment, double &bar_high, double &bar_low)
{
    const int hash = StringFind(comment, "#");
    if(hash < 0)
        return false;
    string part = StringSubstr(comment, hash + 1);
    string pieces[];
    if(StringSplit(part, ',', pieces) != 2)
        return false;
    bar_high = StringToDouble(pieces[0]);
    bar_low = StringToDouble(pieces[1]);
    return (bar_high > 0.0 && bar_low > 0.0);
}

void MarkExtremeUsedFromComment(const string &comment)
{
    bool at_high = false;
    if(!ParseExtremeSideFromComment(comment, at_high))
        return;

    if(StringFind(comment, "LW") == 0) {
        if(at_high)
            MarkLargeWaveHighUsed();
        else
            MarkLargeWaveLowUsed();
    } else if(StringFind(comment, "BX") == 0) {
        if(at_high)
            MarkBoxHighUsed();
        else
            MarkBoxLowUsed();
    }
}

void EnsureLargeWaveStructureSynced()
{
    if(!IsLargeWaveTradeEligible()) {
        g_sync_wave_high = 0.0;
        g_sync_wave_low = 0.0;
        return;
    }

    if(MathAbs(latest_wave.high_price - g_sync_wave_high) > _Point * 0.5 ||
       MathAbs(latest_wave.low_price - g_sync_wave_low) > _Point * 0.5) {
        g_sync_wave_high = latest_wave.high_price;
        g_sync_wave_low = latest_wave.low_price;
        if(InpLargeWaveDirection == BREAKOUT_DIR_RANDOM)
            RollRandomLargeWaveDirection();
    }
}

void EnsureBoxStructureSynced()
{
    if(!InpEnableBoxTrade || !active_box.exists) {
        g_sync_box_high = 0.0;
        g_sync_box_low = 0.0;
        return;
    }

    if(MathAbs(active_box.high_price - g_sync_box_high) > _Point * 0.5 ||
       MathAbs(active_box.low_price - g_sync_box_low) > _Point * 0.5) {
        g_sync_box_high = active_box.high_price;
        g_sync_box_low = active_box.low_price;
        if(InpBoxDirection == BREAKOUT_DIR_RANDOM)
            RollRandomBoxDirection();
    }
}

double EstimateV2SlDistance(const ENUM_POSITION_TYPE pos_type, const double entry_price,
                            const double bar_high, const double bar_low, const bool is_box)
{
    const int offset_pts = is_box ? InpBoxSlBarOffsetPoints : InpLargeWaveSlBarOffsetPoints;
    const double offset = (double)offset_pts * _Point;

    if(pos_type == POSITION_TYPE_BUY) {
        const double sl = bar_low - offset;
        return entry_price - sl;
    }
    const double sl = bar_high + offset;
    return sl - entry_price;
}

bool OpenBreakoutMarket(const ENUM_POSITION_TYPE pos_type, const double lots,
                        const string &comment)
{
    if(lots <= 0.0)
        return false;

    trade.SetExpertMagicNumber(InpMagicNumber);
    if(pos_type == POSITION_TYPE_BUY)
        return trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0, comment);
    if(pos_type == POSITION_TYPE_SELL)
        return trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0, comment);
    return false;
}

void MarkExtremeInvalidated(const bool at_high, const bool is_box)
{
    if(is_box) {
        if(at_high)
            MarkBoxHighUsed();
        else
            MarkBoxLowUsed();
    } else {
        if(at_high)
            MarkLargeWaveHighUsed();
        else
            MarkLargeWaveLowUsed();
    }
}

bool TryCloseBreakoutAtExtreme(const bool at_high, const double extreme_price,
                               const double range_high, const double range_low,
                               const double bar_close, const double bar_high,
                               const double bar_low, const ENUM_BREAKOUT_DIRECTION dir,
                               const bool is_box)
{
    const string prefix = is_box ? "BX" : "LW";
    const bool bar_penetrated = at_high ?
        (bar_high > extreme_price + _Point * 0.5) :
        (bar_low < extreme_price - _Point * 0.5);
    if(!bar_penetrated)
        return false;

    const bool close_confirmed = at_high ?
        (bar_close > extreme_price) :
        (bar_close < extreme_price);
    if(!close_confirmed) {
        MarkExtremeInvalidated(at_high, is_box);
        Print("【", prefix, "】极值首次刺穿但收盘未确认, 标记失效 ",
              (at_high ? "高" : "低"), "=", DoubleToString(extreme_price, _Digits),
              " 收盘=", DoubleToString(bar_close, _Digits),
              " K高=", DoubleToString(bar_high, _Digits),
              " K低=", DoubleToString(bar_low, _Digits));
        return false;
    }

    const ENUM_POSITION_TYPE pos_type = at_high ?
        (ENUM_POSITION_TYPE)PosTypeOnHighBreakout(dir) :
        (ENUM_POSITION_TYPE)PosTypeOnLowBreakout(dir);
    const double entry_price = (pos_type == POSITION_TYPE_BUY) ?
        SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
        SymbolInfoDouble(_Symbol, SYMBOL_BID);
    const double sl_distance = EstimateV2SlDistance(pos_type, entry_price, bar_high, bar_low, is_box);
    if(sl_distance <= _Point * 0.5)
        return false;

    const double lots = CalculateLotSizeFromSlDistance(sl_distance);
    if(lots <= 0.0)
        return false;

    const int range_pts = (int)MathRound(MathAbs(range_high - range_low) / _Point);
    const string comment = BuildV2TradeComment(prefix, range_pts, at_high, extreme_price,
                                               bar_high, bar_low);

    if(!OpenBreakoutMarket(pos_type, lots, comment)) {
        Print("【", prefix, "】收盘突破开仓失败 ", comment,
              " 错误:", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
        return false;
    }

    Print("【", prefix, "】收盘突破开仓 ", comment,
          " 收盘=", DoubleToString(bar_close, _Digits),
          " 极值=", DoubleToString(extreme_price, _Digits),
          " 手数=", DoubleToString(lots, 2));
    return true;
}

bool CheckNewBarAndProcessCloseBreakouts()
{
    const datetime bar_time = iTime(_Symbol, InpTimeframe, 0);
    if(bar_time == 0)
        return false;
    if(bar_time == g_last_bar_time)
        return false;

    g_last_bar_time = bar_time;

    MqlRates closed_bar[];
    if(CopyRates(_Symbol, InpTimeframe, 1, 1, closed_bar) != 1)
        return false;

    const double bar_close = closed_bar[0].close;
    const double bar_high = closed_bar[0].high;
    const double bar_low = closed_bar[0].low;

    EnsureLargeWaveStructureSynced();
    if(IsLargeWaveTradeEligible()) {
        const double wh = latest_wave.high_price;
        const double wl = latest_wave.low_price;
        const ENUM_BREAKOUT_DIRECTION lw_dir = EffectiveLargeWaveDirection();

        if(!latest_wave.high_used)
            TryCloseBreakoutAtExtreme(true, wh, wh, wl, bar_close, bar_high, bar_low, lw_dir, false);
        if(!latest_wave.low_used)
            TryCloseBreakoutAtExtreme(false, wl, wh, wl, bar_close, bar_high, bar_low, lw_dir, false);
    }

    EnsureBoxStructureSynced();
    if(InpEnableBoxTrade && active_box.exists) {
        const double bh = active_box.high_price;
        const double bl = active_box.low_price;
        const ENUM_BREAKOUT_DIRECTION bx_dir = EffectiveBoxDirection();

        if(!active_box.high_used)
            TryCloseBreakoutAtExtreme(true, bh, bh, bl, bar_close, bar_high, bar_low, bx_dir, true);
        if(!active_box.low_used)
            TryCloseBreakoutAtExtreme(false, bl, bh, bl, bar_close, bar_high, bar_low, bx_dir, true);
    }

    return true;
}

//+------------------------------------------------------------------+
//| V2: 成交后按确认K线设SL, 按参数设TP                                |
//+------------------------------------------------------------------+
bool CalcV2SlTp(const ENUM_POSITION_TYPE pos_type, const double open_price,
                const double bar_high, const double bar_low, const bool is_box,
                double &sl, double &tp)
{
    const int offset_pts = is_box ? InpBoxSlBarOffsetPoints : InpLargeWaveSlBarOffsetPoints;
    const double offset = (double)offset_pts * _Point;
    const int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    const double min_stop_distance = (stops_level > 0) ? stops_level * _Point : 0.0;

    double sl_distance = 0.0;
    if(pos_type == POSITION_TYPE_BUY) {
        sl = NormalizeDouble(bar_low - offset, _Digits);
        sl_distance = open_price - sl;
        if(sl_distance <= _Point * 0.5)
            return false;
    } else if(pos_type == POSITION_TYPE_SELL) {
        sl = NormalizeDouble(bar_high + offset, _Digits);
        sl_distance = sl - open_price;
        if(sl_distance <= _Point * 0.5)
            return false;
    } else {
        return false;
    }

    double tp_distance = 0.0;
    const ENUM_TP_MODE tp_mode = is_box ? InpBoxTpMode : InpLargeWaveTpMode;
    if(tp_mode == TP_MODE_FIXED_POINTS) {
        const int tp_points = is_box ? InpBoxTakeProfitPoints : InpLargeWaveTakeProfitPoints;
        if(tp_points <= 0)
            return false;
        tp_distance = (double)tp_points * _Point;
    } else {
        const double rr = is_box ? InpBoxRiskRewardRatio : InpLargeWaveRiskRewardRatio;
        if(rr <= 0.0)
            return false;
        tp_distance = sl_distance * rr;
    }

    if(pos_type == POSITION_TYPE_BUY)
        tp = NormalizeDouble(open_price + tp_distance, _Digits);
    else
        tp = NormalizeDouble(open_price - tp_distance, _Digits);

    if(min_stop_distance > 0.0) {
        if(pos_type == POSITION_TYPE_BUY) {
            if(open_price - sl < min_stop_distance)
                sl = NormalizeDouble(open_price - min_stop_distance, _Digits);
            if(tp - open_price < min_stop_distance)
                tp = NormalizeDouble(open_price + min_stop_distance, _Digits);
        } else {
            if(sl - open_price < min_stop_distance)
                sl = NormalizeDouble(open_price + min_stop_distance, _Digits);
            if(open_price - tp < min_stop_distance)
                tp = NormalizeDouble(open_price - min_stop_distance, _Digits);
        }
    }
    return true;
}

void ClampV2SlTpForModify(const ENUM_POSITION_TYPE pos_type, double &sl, double &tp)
{
    const int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    if(stops_level <= 0)
        return;

    const double min_dist = stops_level * _Point;

    if(pos_type == POSITION_TYPE_BUY) {
        const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        if(sl > 0.0) {
            const double max_sl = NormalizeDouble(bid - min_dist, _Digits);
            if(sl > max_sl)
                sl = max_sl;
        }
        const double min_tp = NormalizeDouble(bid + min_dist, _Digits);
        if(tp < min_tp)
            tp = min_tp;
    } else if(pos_type == POSITION_TYPE_SELL) {
        const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        if(sl > 0.0) {
            const double min_sl = NormalizeDouble(ask + min_dist, _Digits);
            if(sl < min_sl)
                sl = min_sl;
        }
        const double max_tp = NormalizeDouble(ask - min_dist, _Digits);
        if(tp > max_tp)
            tp = max_tp;
    }
}

bool V2ProtectionApplied(const double current_sl, const double current_tp)
{
    return (current_sl > 0.0 && current_tp > 0.0);
}

void LogV2ModifyFail(const ulong ticket, const double sl, const double tp, const uint retcode)
{
    static ulong s_last_ticket = 0;
    static datetime s_last_time = 0;
    static uint s_last_retcode = 0;

    const datetime now = TimeCurrent();
    if(ticket == s_last_ticket && retcode == s_last_retcode &&
       now - s_last_time < 30)
        return;

    s_last_ticket = ticket;
    s_last_time = now;
    s_last_retcode = retcode;

    Print("【V2】设SL/TP失败 ticket=", ticket,
          " SL=", DoubleToString(sl, _Digits),
          " TP=", DoubleToString(tp, _Digits),
          " Bid=", DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits),
          " Ask=", DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_ASK), _Digits),
          " 错误:", retcode, " ", trade.ResultRetcodeDescription());
}

void ApplyV2ProtectionToPosition(const ulong ticket)
{
    if(!PositionSelectByTicket(ticket))
        return;

    const string comment = PositionGetString(POSITION_COMMENT);
    if(!IsEaTradeComment(comment))
        return;

    const ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    const double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
    const double current_sl = PositionGetDouble(POSITION_SL);
    const double current_tp = PositionGetDouble(POSITION_TP);

    if(V2ProtectionApplied(current_sl, current_tp))
        return;

    double bar_high = 0.0, bar_low = 0.0;
    if(!ParseV2BarFromComment(comment, bar_high, bar_low))
        return;

    const bool is_box = IsBoxTradeComment(comment);
    double sl = 0.0, tp = 0.0;
    if(!CalcV2SlTp(pos_type, open_price, bar_high, bar_low, is_box, sl, tp))
        return;

    ClampV2SlTpForModify(pos_type, sl, tp);

    trade.SetExpertMagicNumber(InpMagicNumber);
    if(trade.PositionModify(ticket, sl, tp)) {
        Print("【V2】成交后设SL/TP ticket=", ticket, " 开仓=", open_price,
              " SL=", sl, " TP=", tp, " ", comment);
    } else {
        LogV2ModifyFail(ticket, sl, tp, trade.ResultRetcode());
    }
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

double CalculateLotSizeFromSlDistance(const double sl_distance)
{
    double lots = InpFixedLots;

    if(InpLotSizeMode == LOT_SIZE_RISK_PERCENT && InpRiskPercent > 0.0) {
        const double balance = AccountInfoDouble(ACCOUNT_BALANCE);
        const double risk_money = balance * InpRiskPercent / 100.0;

        const double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        const double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        if(sl_distance > 0.0 && tick_size > 0.0 && tick_value > 0.0 && risk_money > 0.0) {
            const double loss_per_lot = (sl_distance / tick_size) * tick_value;
            if(loss_per_lot > 0.0)
                lots = risk_money / loss_per_lot;
        }
    }

    return NormalizeVolumeLots(lots);
}

double PointsToPriceDistance(const int points)
{
    if(points <= 0)
        return 0.0;
    return (double)points * _Point;
}

bool UseTrailingStopFromComment(const string &comment)
{
    if(StringFind(comment, "BX") == 0)
        return InpBoxUseTrailingStop;
    return InpLargeWaveUseTrailingStop;
}

int TrailingStopPointsFromComment(const string &comment)
{
    if(StringFind(comment, "BX") == 0)
        return InpBoxTrailingStopPoints;
    return InpLargeWaveTrailingStopPoints;
}

void CheckTrailingStop(ulong ticket)
{
    if(!PositionSelectByTicket(ticket))
        return;

    const string comment = PositionGetString(POSITION_COMMENT);
    if(!UseTrailingStopFromComment(comment))
        return;

    const int trail_points = TrailingStopPointsFromComment(comment);
    if(trail_points <= 0)
        return;

    const double trail_dist = PointsToPriceDistance(trail_points);
    const double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
    const double current_sl = PositionGetDouble(POSITION_SL);
    if(current_sl <= 0.0)
        return;

    const ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    const int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    const double min_dist = stops_level * _Point;

    double current_price = 0.0;
    double profit_amount = 0.0;
    double new_sl = 0.0;

    if(pos_type == POSITION_TYPE_BUY) {
        current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        profit_amount = current_price - open_price;
        if(profit_amount + _Point * 0.5 < trail_dist)
            return;

        new_sl = NormalizeDouble(current_price - trail_dist, _Digits);
        if(stops_level > 0 && current_price - new_sl < min_dist)
            new_sl = NormalizeDouble(current_price - min_dist, _Digits);
        if(new_sl >= current_price - _Point * 0.5)
            return;
        if(new_sl <= current_sl + _Point * 0.5)
            return;
    } else if(pos_type == POSITION_TYPE_SELL) {
        current_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        profit_amount = open_price - current_price;
        if(profit_amount + _Point * 0.5 < trail_dist)
            return;

        new_sl = NormalizeDouble(current_price + trail_dist, _Digits);
        if(stops_level > 0 && new_sl - current_price < min_dist)
            new_sl = NormalizeDouble(current_price + min_dist, _Digits);
        if(new_sl <= current_price + _Point * 0.5)
            return;
        if(new_sl >= current_sl - _Point * 0.5)
            return;
    } else {
        return;
    }

    const double tp = PositionGetDouble(POSITION_TP);
    trade.SetExpertMagicNumber(InpMagicNumber);
    if(trade.PositionModify(ticket, new_sl, tp)) {
        Print("【移动止损】ticket=", ticket, " 新SL=", new_sl,
              " 跟踪", trail_points, "点 现价=", DoubleToString(current_price, _Digits));
    }
}

void ManagePositions()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(!PositionSelectByTicket(PositionGetTicket(i)))
            continue;

        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;

        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;

        const ulong ticket = PositionGetTicket(i);
        ApplyV2ProtectionToPosition(ticket);
        CheckTrailingStop(ticket);
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
