//+------------------------------------------------------------------+
//|                              20260526_box_breakout_v3.mq5        |
//|                    有效波段回调策略 V3 - 顺势回调市价触达即进         |
//+------------------------------------------------------------------+
#property copyright "Pullback Strategy"
#property version   "3.03"
#property description "V3: 波段方向顺势回调, 触达回调位市价进场"

#include <Trade\Trade.mqh>

// 手数计算方式
enum ENUM_LOT_SIZE_MODE {
    LOT_SIZE_FIXED = 0,        // 固定手数
    LOT_SIZE_RISK_PERCENT = 1  // 结余风险比例(RiskPercent)
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

input group "=== 回调交易参数 ==="
input bool     InpEnableTrade = true;           // 启用回调交易
input double   InpPullbackRatio = 0.618;        // 回调比例(0-1, 从波端向对侧)
input int      InpStopLossPoints = 80;          // 止损点数
input int      InpTakeProfitPoints = 120;       // 止盈点数
input bool     InpRetryAfterStopLoss = false;   // 止损出局后允许再进一次

input group "=== 仓位管理模式 ==="
input ENUM_LOT_SIZE_MODE InpLotSizeMode = LOT_SIZE_RISK_PERCENT; // 手数模式
input double   InpFixedLots = 0.01;             // 固定手数
input double   InpRiskPercent = 5.0;            // 每笔风险占结余%
input double   InpMaxLots = 10.0;               // 单笔最大手数

input group "=== 其他参数 ==="
input bool     InpCloseManualOrders = true;     // 禁止手工单
input int      InpMagicNumber = 20260529;       // EA魔术号
input bool     InpShowExtremeMarkers = false;   // 显示极值点标记
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
    bool exists;
    double high_price;
    double low_price;
    datetime high_time;
    datetime low_time;
    datetime update_time;
    bool long_used;
    bool short_used;
    bool long_sl_retry_done;
    bool short_sl_retry_done;
    double range_percent;
};

ValidWaveInfo latest_wave;

double g_sync_wave_high = 0.0;
double g_sync_wave_low = 0.0;

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
double RangePercent(const double high, const double low);
bool IsWaveTradeEligible();
bool IsBullishWave();
bool IsBearishWave();
void MarkWaveLongUsed();
void MarkWaveShortUsed();
void HandleStopLossRetryOnDeal(const ulong deal_ticket);
int CheckBreakout(int index, const MqlRates &rates[], const double &ma[]);
void FilterBreakouts(const int &breakout_bars[], const int &breakout_types[],
                    const MqlRates &rates[], int &filtered_bars[], int &filtered_types[]);
bool IsEaTradeComment(const string &comment);
bool CalcEntrySlTp(const ENUM_POSITION_TYPE pos_type, const double entry_price,
                   double &sl, double &tp);
