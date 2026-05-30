//+------------------------------------------------------------------+
//|                                                20260516_Trade.mq5 |
//|                                      突破交易策略 - 完整交易版本    |
//+------------------------------------------------------------------+
#property copyright "Breakout Strategy"
#property version   "1.03"
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
input double   InpMinWavePercent = 0.1;         // 最小波段阈值百分比(%)
input double   InpMaxWavePercent = 10.0;        // 最大波段阈值百分比(%)
input double   InpPullbackTolerance = 0.0;      // 反向突破容忍度(%) 0=不容忍
input int      InpMinWaveBars = 3;              // 有效波段最少K线数(含两端极值所在K)

input group "=== 突破交易参数 ==="
input ENUM_BREAKOUT_DIRECTION InpBreakoutDirection = BREAKOUT_DIR_FOLLOW; // 开仓方向
input bool     InpEnablePullbackReverse = false; // 启用突破回落反向
input int      InpPullbackReverseWatchBars = 3; // 回落监测K线数(突破K+后2根=3)

input group "=== 风险管理参数 ==="
input int      InpStopLossPoints = 200;         // 止损点数
input int      InpTakeProfitPoints = 300;       // 止盈点数
input bool     InpUseTrailingStop = true;       // 使用移动止损

input group "=== 仓位管理参数 ==="
input ENUM_LOT_SIZE_MODE InpLotSizeMode = LOT_SIZE_RISK_PERCENT; // 手数模式
input double   InpFixedLots = 0.01;             // 固定手数(固定模式)
input double   InpRiskPercent = 5.0;            // 每笔风险占结余%(风险比例模式)
input double   InpMaxLots = 99.0;               // 单笔最大手数(0=仅受品种限制)
input int      InpMaxPositions = 99;            // 最大持仓笔数
input bool     InpOnePositionPerDirection = true; // 单方向最多持有一单

input group "=== 连续亏损保护 ==="
input int      InpConsecutiveLosses = 3;        // 连续亏损次数触发冷冻(0=禁用)
input int      InpFreezeBarCount = 60;          // 冷冻K线根数(0=禁用)

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
    bool high_used;                             // 高点-突破挂单已用(每极值限1次)
    bool low_used;                              // 低点-突破挂单已用(每极值限1次)
    bool high_pullback_reverse_used;            // 高点-回落反向已用(每极值限1次)
    bool low_pullback_reverse_used;             // 低点-回落反向已用(每极值限1次)
};

struct PullbackWatchState {
    bool active;
    double extreme_price;
    int bars_checked;
};

ValidWaveInfo latest_wave;                      // 最新有效波段

PullbackWatchState g_high_pullback_watch;
PullbackWatchState g_low_pullback_watch;
datetime g_pullback_bar_time_high = 0;
bool g_pullback_opened_on_bar_high = false;
datetime g_pullback_bar_time_low = 0;
bool g_pullback_opened_on_bar_low = false;

double g_sync_wave_high = 0.0;                  // 已挂单的波段高价(用于检测换波段)
double g_sync_wave_low = 0.0;

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
int CountBarsBetweenExtremeTimes(const MqlRates &rates[], const datetime t1, const datetime t2);
bool IsValidWaveByBarCount(const MqlRates &rates[], const datetime t1, const datetime t2);
void DrawExtremeMarkers(ExtremePoint &extremes[]);
void DrawLatestValidWave(double high_price, datetime high_time, double low_price, datetime low_time);
int CheckBreakout(int index, const MqlRates &rates[], const double &ma[]);
void FilterBreakouts(const int &breakout_bars[], const int &breakout_types[],
                    const MqlRates &rates[], int &filtered_bars[], int &filtered_types[]);
void SyncBreakoutPendingOrders();
void CancelAllEaPendingOrders();
void CancelEaPendingOrderType(const ENUM_ORDER_TYPE order_type);
void CancelEaPendingAtHigh();
void CancelEaPendingAtLow();
ulong FindEaPendingOrder(const ENUM_ORDER_TYPE order_type);
ENUM_ORDER_TYPE PendingTypeOnHighBreakout();
ENUM_ORDER_TYPE PendingTypeOnLowBreakout();
long PosTypeOnHighBreakout();
long PosTypeOnLowBreakout();
void SyncPendingAtExtreme(const bool at_high, const double trigger_price,
                          const double wave_high, const double wave_low, const double lots);
