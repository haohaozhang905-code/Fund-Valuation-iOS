# Fund Valuation iOS

SwiftUI 持仓看板 App，当前覆盖 A 股基金和美股股票两类资产。目标是打开 App 即可查看持仓资产、当日盈亏、累计盈亏和行情状态，减少频繁进入银行/券商 App 登录验证的成本。

## 功能概览

| 模块 | 能力 |
|---|---|
| 账号系统 | 邮箱注册/登录、退出登录、注销账号、邮箱验证码找回密码 |
| 基金持仓 | 新增、编辑、删除、重复基金覆盖、本地缓存、登录后同步 |
| 基金行情 | 天天基金估值、东方财富净值、F10 兜底、沪深300走势对比 |
| 美股持仓 | 新增、编辑、删除、重复股票覆盖、本地缓存、登录后同步 |
| 美股行情 | Finnhub、Alpha Vantage、THS Bridge、Mock Provider |
| 股票搜索 | 按 Provider 搜索 symbol 和公司名称 |
| K 线 | 美股 K 线展示、区间切换、缓存兜底 |
| 刷新 | 当前 Tab 刷新、下拉刷新、回前台刷新、定时刷新 |
| 设置 | 主题、AI 配置、美股数据源配置 |
| AI 分析 | 当前用于基金组合分析 |

## 项目结构

```text
FundValuationApp/
├── FundValuationApp.swift
├── RootView.swift
├── AuthViews.swift
├── AuthModels.swift
├── AuthService.swift
├── SessionViewModel.swift
├── KeychainStore.swift
├── MainView.swift
├── FundModels.swift
├── FundServices.swift
├── FundViewModel.swift
├── StockModels.swift
├── StockServices.swift
├── StockViewModel.swift
└── StockViews.swift

ths-bridge/
├── app.py
├── auth_service.py
├── database.py
├── models.py
├── schemas.py
├── mailer.py
├── alembic/
├── requirements.txt
└── README.md

docs/
├── 01-项目现状与产品原则.md
├── 02-架构与模块规范.md
├── 03-数据源与刷新策略.md
├── 04-UI交互与视觉规范.md
├── 05-开发规范与验收清单.md
└── 06-后续规划.md
```

## 数据源

基金：

- 天天基金估值：`fundgz.1234567.com.cn`
- 东方财富净值：`fund.eastmoney.com/pingzhongdata`
- 东方财富 F10：`fundf10.eastmoney.com/F10DataApi`
- 沪深300走势：指数 K 线接口

美股：

- `THS Bridge`：推荐主源，iOS 通过自建 Bridge 获取同花顺/Westock 等上游数据。
- `Finnhub`：备用源，需要 API Key。
- `Alpha Vantage`：低频兜底，需要 API Key。
- `Mock`：本地调试。

## 核心口径

- 基金使用人民币，美股使用美元，不做合并总资产。
- 基金当日收益按当前估值/净值与基准净值差值乘以份额计算。
- 美股当日盈亏按 `regularPrice - previousClose` 计算。
- 美股累计盈亏按 `regularPrice - averageCost` 计算。
- 盘前/盘后数据只作为补充行情，不覆盖主收益口径。
- 网络失败时保留旧数据，不清空列表，不把价格置为 0。

## 刷新策略

| 触发 | 基金 | 美股 |
|---|---:|---:|
| 当前 Tab 停留定时刷新 | 5 分钟 | 60 秒 |
| 频繁切 Tab 防抖 | 5 分钟 | 30 秒 |
| 下拉刷新/顶部刷新 | 强制刷新当前 Tab | 强制刷新当前 Tab |
| App 回前台 | 强制刷新当前 Tab | 强制刷新当前 Tab |

## 构建

```bash
xcodebuild -project FundValuationAPP.xcodeproj -scheme FundValuationApp -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/FundValuationDerivedData CODE_SIGNING_ALLOWED=NO build
```

如果本机没有可用 iOS Simulator Runtime，可能出现 AssetCatalog/CoreSimulator 相关错误。判断代码是否通过时优先看是否存在 Swift 编译错误；UI 仍需在 Xcode 真机或可用模拟器中验证。

## 文档

详细产品原则、架构、数据源、UI 规范和验收清单见 `docs/`。后续修改交互、数据源、刷新策略或视觉规范时，需要同步更新对应 md 文件。