double CalculateLotSize(const int sl_points);
double NormalizeVolumeLots(double lots);
void ManagePositions();
void CheckAndCloseManualOrders();
bool ParseHHMMToMinutes(const string hhmm, int &minutes);
bool ParseTradeSessionsFromString(const string spec);
int BeijingMinutesOfDay();
bool IsWithinTradeSession();
void EnforceTradeSessionOnTick();
void LogDealFees(const ulong deal_ticket);
void CheckPullbackEntryOnTick();
void EnsureWaveStructureSynced();
bool OpenPullbackMarket(const ENUM_POSITION_TYPE pos_type, const double lots, const string &comment);
bool TryOpenPullbackLong(const double buy_level, const double range_high, const double range_low);
bool TryOpenPullbackShort(const double sell_level, const double range_high, const double range_low);
string BuildPullbackComment(const bool is_long, const int range_pts, const double level);
bool ParsePullbackSideFromComment(const string &comment, bool &is_long);
bool HasEaPositionOfType(const ENUM_POSITION_TYPE pos_type);
double PullbackBuyLevel(const double high, const double low);
double PullbackSellLevel(const double high, const double low);
double PointsToPriceDistance(const int points);

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

    if(InpPullbackRatio <= 0.0 || InpPullbackRatio >= 1.0) {
        Print("【参数错误】回调比例须在(0,1)之间, 当前=", InpPullbackRatio);
        return(INIT_PARAMETERS_INCORRECT);
    }

    if(InpStopLossPoints <= 0) {
        Print("【参数错误】止损点数须大于0");
        return(INIT_PARAMETERS_INCORRECT);
    }

    // 设置交易参数
    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetDeviationInPoints(10);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    MathSrand((uint)(TimeLocal() ^ InpMagicNumber ^ ChartID()));

    // 清理旧版遗留的 PB 限价挂单
    for(int i = OrdersTotal() - 1; i >= 0; i--) {
        const ulong ticket = OrderGetTicket(i);
        if(ticket == 0 || !OrderSelect(ticket))
            continue;
        if(OrderGetString(ORDER_SYMBOL) != _Symbol)
            continue;
        if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
            continue;
        if(StringFind(OrderGetString(ORDER_COMMENT), "PB") == 0)
            trade.OrderDelete(ticket);
    }

    // 初始化最新有效波段
    latest_wave.exists = false;
    latest_wave.high_price = 0;
    latest_wave.low_price = 0;
    latest_wave.high_time = 0;
    latest_wave.low_time = 0;
    latest_wave.update_time = 0;
    latest_wave.long_used = false;
    latest_wave.short_used = false;
    latest_wave.long_sl_retry_done = false;
    latest_wave.short_sl_retry_done = false;

    g_sync_wave_high = 0.0;
    g_sync_wave_low = 0.0;

    Print("========================================");
    Print("20260526_box_breakout_v3 初始化成功");
    Print("品种:", _Symbol, " Magic:", InpMagicNumber);
    Print("策略: 有效波段顺势回调 市价触达即进 比例=", DoubleToString(InpPullbackRatio, 3),
          " SL=", InpStopLossPoints, " TP=", InpTakeProfitPoints);
    Print("结构有效波段: ", InpMinWavePercent, "% - ", InpMaxWavePercent, "%");
    Print("回调交易:", (InpEnableTrade ? "开" : "关"));
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

    Print("回调交易策略EA V3已卸载");
}