bool CalcPendingSlTp(const ENUM_ORDER_TYPE pending_type, const double trigger_price, double &sl, double &tp);
bool PlaceBreakoutPendingOrder(const ENUM_ORDER_TYPE pending_type, const double trigger_price,
                               const double wave_high, const double wave_low);
double GetStopLossOffset();
double GetTakeProfitOffset();
double StopLossAmountFromPositionComment(const string &comment);
double CalculateLotSize(const double wave_high, const double wave_low);
double NormalizeVolumeLots(double lots);
void ManagePositions();
void CheckTrailingStop(ulong ticket);
void CheckAndCloseManualOrders();
void CheckPullbackReverseSignals();
void TryArmPullbackWatch();
void ProcessPullbackReverseOnNewBar();
ENUM_ORDER_TYPE OrderTypeOnHighPullbackReverse();
ENUM_ORDER_TYPE OrderTypeOnLowPullbackReverse();
bool IsPullbackBarOpenAllowed(const bool for_high_extreme);
void MarkPullbackBarOpened(const bool for_high_extreme);
void SyncPullbackBarLock(const bool for_high_extreme);
bool IsPullbackOpenBlocked();
bool OpenPullbackReversePosition(ENUM_ORDER_TYPE order_type, const bool from_high_extreme,
                                 const double extreme_price, const double wave_high,
                                 const double wave_low);
bool CalcMarketSlTp(const ENUM_ORDER_TYPE order_type, const double entry_price, double &sl,
                    double &tp);

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
    latest_wave.high_pullback_reverse_used = false;
    latest_wave.low_pullback_reverse_used = false;
    g_high_pullback_watch.active = false;
    g_low_pullback_watch.active = false;

    Print("========================================");
    Print("突破交易策略EA初始化成功");
    Print("品种:", _Symbol);
    Print("K线周期:", EnumToString(InpTimeframe));
    Print("MA周期:", InpMAPeriod);
    Print("波段阈值范围: ", InpMinWavePercent, "% - ", InpMaxWavePercent, "%");
    Print("有效波段最少K线: ", InpMinWaveBars, " (两极值间含两端,<=1=不限制)");
    if(InpPullbackTolerance > 0)
        Print("反向突破容忍度: ", DoubleToString(InpPullbackTolerance, 1), "% (启用)");
    else
        Print("反向突破容忍度: 0% (禁用 - 保持原有逻辑)");
    Print("止损:", InpStopLossPoints, "点 | 止盈:", InpTakeProfitPoints, "点");
    Print("移动止损:", (InpUseTrailingStop ? "启用" : "禁用"));
    Print("最大持仓笔数:", InpMaxPositions, " 单笔最大手数:", InpMaxLots);
    Print("单方向持仓限制:", (InpOnePositionPerDirection ? "启用 (每方向最多1单)" : "禁用"));
    if(InpConsecutiveLosses > 0 && InpFreezeBarCount > 0)
        Print("连续亏损保护: 启用 (", InpConsecutiveLosses, "次亏损→冷冻", InpFreezeBarCount, "根K线)");
    else
        Print("连续亏损保护: 禁用");
    if(InpLotSizeMode == LOT_SIZE_RISK_PERCENT)
        Print("手数模式: 结余风险比例 ", InpRiskPercent, "% (按止损距离反推手数)");
    else
        Print("手数模式: 固定手数 ", InpFixedLots);
    if(InpBreakoutDirection == BREAKOUT_DIR_FOLLOW)
        Print("开仓方向: 顺势(破高多/破低空) 挂单: 高BUY STOP / 低SELL STOP");
    else
        Print("开仓方向: 反向(破高空/破低多) 挂单: 高SELL LIMIT / 低BUY LIMIT");
    if(InpEnablePullbackReverse)
        Print("回落反向: 开 破极值后监测", InpPullbackReverseWatchBars,
              "根K收盘回到极值内开反向单(与突破挂单独立)");
    else
        Print("回落反向: 关");
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
    CancelAllEaPendingOrders();

    Print("突破交易策略EA已卸载");
}

