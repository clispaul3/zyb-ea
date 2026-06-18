# 金麒麟EA - MQL5版本使用说明

## 📌 概述

这是从MQL4版本转换而来的MQL5版本金麒麟EA,保留了原版的核心策略逻辑:
- **网格马丁策略** - 价格移动时自动加仓
- **对冲机制** - 多空双向操作,避免单边风险
- **时间过滤** - 可设置交易时段
- **风险控制** - 多层次止盈止损机制

## ⚠️ 风险警告

**本EA采用马丁加仓策略,风险极高!**

- ❌ 遇到单边趋势可能导致爆仓
- ❌ 需要大量保证金支撑
- ❌ 不适合小资金账户(建议≥5000美元)
- ✅ 仅适用于震荡行情
- ✅ 强烈建议先在模拟盘充分测试

---

## 📋 MQL4到MQL5主要改动

### 1. 订单管理系统
**MQL4**:
```mql4
OrderSend(Symbol(), OP_BUYSTOP, lots, price, slippage, 0, 0, "comment", magic, 0, clr);
OrderSelect(i, SELECT_BY_POS, MODE_TRADES);
OrderClose(ticket, lots, price, slippage);
```

**MQL5**:
```mql5
#include <Trade\Trade.mqh>
CTrade trade;
trade.BuyStop(lots, price, symbol, 0, 0, ORDER_TIME_GTC, 0, "comment");
posInfo.SelectByIndex(i);
trade.PositionClose(ticket);
```

### 2. 持仓和挂单分离
- MQL4: Orders包含持仓+挂单
- MQL5: Positions(持仓) 和 Orders(挂单) 完全分开

### 3. 对冲平仓变化
- MQL4: `OrderCloseBy(ticket1, ticket2)` - 直接对冲
- MQL5: 没有OrderCloseBy,改为直接平仓

### 4. 时间函数
- MQL4: `TimeCurrent()`, `TimeLocal()`
- MQL5: 保持不变,但结构体使用`MqlDateTime`

### 5. 品种信息
- MQL4: `MarketInfo(Symbol(), MODE_XXX)`
- MQL5: `SymbolInfoInteger/_Double/_String(symbol, SYMBOL_XXX)`

---

## 🎛️ 参数说明

### 价格限制设置
| 参数 | 默认值 | 说明 |
|------|--------|------|
| On_top_of_this_price_not_Buy_first_order | 0 | 价格高于此值不开首单买(0=关闭) |
| On_under_of_this_price_not_Sell_first_order | 0 | 价格低于此值不开首单卖(0=关闭) |
| On_top_of_this_price_not_Buy_order | 0 | 价格高于此值不补单买(0=关闭) |
| On_under_of_this_price_not_Sell_order | 0 | 价格低于此值不补单卖(0=关闭) |

### 时间控制
| 参数 | 默认值 | 说明 |
|------|--------|------|
| Limit_StartTime | "00:00" | 允许挂单开始时间 |
| Limit_StopTime | "24:00" | 允许挂单停止时间 |
| EA_StartTime | "00:00" | EA运行开始时间 |
| EA_StopTime | "24:00" | EA运行停止时间 |

### 平仓设置
| 参数 | 默认值 | 说明 |
|------|--------|------|
| CloseBuySell | true | 对冲平仓开关 |
| HomeopathyCloseAll | true | 同向对冲平仓开关 |
| Homeopathy | true | 允许同向手数对冲补单 |
| Over | false | 公司到期(测试用) |
| NextTime | 0 | 到期后等待秒数 |

### 资金管理(核心参数)
| 参数 | 默认值 | 说明 | 推荐值 |
|------|--------|------|--------|
| **Money** | -300 | 盈利后才补单(负数=关闭) | -300 |
| **FirstStep** | 60 | 首单距离(点) | 60-100 |
| **MinDistance** | 200 | 最小加仓距离(点) | 200-300 |
| **TwoMinDistance** | 200 | 第二最小距离(点) | 200-300 |
| StepTrallOrders | 80 | 挂单追踪点数 | 80 |
| **Step** | 300 | 补单间距(点) | 300-500 |
| **TwoStep** | 300 | 第二补单间距(点) | 300-500 |

### 开仓模式
| 参数 | 默认值 | 说明 |
|------|--------|------|
| OpenMode | MODE_ALWAYS(3) | 1=新K线 2=定时 3=不限制 |
| TimeZone | PERIOD_M1 | 新K线时间周期 |
| SleepSeconds | 30 | 定时开仓间隔(秒) |