//+------------------------------------------------------------------+
//| 日志：成交手续费/库存费/净利(来自测试器或券商 deal 记录)              |
//+------------------------------------------------------------------+
void LogDealFees(const ulong deal_ticket)
{
    if(!HistoryDealSelect(deal_ticket))
        return;

    const string comment = HistoryDealGetString(deal_ticket, DEAL_COMMENT);
    if(StringFind(comment, "PB") != 0)
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
        if(IsEaTradeComment(deal_comment)) {
            bool is_long = false;
            if(ParsePullbackSideFromComment(deal_comment, is_long)) {
                if(is_long)
                    MarkWaveLongUsed();
                else
                    MarkWaveShortUsed();
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

    // 3. 时段过滤(北京时间)
    EnforceTradeSessionOnTick();
    if(InpEnableTradeSessionFilter && !IsWithinTradeSession()) {
        ManagePositions();
        return;
    }

    // 4. 回调区触达 → 市价开仓
    CheckPullbackEntryOnTick();

    // 5. 管理持仓
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
                latest_wave.high_time = high_time;
                latest_wave.low_time = low_time;
                latest_wave.update_time = extremes[i].time;
                latest_wave.range_percent = RangePercent(high, low);

                if(high != prev_high) {
                    latest_wave.long_used = false;
                    latest_wave.short_used = false;
                    latest_wave.long_sl_retry_done = false;
                    latest_wave.short_sl_retry_done = false;
                }
                if(low != prev_low) {
                    latest_wave.long_used = false;
                    latest_wave.short_used = false;
                    latest_wave.long_sl_retry_done = false;
                    latest_wave.short_sl_retry_done = false;
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
//| 振幅 / 交易资格 / 已用标记                                          |
//+------------------------------------------------------------------+
double RangePercent(const double high, const double low)
{
    const double mid = (high + low) * 0.5;
    if(mid <= 0.0)
        return 0.0;
    return (high - low) / mid * 100.0;
}

bool IsWaveTradeEligible()
{
    return (InpEnableTrade && latest_wave.exists);
}

bool IsBullishWave()
{
    return (latest_wave.exists && latest_wave.high_time >= latest_wave.low_time);
}

bool IsBearishWave()
{
    return (latest_wave.exists && latest_wave.low_time > latest_wave.high_time);
}

void MarkWaveLongUsed()
{
    latest_wave.long_used = true;
}

void MarkWaveShortUsed()
{
    latest_wave.short_used = true;
}

void HandleStopLossRetryOnDeal(const ulong deal_ticket)
{
    if(!InpRetryAfterStopLoss)
        return;
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

    string entry_comment = "";
    for(int i = 0; i < HistoryDealsTotal(); i++) {
        const ulong in_ticket = HistoryDealGetTicket(i);
        if(in_ticket == 0)
            continue;
        if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(in_ticket, DEAL_ENTRY) != DEAL_ENTRY_IN)
            continue;
        entry_comment = HistoryDealGetString(in_ticket, DEAL_COMMENT);
        break;
    }
    if(entry_comment == "" || StringFind(entry_comment, "PB") != 0)
        return;

    bool is_long = false;
    if(!ParsePullbackSideFromComment(entry_comment, is_long))
        return;

    if(is_long) {
        if(latest_wave.long_sl_retry_done)
            return;
        latest_wave.long_used = false;
        latest_wave.long_sl_retry_done = true;
    } else {
        if(latest_wave.short_sl_retry_done)
            return;
        latest_wave.short_used = false;
        latest_wave.short_sl_retry_done = true;
    }
    Print("【回调】止损出局, 允许同方向再进一次 ", entry_comment);
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
//| 回调交易逻辑                                                       |
//+------------------------------------------------------------------+
bool IsEaTradeComment(const string &comment)
{
    return (StringFind(comment, "PB") == 0);
}

double PointsToPriceDistance(const int points)
{
    if(points <= 0)
        return 0.0;
    return (double)points * _Point;
}

double PullbackBuyLevel(const double high, const double low)
{
    const double range = high - low;
    if(range <= 0.0)
        return 0.0;
    return NormalizeDouble(high - InpPullbackRatio * range, _Digits);
}

double PullbackSellLevel(const double high, const double low)
{
    const double range = high - low;
    if(range <= 0.0)
        return 0.0;
    return NormalizeDouble(low + InpPullbackRatio * range, _Digits);
}

string BuildPullbackComment(const bool is_long, const int range_pts, const double level)
{
    return StringFormat("PB%d%c@%.*f",
                        range_pts, (is_long ? 'B' : 'S'),
                        _Digits, level);
}

bool ParsePullbackSideFromComment(const string &comment, bool &is_long)
{
    const int at_pos = StringFind(comment, "@");
    if(at_pos < 3)
        return false;
    const ushort ch = StringGetCharacter(comment, at_pos - 1);
    if(ch == 'B') {
        is_long = true;
        return true;
    }
    if(ch == 'S') {
        is_long = false;
        return true;
    }
    return false;
}

void EnsureWaveStructureSynced()
{
    if(!latest_wave.exists) {
        g_sync_wave_high = 0.0;
        g_sync_wave_low = 0.0;
        return;
    }

    if(MathAbs(latest_wave.high_price - g_sync_wave_high) > _Point * 0.5 ||
       MathAbs(latest_wave.low_price - g_sync_wave_low) > _Point * 0.5) {
        g_sync_wave_high = latest_wave.high_price;
        g_sync_wave_low = latest_wave.low_price;
    }
}

bool HasEaPositionOfType(const ENUM_POSITION_TYPE pos_type)
{
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(!PositionSelectByTicket(PositionGetTicket(i)))
            continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;
        if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == pos_type)
            return true;
    }
    return false;
}

bool OpenPullbackMarket(const ENUM_POSITION_TYPE pos_type, const double lots, const string &comment)
{
    if(lots <= 0.0)
        return false;

    const double entry_price = (pos_type == POSITION_TYPE_BUY) ?
        SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
        SymbolInfoDouble(_Symbol, SYMBOL_BID);

    double sl = 0.0, tp = 0.0;
    if(!CalcEntrySlTp(pos_type, entry_price, sl, tp))
        return false;

    trade.SetExpertMagicNumber(InpMagicNumber);
    if(pos_type == POSITION_TYPE_BUY)
        return trade.Buy(lots, _Symbol, 0.0, sl, tp, comment);
    if(pos_type == POSITION_TYPE_SELL)
        return trade.Sell(lots, _Symbol, 0.0, sl, tp, comment);
    return false;
}

bool TryOpenPullbackLong(const double buy_level, const double range_high, const double range_low)
{
    if(latest_wave.long_used || HasEaPositionOfType(POSITION_TYPE_BUY))
        return false;

    const int range_pts = (int)MathRound(MathAbs(range_high - range_low) / _Point);
    const string comment = BuildPullbackComment(true, range_pts, buy_level);
    const double lots = CalculateLotSize(InpStopLossPoints);
    if(lots <= 0.0)
        return false;

    if(!OpenPullbackMarket(POSITION_TYPE_BUY, lots, comment)) {
        Print("【回调】做多开仓失败 ", comment,
              " 错误:", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
        return false;
    }

    latest_wave.long_used = true;
    Print("【回调】做多 ", comment,
          " 回调位=", DoubleToString(buy_level, _Digits),
          " Ask=", DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_ASK), _Digits),
          " 手数=", DoubleToString(lots, 2));
    return true;
}

bool TryOpenPullbackShort(const double sell_level, const double range_high, const double range_low)
{
    if(latest_wave.short_used || HasEaPositionOfType(POSITION_TYPE_SELL))
        return false;

    const int range_pts = (int)MathRound(MathAbs(range_high - range_low) / _Point);
    const string comment = BuildPullbackComment(false, range_pts, sell_level);
    const double lots = CalculateLotSize(InpStopLossPoints);
    if(lots <= 0.0)
        return false;

    if(!OpenPullbackMarket(POSITION_TYPE_SELL, lots, comment)) {
        Print("【回调】做空开仓失败 ", comment,
              " 错误:", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
        return false;
    }

    latest_wave.short_used = true;
    Print("【回调】做空 ", comment,
          " 回调位=", DoubleToString(sell_level, _Digits),
          " Bid=", DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits),
          " 手数=", DoubleToString(lots, 2));
    return true;
}

void CheckPullbackEntryOnTick()
{
    if(!IsWaveTradeEligible())
        return;

    EnsureWaveStructureSynced();

    const double high = latest_wave.high_price;
    const double low = latest_wave.low_price;
    if(high <= low)
        return;

    const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    const double buy_level = PullbackBuyLevel(high, low);
    const double sell_level = PullbackSellLevel(high, low);

    // 顺势: 先低后高 → 做多回调; 先高后低 → 做空回调
    if(IsBullishWave() && buy_level > 0.0 && ask <= buy_level + _Point * 0.5)
        TryOpenPullbackLong(buy_level, high, low);

    if(IsBearishWave() && sell_level > 0.0 && bid >= sell_level - _Point * 0.5)
        TryOpenPullbackShort(sell_level, high, low);
}

bool CalcEntrySlTp(const ENUM_POSITION_TYPE pos_type, const double entry_price,
                   double &sl, double &tp)
{
    if(InpStopLossPoints <= 0)
        return false;

    const double sl_dist = PointsToPriceDistance(InpStopLossPoints);
    const double tp_dist = PointsToPriceDistance(InpTakeProfitPoints);
    const int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    const double min_stop_distance = (stops_level > 0) ? stops_level * _Point : 0.0;

    sl = 0.0;
    tp = 0.0;

    if(pos_type == POSITION_TYPE_BUY) {
        sl = NormalizeDouble(entry_price - sl_dist, _Digits);
        if(InpTakeProfitPoints > 0)
            tp = NormalizeDouble(entry_price + tp_dist, _Digits);
    } else if(pos_type == POSITION_TYPE_SELL) {
        sl = NormalizeDouble(entry_price + sl_dist, _Digits);
        if(InpTakeProfitPoints > 0)
            tp = NormalizeDouble(entry_price - tp_dist, _Digits);
    } else {
        return false;
    }

    if(min_stop_distance > 0.0) {
        if(pos_type == POSITION_TYPE_BUY) {
            if(entry_price - sl < min_stop_distance)
                sl = NormalizeDouble(entry_price - min_stop_distance, _Digits);
            if(tp > 0.0 && tp - entry_price < min_stop_distance)
                tp = NormalizeDouble(entry_price + min_stop_distance, _Digits);
        } else {
            if(sl - entry_price < min_stop_distance)
                sl = NormalizeDouble(entry_price + min_stop_distance, _Digits);
            if(tp > 0.0 && entry_price - tp < min_stop_distance)
                tp = NormalizeDouble(entry_price - min_stop_distance, _Digits);
        }
    }
    return true;
}

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

double CalculateLotSize(const int sl_points)
{
    double lots = InpFixedLots;

    if(InpLotSizeMode == LOT_SIZE_RISK_PERCENT && InpRiskPercent > 0.0 && sl_points > 0) {
        const double balance = AccountInfoDouble(ACCOUNT_BALANCE);
        const double risk_money = balance * InpRiskPercent / 100.0;
        const double sl_distance = PointsToPriceDistance(sl_points);

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

void ManagePositions()
{
}

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