//+------------------------------------------------------------------+
//| 交易事务处理函数 - 用于检测亏损单                                    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
        if(HistoryDealSelect(trans.deal)) {
            if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) == _Symbol &&
               HistoryDealGetInteger(trans.deal, DEAL_MAGIC) == InpMagicNumber &&
               HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_IN) {
                const string deal_comment = HistoryDealGetString(trans.deal, DEAL_COMMENT);
                if(StringFind(deal_comment, "-PB") < 0) {
                    const ENUM_DEAL_TYPE deal_type =
                        (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
                    if(deal_type == DEAL_TYPE_BUY) {
                        if(PosTypeOnHighBreakout() == POSITION_TYPE_BUY)
                            latest_wave.high_used = true;
                        else if(PosTypeOnLowBreakout() == POSITION_TYPE_BUY)
                            latest_wave.low_used = true;
                    } else if(deal_type == DEAL_TYPE_SELL) {
                        if(PosTypeOnHighBreakout() == POSITION_TYPE_SELL)
                            latest_wave.high_used = true;
                        else if(PosTypeOnLowBreakout() == POSITION_TYPE_SELL)
                            latest_wave.low_used = true;
                    }
                }
            }
        }
    }

    // 只在功能启用时处理连续亏损
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
    // 1. 检查并关闭手工单（如果启用）
    if(InpCloseManualOrders)
        CheckAndCloseManualOrders();

    // 2. 更新最新有效波段
    UpdateLatestValidWave();

    // 3. 突破回落反向(破极值后K线收盘回到极值内,与突破挂单独立)
    CheckPullbackReverseSignals();

    // 4. 同步突破挂单(顺势/反向由 InpBreakoutDirection 决定)
    SyncBreakoutPendingOrders();

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
        double price_diff = MathAbs(extremes[i].price - extremes[i-1].price);
        double price_diff_points = price_diff / _Point;

        // 计算阈值（百分比模式：以前一个极值点价格为基准计算百分比）
        double base_price = extremes[i-1].price;
        double min_threshold = (base_price * InpMinWavePercent / 100.0) / _Point;
        double max_threshold = (base_price * InpMaxWavePercent / 100.0) / _Point;

        // 波段必须在最小和最大阈值之间才是有效波段
        if(price_diff_points >= min_threshold && price_diff_points <= max_threshold &&
           IsValidWaveByBarCount(rates, extremes[i - 1].time, extremes[i].time)) {
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
        if(price_diff_points >= min_threshold && price_diff_points <= max_threshold &&
           IsValidWaveByBarCount(rates, extremes[i - 1].time, extremes[i].time)) {
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

                if(high != prev_high) {
                    latest_wave.high_used = false;
                    latest_wave.high_pullback_reverse_used = false;
                    g_high_pullback_watch.active = false;
                }
                if(low != prev_low) {
                    latest_wave.low_used = false;
                    latest_wave.low_pullback_reverse_used = false;
                    g_low_pullback_watch.active = false;
                }

                // 绘制最新有效波段
                if(InpShowMarkers) {
                    DrawLatestValidWave(high, high_time, low, low_time);
                }

                if(InpShowDebugInfo) {
                    Print("更新最新有效波段 - 高:", DoubleToString(high, _Digits),
                          " 低:", DoubleToString(low, _Digits),
                          " 价差:", (int)price_diff_points, "点",
                          " K线数:", CountBarsBetweenExtremeTimes(rates, extremes[i - 1].time, extremes[i].time),
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
//| 突破挂单管理                                                       |
//+------------------------------------------------------------------+
long PosTypeOnHighBreakout()
{
    if(InpBreakoutDirection == BREAKOUT_DIR_REVERSE)
        return POSITION_TYPE_SELL;
    return POSITION_TYPE_BUY;
}

long PosTypeOnLowBreakout()
{
    if(InpBreakoutDirection == BREAKOUT_DIR_REVERSE)
        return POSITION_TYPE_BUY;
    return POSITION_TYPE_SELL;
}

ENUM_ORDER_TYPE PendingTypeOnHighBreakout()
{
    if(InpBreakoutDirection == BREAKOUT_DIR_REVERSE)
        return ORDER_TYPE_SELL_LIMIT;
    return ORDER_TYPE_BUY_STOP;
}

ENUM_ORDER_TYPE PendingTypeOnLowBreakout()
{
    if(InpBreakoutDirection == BREAKOUT_DIR_REVERSE)
        return ORDER_TYPE_BUY_LIMIT;
    return ORDER_TYPE_SELL_STOP;
}

void CancelEaPendingOrderType(const ENUM_ORDER_TYPE order_type)
{
    const ulong ticket = FindEaPendingOrder(order_type);
    if(ticket > 0)
        trade.OrderDelete(ticket);
}

void CancelEaPendingAtHigh()
{
    CancelEaPendingOrderType(ORDER_TYPE_BUY_STOP);
    CancelEaPendingOrderType(ORDER_TYPE_SELL_LIMIT);
}

void CancelEaPendingAtLow()
{
    CancelEaPendingOrderType(ORDER_TYPE_SELL_STOP);
    CancelEaPendingOrderType(ORDER_TYPE_BUY_LIMIT);
}

void CancelAllEaPendingOrders()
{
    CancelEaPendingAtHigh();
    CancelEaPendingAtLow();
}

ulong FindEaPendingOrder(const ENUM_ORDER_TYPE order_type)
{
    for(int i = OrdersTotal() - 1; i >= 0; i--) {
        const ulong ticket = OrderGetTicket(i);
        if(ticket == 0 || !OrderSelect(ticket))
            continue;
        if(OrderGetString(ORDER_SYMBOL) != _Symbol)
            continue;
        if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
            continue;
        if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == order_type)
            return ticket;
    }
    return 0;
}

bool CalcPendingSlTp(const ENUM_ORDER_TYPE pending_type, const double trigger_price, double &sl, double &tp)
{
    const double stop_loss_amount = GetStopLossOffset();
    const double take_profit_amount = GetTakeProfitOffset();
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
                               const double wave_high, const double wave_low)
{
    const double lots = CalculateLotSize(wave_high, wave_low);
    if(lots <= 0.0)
        return false;

    double sl = 0.0, tp = 0.0;
    if(!CalcPendingSlTp(pending_type, trigger_price, sl, tp))
        return false;

    const int wave_range_points = (int)MathRound(MathAbs(wave_high - wave_low) / _Point);
    const string comment = StringFormat("WR%d", wave_range_points);

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
        Print("挂单失败 ", EnumToString(pending_type), " 触发价:", trigger_price,
              " 错误:", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
        return false;
    }

    Print("突破挂单成功 ", EnumToString(pending_type),
          " 触发:", trigger_price, " 手数:", lots,
          " SL:", sl, " TP:", tp,
          " 波段 H:", wave_high, " L:", wave_low);
    return true;
}

void SyncPendingAtExtreme(const bool at_high, const double trigger_price,
                          const double wave_high, const double wave_low,
                          const double lots)
{
    const ENUM_ORDER_TYPE pending_type = at_high ?
        PendingTypeOnHighBreakout() : PendingTypeOnLowBreakout();
    const ENUM_ORDER_TYPE stale_type = at_high ?
        (pending_type == ORDER_TYPE_BUY_STOP ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_BUY_STOP) :
        (pending_type == ORDER_TYPE_SELL_STOP ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_STOP);
    CancelEaPendingOrderType(stale_type);

    const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    const bool price_crossed = at_high ?
        (ask >= trigger_price - _Point * 0.5) :
        (bid <= trigger_price + _Point * 0.5);

    if(price_crossed) {
        if(at_high)
            CancelEaPendingAtHigh();
        else
            CancelEaPendingAtLow();
        if(InpShowDebugInfo)
            Print("价格已越过波段", (at_high ? "高点" : "低点"),
                  ",暂不挂", EnumToString(pending_type),
                  " ", (at_high ? "Ask:" : "Bid:"),
                  (at_high ? ask : bid), " 极值:", trigger_price);
        return;
    }

    ulong ticket = FindEaPendingOrder(pending_type);
    if(ticket > 0 && OrderSelect(ticket)) {
        const double order_price = OrderGetDouble(ORDER_PRICE_OPEN);
        const double order_lots = OrderGetDouble(ORDER_VOLUME_CURRENT);
        if(MathAbs(order_price - trigger_price) > _Point * 0.5 ||
           MathAbs(order_lots - lots) > 1e-8) {
            trade.OrderDelete(ticket);
            ticket = 0;
        }
    }
    if(ticket == 0)
        PlaceBreakoutPendingOrder(pending_type, trigger_price, wave_high, wave_low);
}

void SyncBreakoutPendingOrders()
{
    if(!latest_wave.exists) {
        CancelAllEaPendingOrders();
        g_sync_wave_high = 0.0;
        g_sync_wave_low = 0.0;
        return;
    }

    if(InpConsecutiveLosses > 0 && InpFreezeBarCount > 0 && freeze_bar_index > 0) {
        const int current_bars = Bars(_Symbol, InpTimeframe);
        if(current_bars < freeze_bar_index) {
            CancelAllEaPendingOrders();
            return;
        }
        if(freeze_bar_index > 0) {
            Print("【连续亏损保护】冷冻解除，恢复交易");
            consecutive_loss_count = 0;
            freeze_bar_index = 0;
            freeze_until_time = 0;
        }
    }

    if(MathAbs(latest_wave.high_price - g_sync_wave_high) > _Point * 0.5 ||
       MathAbs(latest_wave.low_price - g_sync_wave_low) > _Point * 0.5) {
        CancelAllEaPendingOrders();
        g_sync_wave_high = latest_wave.high_price;
        g_sync_wave_low = latest_wave.low_price;
    }

    int total_positions = 0;
    int buy_positions = 0;
    int sell_positions = 0;

    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(!PositionSelectByTicket(PositionGetTicket(i)))
            continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;
        total_positions++;
        const ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        if(pos_type == POSITION_TYPE_BUY)
            buy_positions++;
        else if(pos_type == POSITION_TYPE_SELL)
            sell_positions++;
    }

    if(total_positions >= InpMaxPositions) {
        CancelAllEaPendingOrders();
        if(InpShowDebugInfo)
            Print("已达最大持仓笔数,撤销突破挂单: ", total_positions, "/", InpMaxPositions);
        return;
    }

    const double wave_high = latest_wave.high_price;
    const double wave_low = latest_wave.low_price;
    const double lots = CalculateLotSize(wave_high, wave_low);

    const long high_pos_type = PosTypeOnHighBreakout();
    const long low_pos_type = PosTypeOnLowBreakout();
    const int high_dir_positions = (high_pos_type == POSITION_TYPE_BUY) ?
        buy_positions : sell_positions;
    const int low_dir_positions = (low_pos_type == POSITION_TYPE_BUY) ?
        buy_positions : sell_positions;

    if(!latest_wave.high_used &&
       (!InpOnePositionPerDirection || high_dir_positions < 1)) {
        SyncPendingAtExtreme(true, wave_high, wave_high, wave_low, lots);
    } else {
        CancelEaPendingAtHigh();
    }

    if(!latest_wave.low_used &&
       (!InpOnePositionPerDirection || low_dir_positions < 1)) {
        SyncPendingAtExtreme(false, wave_low, wave_high, wave_low, lots);
    } else {
        CancelEaPendingAtLow();
    }
}

//+------------------------------------------------------------------+
//| 突破回落反向(破极值后收盘回到极值内开反向单,与突破挂单独立)            |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE OrderTypeOnHighPullbackReverse()
{
    return ORDER_TYPE_SELL;
}

ENUM_ORDER_TYPE OrderTypeOnLowPullbackReverse()
{
    return ORDER_TYPE_BUY;
}

void SyncPullbackBarLock(const bool for_high_extreme)
{
    const datetime bar_time = iTime(_Symbol, InpTimeframe, 0);
    if(bar_time == 0)
        return;
    if(for_high_extreme) {
        if(bar_time != g_pullback_bar_time_high) {
            g_pullback_bar_time_high = bar_time;
            g_pullback_opened_on_bar_high = false;
        }
    } else {
        if(bar_time != g_pullback_bar_time_low) {
            g_pullback_bar_time_low = bar_time;
            g_pullback_opened_on_bar_low = false;
        }
    }
}

bool IsPullbackBarOpenAllowed(const bool for_high_extreme)
{
    SyncPullbackBarLock(for_high_extreme);
    if(for_high_extreme)
        return !g_pullback_opened_on_bar_high;
    return !g_pullback_opened_on_bar_low;
}

void MarkPullbackBarOpened(const bool for_high_extreme)
{
    SyncPullbackBarLock(for_high_extreme);
    if(for_high_extreme)
        g_pullback_opened_on_bar_high = true;
    else
        g_pullback_opened_on_bar_low = true;
}

bool IsPullbackOpenBlocked()
{
    if(InpConsecutiveLosses > 0 && InpFreezeBarCount > 0 && freeze_bar_index > 0) {
        if(Bars(_Symbol, InpTimeframe) < freeze_bar_index)
            return true;
    }

    int total_positions = 0;
    int buy_positions = 0;
    int sell_positions = 0;

    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(!PositionSelectByTicket(PositionGetTicket(i)))
            continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;
        total_positions++;
        const ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        if(pos_type == POSITION_TYPE_BUY)
            buy_positions++;
        else if(pos_type == POSITION_TYPE_SELL)
            sell_positions++;
    }

    if(total_positions >= InpMaxPositions)
        return true;

    return false;
}

bool IsPullbackDirectionBlocked(const ENUM_ORDER_TYPE order_type)
{
    if(!InpOnePositionPerDirection)
        return false;

    const long pos_type = (order_type == ORDER_TYPE_BUY) ?
        POSITION_TYPE_BUY : POSITION_TYPE_SELL;

    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(!PositionSelectByTicket(PositionGetTicket(i)))
            continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;
        if(PositionGetInteger(POSITION_TYPE) == pos_type)
            return true;
    }
    return false;
}