### 风险控制(重要!)
| 参数 | 默认值 | 说明 | 推荐值 |
|------|--------|------|--------|
| **MaxLoss** | -1000 | 单边最大亏损后停止补单 | -500~-1000 |
| **MaxLossCloseAll** | -50 | 单边亏损达此值强平 | -50~-100 |
| **lot** | 0.01 | 初始手数 | 0.01 |
| **MaxLot** | 5 | 最大单次手数 | 1-5 |
| PlusLot | 0 | 每次累加手数 | 0 |
| **K_Lot** | 2.0 | 手数倍率(马丁核心) | 1.5-2.0 |
| DigitsLot | 2 | 手数小数位数 | 2 |
| **CloseAll** | 5.0 | 总盈利平仓(美元) | 5-20 |
| Profit | true | 单边盈利平仓开关 | true |
| **StopProfit** | 5.0 | 单边止盈(美元) | 5-10 |
| **StopLoss** | -1000 | 总亏损止损(美元) | -500~-1000 |
| Magic | 9589998 | EA魔术号 | 任意数字 |
| **Totals** | 10 | 最大订单数 | 5-10 |
| **MaxSpread** | 60 | 最大点差限制(点) | 30-60 |
| Leverage | 100 | 最小杠杆要求 | 100-500 |

---

## 🔧 安装步骤

### 1. 复制文件
将 `GoldKylin_MQL5.mq5` 复制到:
```
MT5数据文件夹/MQL5/Experts/
```

### 2. 编译
- 打开MT5 MetaEditor
- 打开 `GoldKylin_MQL5.mq5`
- 点击"编译"按钮(F7)
- 确保无错误

### 3. 加载到图表
- 在MT5中打开想要交易的品种图表
- 从导航器拖拽EA到图表
- 设置参数
- 点击"确定"

### 4. 检查
- 确保右上角显示笑脸(EA已启用)
- 确保"算法交易"按钮已开启
- 查看EA输出信息

---

## 📊 策略运行逻辑

### 阶段1: 首单挂单
```
多单: Ask + FirstStep点 (BuyStop)
空单: Bid - FirstStep点 (SellStop)
```

### 阶段2: 加仓条件
**做多加仓**:
- 价格距离最高价 >= Step点 (继续上涨)
- 或价格距离最低价 <= -Step点 (回撤加仓)

**做空加仓**:
- 价格距离最低价 <= -Step点 (继续下跌)
- 或价格距离最高价 >= Step点 (反弹加仓)

**手数计算**:
```
新手数 = 订单数 * PlusLot + lot * (K_Lot ^ 订单数)

例如(K_Lot=2.0, lot=0.01):
第1单: 0.01
第2单: 0.02
第3单: 0.04
第4单: 0.08
第5单: 0.16
...
```

### 阶段3: 对冲触发
当满足以下条件时,允许反向加仓对冲:
```
空单手数 > 多单手数 * 3 且 手数差 > 0.2  →  允许加多单
多单手数 > 空单手数 * 3 且 手数差 > 0.2  →  允许加空单
```

### 阶段4: 平仓条件

**1. 总盈利平仓**:
```
总盈利 >= CloseAll → 全部平仓
```

**2. 单边止盈**:
```
多单盈利 > StopProfit (或 StopProfit * 多单数) → 平多单
空单盈利 > StopProfit (或 StopProfit * 空单数) → 平空单
```

**3. 对冲平仓**:
```
总盈利 >= CloseAll 且 (多单亏损 <= MaxLossCloseAll 或 空单亏损 <= MaxLossCloseAll)
→ 全部平仓
```

**4. 总止损**:
```
总盈利 <= StopLoss → 强制平仓
```

---

## 💡 使用建议

### 适用品种
✅ **推荐**:
- EURUSD (欧美)
- GBPUSD (镑美)
- AUDUSD (澳美)
- 黄金(XAUUSD) - 需调大参数

❌ **不推荐**:
- 加密货币(波动太大)
- 外汇次要货币对(流动性差)
- 指数(跳空风险)

### 时间段建议
- ✅ 亚洲盘(震荡为主): 00:00-08:00 GMT
- ⚠️ 欧洲盘(波动增大): 08:00-16:00 GMT
- ❌ 美洲盘(单边风险): 16:00-24:00 GMT
- ❌ 重要新闻时段: 关闭EA

