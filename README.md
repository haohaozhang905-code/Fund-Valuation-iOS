# Fund Valuation iOS

将网页版 `Fund Valuation Viewing` 迁移为 SwiftUI iOS App，支持基金持仓管理、实时估值、收益计算与 AI 分析。

---

## 功能概览

| 功能 | 说明 |
|------|------|
| **持仓管理** | 新增 / 编辑 / 删除基金，本地持久化 UserDefaults |
| **实时估值** | 交易时段显示估值，收盘后净值未出时用估值 |
| **收益计算** | 当日收益、累计收益、账户总资产汇总 |
| **排序** | 按当日收益或持有收益升序/降序 |
| **主题** | 浅色 / 深色 / 跟随系统 |
| **AI 分析** | 手动触发 + 自动时段（早盘结束、收盘前 30 分钟）+ 本地配置 API |

---

## 项目结构

```
FundValuationApp/
├── FundValuationApp.swift    # App 入口
├── MainView.swift            # 主界面、持仓列表、详情页、编辑页、设置页、AI 页
├── FundViewModel.swift       # 业务逻辑、数据拉取、快照计算、AI 调用
├── FundModels.swift          # 数据模型（FundPosition、FundSnapshot、NavPair 等）
└── FundServices.swift        # 网络请求、数据解析、DateHelper、NumberFormat
```

---

## 界面结构

```
MainView（主界面）
├── 顶部栏：刷新、标题、设置
├── 汇总区：账户总资产、当日收益（下个交易日未开盘时显示 MM-DD 日期标签）、持有收益
├── 持仓列表：可点击进入详情、左滑编辑
├── 右下角悬浮按钮：打开 AI 分析
│
├── FundDetailPageView（详情页，fullScreenCover）
│   ├── 当日涨幅、当日收益、净值/估值时间
│   ├── 持有金额、份额、占比、持有收益、收益率、成本
│   ├── 业绩走势图（本基金 vs 沪深300，近1月/3月/6月/1年/3年）
│   └── 编辑入口
│
├── FundEditorView（编辑页，fullScreenCover）
│   ├── 基金代码（6 位，保存时校验有效性）
│   ├── 持仓成本、持有份额
│   └── 删除持仓（仅编辑时显示）
│
├── SettingsPageView（设置页，fullScreenCover）
│   ├── AI 模型配置（endpoint、model、API Key）
│   ├── 自动分析开关
│   └── 主题切换
│
└── AIAnalysisPageView（AI 分析页，fullScreenCover）
    ├── 重新分析按钮
    ├── AI 报告（Markdown 渲染）
    └── 风险提示卡片
```

---

## 数据模型

| 模型 | 文件 | 说明 |
|------|------|------|
| `FundPosition` | FundModels | 持仓：id、fundCode、costPrice、shares、fundName |
| `FundSnapshot` | FundModels | 快照：currentPrice、todayProfit、cumulativeProfit、intradayTrend 等 |
| `NavPair` | FundModels | 净值对：latest、previous（NavPoint） |
| `PortfolioSummary` | FundModels | 汇总：totalCost、totalTodayProfit、totalCumulativeProfit、totalHoldValue、showTodayProfitDateLabel、todayProfitDateLabel |
| `FundValuationResponse` | FundServices | 估值 API 返回：gsz、gszzl、dwjz、jzrq、gztime |

---

## 核心逻辑

### 1. 数据源与优先级

| 用途 | 接口 | 域名 | 说明 |
|------|------|------|------|
| **估值 gsz** | `fundgz.1234567.com.cn/js/{code}.js` | 天天基金 | 当日实时估值、gszzl 涨跌幅 |
| **净值** | `fund.eastmoney.com/pingzhongdata/{code}.js` | 东方财富 | Data_netWorthTrend，T+2/QDII 可能滞后 |
| **净值** | `fundf10.eastmoney.com/F10DataApi.aspx` | 东方财富 | 历史净值，更新更及时 |

净值合并规则（`mergeNavPair`）：F10 与 pingzhong 按**日期**取更新者；若估值接口的 `jzrq` 更晚，则用估值里的 `dwjz` 覆盖 `latestPublished`。

### 2. 估值 API 返回格式（JSONP）

```json
{
  "fundcode": "015311",
  "name": "华泰柏瑞恒生科技ETF联接(QDII)C",
  "gsz": "1.1547",
  "gszzl": "-0.08",
  "dwjz": "1.1556",
  "jzrq": "2026-03-16",
  "gztime": "2026-03-17 16:00"
}
```

- `gsz`：估算净值（当日）
- `gszzl`：估算增长率 %
- `dwjz`：单位净值（前一交易日）
- `jzrq`：净值日期
- `gztime`：估值时间

### 3. 时段与价格逻辑（`loadSnapshotFromData`）

根据 `DateHelper` 判断当前时段：

| 时段 | 条件 | currentPrice | todayBase | 当日收益 |
|------|------|--------------|-----------|----------|
| **交易中** | 9:30–11:30 或 13:00–15:00 | gsz（估值） | 昨日净值 | (gsz - 昨日净值) × 份额 |
| **交易前 / 非交易日** | 9:30 前 或 周末/节假日 | 最新净值 | 前日净值 | (最新 - 前日) × 份额 |
| **收盘后 + 净值已出** | latestPublished 日期=今天 | 今日净值 | 前日净值 | (今日 - 前日) × 份额 |
| **收盘后 + 净值未出** | 有当日估值 gsz | gsz | **估值接口 dwjz** | 优先用 **gszzl** |