bool CalcMarketSlTp(const ENUM_ORDER_TYPE order_type, const double entry_price, double &sl,
                    double &tp)
{
    const ENUM_ORDER_TYPE pending_equiv = (order_type == ORDER_TYPE_BUY) ?
        ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
    return CalcPendingSlTp(pending_equiv, entry_price, sl, tp);
}

bool OpenPullbackReversePosition(ENUM_ORDER_TYPE order_type, const bool from_high_extreme,
                                 const double extreme_price, const double wave_high,
                                 const double wave_low)
{
    if(!IsPullbackBarOpenAllowed(from_high_extreme))
        return false;

    if(IsPullbackOpenBlocked()) {
        if(InpShowDebugInfo)
            Print("【回落反向】开仓跳过 - 冷冻中或已达最大持仓笔数");
        return false;
    }

    if(IsPullbackDirectionBlocked(order_type)) {
        if(InpShowDebugInfo)
            Print("【回落反向】开仓跳过 - 同向已有持仓");
        return false;
    }

    const double lots = CalculateLotSize(wave_high, wave_low);
    if(lots <= 0.0)
        return false;

    const double entry_price = (order_type == ORDER_TYPE_BUY) ?
        SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
        SymbolInfoDouble(_Symbol, SYMBOL_BID);

    double sl = 0.0, tp = 0.0;
    if(!CalcMarketSlTp(order_type, entry_price, sl, tp))
        return false;

    const int wave_range_points = (int)MathRound(MathAbs(wave_high - wave_low) / _Point);
    const string comment = StringFormat("WR%d-PB", wave_range_points);

    bool result = false;
    if(order_type == ORDER_TYPE_BUY)
        result = trade.Buy(lots, _Symbol, entry_price, sl, tp, comment);
    else
        result = trade.Sell(lots, _Symbol, entry_price, sl, tp, comment);

    if(!result) {
        Print("【回落反向】开仓失败: ", trade.ResultRetcode(), " - ",
              trade.ResultRetcodeDescription());
        return false;
    }

    MarkPullbackBarOpened(from_high_extreme);
    Print("【回落反向】开仓成功 ", (order_type == ORDER_TYPE_BUY ? "多" : "空"),
          " 手数:", lots, " 极值:", extreme_price, " SL:", sl, " TP:", tp);
    return true;
}