### 资金管理
| 账户余额 | 初始手数 | K_Lot | MaxLot | Totals |
|----------|----------|-------|--------|--------|
| $1,000 | 0.01 | 1.5 | 0.5 | 5 |
| $5,000 | 0.01 | 2.0 | 2.0 | 8 |
| $10,000 | 0.02 | 2.0 | 5.0 | 10 |

### 参数优化建议

**保守型**(适合新手):
```
lot = 0.01
K_Lot = 1.5
MaxLot = 1.0
Step = 500
Totals = 5
CloseAll = 10.0
StopLoss = -300
```

**激进型**(有经验):
```
lot = 0.01
K_Lot = 2.0
MaxLot = 5.0
Step = 300
Totals = 10
CloseAll = 5.0
StopLoss = -1000
```

---

## 🐛 常见问题

### Q1: EA没有交易
**检查**:
- 是否开启"算法交易"
- 是否在EA运行时间内(EA_StartTime ~ EA_StopTime)
- 点差是否超过MaxSpread
- 杠杆是否低于Leverage设置

### Q2: 挂单不触发
**检查**:
- 是否在挂单时间内(Limit_StartTime ~ Limit_StopTime)
- 价格是否触及挂单价
- 是否达到最大订单数(Totals)

### Q3: 频繁加仓
**解决**:
- 增大Step参数(如500)
- 增大MinDistance参数
- 减少Totals限制订单数

### Q4: 保证金不足
**解决**:
- 减小lot初始手数
- 减小K_Lot倍率(如1.5)
- 减小MaxLot上限
- 增加账户资金

### Q5: 对冲后仍然亏损
**说明**:
- 对冲只是锁仓,不能减少亏损
- 需要价格回调才能盈利
- 建议设置合理的StopLoss硬止损

---

## 📈 回测建议

### 回测设置
- **时间段**: 至少3-6个月
- **品种**: EURUSD
- **周期**: M5或M15
- **点差**: 设置为实际点差(如20点)
- **滑点**: 设置为30-50点
- **初始资金**: $5,000-$10,000

### 关注指标
- ✅ 最大回撤 < 30%
- ✅ 盈利因子 > 1.5
- ✅ 胜率 > 60%
- ❌ 单笔最大亏损 (应有硬止损保护)
- ❌ 最大连续亏损次数

---

## ⚙️ 与原版MQL4的差异

### 1. 已移除功能
- ❌ 图形界面按钮(MQL5需重新实现)
- ❌ 复杂的统计面板
- ❌ OrderCloseBy对冲平仓(改为直接平仓)

### 2. 已保留功能
- ✅ 核心马丁加仓逻辑
- ✅ 对冲机制
- ✅ 时间过滤
- ✅ 所有风险控制参数
- ✅ 价格限制

### 3. 新增功能
- ✅ 使用MQL5标准库(CTrade)
- ✅ 更清晰的代码结构
- ✅ 简洁的界面显示

---

## 📝 改进建议

如果您要进一步优化这个EA,建议:

1. **添加硬止损**
```mql5
trade.BuyStop(lots, price, _Symbol,
              price - 200*_Point,  // SL
              price + 100*_Point,  // TP
              ...);
```

2. **限制最大加仓次数**
```mql5
if(buyCount >= 5) return;  // 最多5单
```

3. **添加趋势过滤**
```mql5
double ma = iMA(_Symbol, PERIOD_H1, 100, 0, MODE_SMA, PRICE_CLOSE);
if(iClose(_Symbol, PERIOD_H1, 0) > ma)
   g_canTradeSell = false;  // 上升趋势不做空
```

4. **降低马丁倍率**
```mql5
K_Lot = 1.5;  // 从2.0降到1.5
```

---

## 📞 技术支持

- 原版链接: https://hisanhe.com
- 本MQL5版本: 转换自MQL4版本
- 建议: 充分测试后再实盘使用

---

## ⚖️ 免责声明

- 本EA为教育和研究目的
- 外汇交易存在高风险,可能损失全部本金
- 马丁策略风险极高,不建议实盘使用
- 作者不对任何交易损失负责
- 使用前请充分理解风险并在模拟盘测试

---

**祝交易顺利! 但请务必谨慎!** 🎯