**重要**：收盘后净值未出时，`todayBase` 必须用估值接口的 `dwjz`，`todayRate` 优先用 `gszzl`，避免与 pingzhong/F10 混算导致数据跳动。

**0 点后规则**：过了 0 点至下一交易日 9:30 前，仍展示上个交易日数据（不清空收益）。此时顶部 banner 的「当日收益」旁显示 MM-DD 日期标签（样式同列表「已更新」），标明数据所属日期。

### 4. 收益计算公式

```
当日收益 = (currentPrice - todayBase) × 份额
当日涨跌% = (currentPrice - todayBase) / todayBase × 100  （或直接用 gszzl）
累计收益 = (currentPrice - 成本价) × 份额
累计涨跌% = (currentPrice - 成本价) / 成本价 × 100
账户总资产 = Σ 各持仓市值（无市值时用成本+累计收益兜底）
```

### 5. 日内走势（`buildIntradaySeries`）

- **交易中**：每次刷新追加当前估值与 baseline 的涨跌幅，本地缓存（最多 240 点）
- **非交易中**：用当日涨跌生成 09:30 / 10:30 / 11:30 / 13:00 / 14:00 / 15:00 的合成点

### 6. 数字与日期格式化

- **金额**：`|value| >= 1000` 时使用千分位（如 `12,345.67`）
- **百分比**：统一保留 2 位小数（如 `+2.55%`）
- **交易日**：周一至周五；交易时段 9:30–11:30、13:00–15:00

---

## 刷新流程（`refreshAll`）

1. **并行拉取**：每个基金同时请求 `fetchValuationAndNav`（估值 + pingzhong + F10 并行）
2. **快照计算**：`loadSnapshotFromData` 根据时段与数据源计算 currentPrice、todayBase、todayRate
3. **汇总**：遍历快照累加 totalCost、totalTodayProfit、totalCumulativeProfit、totalHoldValue
4. **失败兜底**：若全部拉取失败，**不覆盖**旧 snapshots，避免列表变空
5. **单基金失败**：该基金用上一次快照（`oldByID[fund.id]`）保留
6. **日期标签**：若 `beforeMarket || !tradingDay`，设置 `showTodayProfitDateLabel`、`todayProfitDateLabel`（MM-dd 格式）

**触发时机**：App 启动、下拉刷新、从后台回到前台、每 5 分钟定时刷新

---

## 错误处理

| 场景 | 行为 |
|------|------|
| 估值 API 失败 | 用 latestPublished / dwjz 兜底，可能无当日估值 |
| 净值 API 全部失败 | 用估值接口的 valNav 或 nil |
| 全部基金拉取失败 | 不覆盖 snapshots，保留上次数据 |
| 基金代码校验失败 | 编辑页保存时弹窗「基金代码无效」 |
| AI 未配置 API Key | 提示前往阿里云百炼申请 |

---

## AI 分析

- **配置**：阿里云百炼兼容接口（`dashscope.aliyuncs.com`），API Key 存本地
- **自动触发**：早盘结束（11:30 左右）、收盘前 30 分钟（14:30 左右），每日每时段仅一次（`ai_auto_trigger_cache_v1`）
- **手动触发**：点击 AI 按钮或「重新分析」
- **Prompt**：组合汇总 + 持仓明细 + 时段任务（早盘总结 / 收盘前建议 / 实时分析）

---

## 本地存储（UserDefaults）

| Key | 内容 |
|-----|------|
| `fund_list` | 持仓列表 `[FundPosition]` |
| `ai_config_v1` | AI 接口配置（endpoint、model、apiKey） |
| `ai_auto_enabled` | 是否开启自动分析 |
| `ai_auto_trigger_cache_v1` | 自动触发去重（日期+时段） |
| `intraday_pct_cache_v1` | 日内走势缓存 `[code: [day: [IntradayPoint]]]` |
| `fund_theme` | 主题（light / dark / system） |

---

## 已知限制

- **QDII / T+2 基金**：pingzhong 数据可能滞后，F10 更新更及时；收盘后净值未出时务必用估值接口的 dwjz/gszzl
- **接口依赖**：依赖天天基金、东方财富公开接口，无官方文档，可能变动
- **时区**：交易日判断使用设备本地时区（`TimeZone.current`）

---

## 关键代码索引

| 逻辑 | 文件 | 函数/位置 |
|------|------|-----------|
| 刷新入口 | FundViewModel | `refreshAll()` |
| 快照计算 | FundViewModel | `loadSnapshotFromData()` |
| 日期标签格式化 | FundViewModel | `formatLatestDateAsMMdd()` |
| 时段判断 | FundServices | `DateHelper.marketOpenNow()` 等 |
| 净值合并 | FundServices | `mergeNavPair()` |
| 估值请求 | FundServices | `fetchValuation()` |
| 业绩走势 | FundServices | `fetchDailyPerformanceTrend()`、`fetchCSI300Trend()` |
| 编辑校验 | MainView | `FundEditorView` 保存时 `validateFundCode` |

---

## 打开方式

1. 使用 Xcode 打开 `FundValuationApp.xcodeproj`
2. 选择 `FundValuationApp` Scheme
3. 选择 iPhone 模拟器或真机运行

---

## 依赖

- SwiftUI
- Charts（系统 Charts 框架）
- 无第三方网络库，使用 `URLSession`