void TryArmPullbackWatch()
{
    if(!InpEnablePullbackReverse || !latest_wave.exists)
        return;

    const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    if(ask > latest_wave.high_price && !latest_wave.high_pullback_reverse_used) {
        if(!g_high_pullback_watch.active ||
           g_high_pullback_watch.extreme_price != latest_wave.high_price) {
            g_high_pullback_watch.active = true;
            g_high_pullback_watch.extreme_price = latest_wave.high_price;
            g_high_pullback_watch.bars_checked = 0;
            if(InpShowDebugInfo)
                Print("【回落反向】开始监测破高 极值:", latest_wave.high_price,
                      " 共", InpPullbackReverseWatchBars, "根K");
        }
    }

    if(bid < latest_wave.low_price && !latest_wave.low_pullback_reverse_used) {
        if(!g_low_pullback_watch.active ||
           g_low_pullback_watch.extreme_price != latest_wave.low_price) {
            g_low_pullback_watch.active = true;
            g_low_pullback_watch.extreme_price = latest_wave.low_price;
            g_low_pullback_watch.bars_checked = 0;
            if(InpShowDebugInfo)
                Print("【回落反向】开始监测破低 极值:", latest_wave.low_price,
                      " 共", InpPullbackReverseWatchBars, "根K");
        }
    }
}

