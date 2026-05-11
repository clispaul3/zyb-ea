# 马丁网格策略

- **概念**：`InpSlippage` 等仍按「点」= `SYMBOL_POINT`；但 **首档止盈 / 统盈 / 加仓间距** 在 v1.08 起为**相对价**的**百分比(%)**，在运行时以对应参考价（开仓/成本/上一同向开）换算成实际价距。语言 MQL5。
- **特点**：小周期震荡、同向加仓、整篮按成本统盈（无单张止损）。

## 功能概要

震荡中同向加仓；无单时开首单；首档按 **InpFirstTpPercent** 相对**该笔开仓**设止盈(价距=开仓价×%)；多档后按**加权成本 × InpAveTpPercent%** 整篮平仓；加仓间距= **上一同向单开仓价 × InpDisPercent%**；多空对称（v1.10 起已取消按 K 线数的时间全平）。

## 参数（与输入组对应）

| 思路 | 参数 |
|------|------|
| 滑点 | `InpSlippage` |
| 识别 | `InpMagic` |
| 首档 TP% / 统盈%(相对成本) | `InpFirstTpPercent`（默认0.05）, `InpAveTpPercent`（默认0.05） |
| 加仓间距%(相对上笔同向开) / 满 20 档后倍率 / 单方向最大持仓笔数 | `InpDisPercent`（默认0.1）, `InpAddTimes`（默认1.2）, `InpMaxOrdersPerSide`（默认20，0=不限制；达到后仅停止新开仓，不平仓） |
| 第 1~20 档总手数（一行 20 个数，英文逗号） | `InpLotLadder` |
| 每档拆单笔数 | `InpOrdersPerAdd` |
| 点差上限、日志 | `InpMaxSpreadPoints`, `InpLog` |
| 图表虚拟统盈线 | `InpDrawVtp` 及颜色、线宽 |
| 图表每单统盈价列表 | `InpShowBasketTgtList`, `InpTgtListColor`, `InpTgtListFont`（左下列出 #、开仓、统盈目标 T，与程序整篮价一致，非交易列表「获利」列） |

## 止盈策略

**档**：同向第几批加仓；若 `InpOrdersPerAdd>1`，档数 = 该向笔数 / 拆单。

- **仅 1 档**  
  - `InpFirstTpPercent > 0`：在**订单上**挂 TP（多 `开 + 开×%`，空 `开 − 开×%`）。  
  - `InpFirstTpPercent = 0`：不挂首档 TP，改由程序在 **多** `Bid ≥ 成本 + 成本×InpAveTpPercent%`、**空** `Ask ≤ 成本 − 成本×InpAveTpPercent%` 时整篮平仓。  
- **≥2 档**：加第 2 档前会清掉该向各单 TP，之后只在 **多** `Bid ≥ 成本 + 成本×统盈%`、**空** `Ask ≤ 成本 − 成本×统盈%` 时**整篮**平仓。  
- 市价加仓判定：多关注 **Ask** 与上一开间距；空 **Bid** 与上一开（与 v1.08 前仅用对侧价相比更贴实际成价）。  
- **图表线** `InpDrawVtp`：仅作目标价参考，非经纪商挂单。  
- **每单看统盈价**：`InpShowBasketTgtList=true` 时，在**图表左下**用文本列出该向每笔 `#`、开仓、以及**同一条**统盈目标 T（与程序整篮平仓一致）。**交易**窗口里多档时「获利」仍可能全 0：统盈是程序按成本判断，**不能把同一统盈价在每一笔上都设成有效经纪商 TP**（否则或拒单、或只平部分单），故用图上列表作对照。