void ProcessPullbackReverseOnNewBar()
{
    if(!InpEnablePullbackReverse || !latest_wave.exists)
        return;

    const int max_bars = MathMax(1, InpPullbackReverseWatchBars);
    const double wave_high = latest_wave.high_price;
    const double wave_low = latest_wave.low_price;

    if(g_high_pullback_watch.active && !latest_wave.high_pullback_reverse_used) {
        const double close1 = iClose(_Symbol, InpTimeframe, 1);
        if(close1 > 0.0 && close1 <= g_high_pullback_watch.extreme_price) {
            if(OpenPullbackReversePosition(OrderTypeOnHighPullbackReverse(), true,
                                           g_high_pullback_watch.extreme_price,
                                           wave_high, wave_low)) {
                latest_wave.high_pullback_reverse_used = true;
            }
            g_high_pullback_watch.active = false;
        } else {
            g_high_pullback_watch.bars_checked++;
            if(g_high_pullback_watch.bars_checked >= max_bars) {
                if(InpShowDebugInfo)
                    Print("【回落反向】破高监测结束 未回落极值内");
                g_high_pullback_watch.active = false;
            }
        }
    }

    if(g_low_pullback_watch.active && !latest_wave.low_pullback_reverse_used) {
        const double close1 = iClose(_Symbol, InpTimeframe, 1);
        if(close1 > 0.0 && close1 >= g_low_pullback_watch.extreme_price) {
            if(OpenPullbackReversePosition(OrderTypeOnLowPullbackReverse(), false,
                                           g_low_pullback_watch.extreme_price,
                                           wave_high, wave_low)) {
                latest_wave.low_pullback_reverse_used = true;
            }
            g_low_pullback_watch.active = false;
        } else {
            g_low_pullback_watch.bars_checked++;
            if(g_low_pullback_watch.bars_checked >= max_bars) {
                if(InpShowDebugInfo)
                    Print("【回落反向】破低监测结束 未回升极值内");
                g_low_pullback_watch.active = false;
            }
        }
    }
}

void CheckPullbackReverseSignals()
{
    if(!InpEnablePullbackReverse)
        return;

    TryArmPullbackWatch();

    static datetime s_last_bar_time = 0;
    const datetime bar_time = iTime(_Symbol, InpTimeframe, 0);
    if(bar_time == 0 || bar_time == s_last_bar_time)
        return;
    s_last_bar_time = bar_time;

    ProcessPullbackReverseOnNewBar();
}

//+------------------------------------------------------------------+
//| 止损/止盈距离(点数)                                                |
//+------------------------------------------------------------------+
double GetStopLossOffset()
{
    if(InpStopLossPoints <= 0)
        return 0.0;
    return (double)InpStopLossPoints * _Point;
}

double GetTakeProfitOffset()
{
    if(InpTakeProfitPoints <= 0)
        return 0.0;
    return (double)InpTakeProfitPoints * _Point;
}

double StopLossAmountFromPositionComment(const string &comment)
{
    return GetStopLossOffset();
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
double CalculateLotSize(const double wave_high, const double wave_low)
{
    double lots = InpFixedLots;

    if(InpLotSizeMode == LOT_SIZE_RISK_PERCENT && InpRiskPercent > 0.0) {
        const double stop_loss_dist = GetStopLossOffset();
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

    // 计算止损金额（有效波段区间 × 比例，备注中 WR 存区间点数）
    const string comment = PositionGetString(POSITION_COMMENT);
    const double stop_loss_amount = StopLossAmountFromPositionComment(comment);

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
