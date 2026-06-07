# FinMate Android — 执行计划

## 1. 项目概览

**目标**：用 Flutter 实现 FinMate Android 版，功能与 iOS 版对齐。

**后端复用**：
- 账号体系、持仓同步、基金行情、美股行情 → 全部复用独立 FinMate Backend
- 生产地址第一阶段保持 `https://thsbridge.zeabur.app`
- OpenAPI 合约以独立后端项目的 `/openapi.json` 和 `docs/API.md` 为准

**不做的**：
- 银行/券商登录
- 自动同步交易持仓
- 下单交易
- Android 独立用户表或独立持仓格式

---

## 2. 技术选型

| 层 | 方案 | 理由 |
|---|---|---|
| UI 框架 | Flutter | 一套代码 Android + iOS，减少维护成本 |
| 语言 | Dart | Flutter 原生语言 |
| 状态管理 | Riverpod | 类型安全、易于测试 |
| 网络 | dio | 拦截器、超时、重试支持好 |
| 本地存储 | shared_preferences / hive | 替代 UserDefaults |
| 图表 | fl_chart | 支持折线图、蜡烛图 |
| Markdown | flutter_markdown | AI 分析报告渲染 |

## 3. 项目结构

```
finmate_flutter/
├── lib/
│   ├── main.dart                  # 入口
│   ├── app.dart                   # 根 Widget + Tab 切换
│   ├── models/                    # 数据模型
│   │   ├── fund_models.dart
│   │   └── stock_models.dart
│   ├── services/                  # 网络层
│   │   ├── auth_api_service.dart  # 登录/注册/找回密码/当前用户
│   │   ├── portfolio_api_service.dart # 云端持仓 GET/PUT
│   │   ├── fund_api_service.dart  # FinMate Backend 基金代理 API
│   │   ├── stock_api_service.dart # FinMate Backend 美股 API
│   │   └── ai_service.dart        # LLM API
│   ├── viewmodels/                # 状态管理
│   │   ├── fund_viewmodel.dart
│   │   └── stock_viewmodel.dart
│   ├── pages/                     # UI 页面
│   │   ├── fund/
│   │   │   ├── fund_tab.dart         # 基金首页
│   │   │   ├── fund_detail_page.dart # 基金详情
│   │   │   ├── fund_editor_page.dart # 添加/编辑
│   │   │   └── widgets/              # 基金组件
│   │   │       ├── fund_list_row.dart
│   │   │       ├── fund_banner.dart
│   │   │       └── performance_chart.dart
│   │   ├── stock/
│   │   │   ├── stock_tab.dart        # 美股首页
│   │   │   ├── stock_detail_page.dart# 美股详情
│   │   │   ├── stock_editor_page.dart# 添加/编辑
│   │   │   └── widgets/
│   │   │       ├── stock_list_row.dart
│   │   │       ├── stock_banner.dart
│   │   │       └── candlestick_chart.dart
│   │   ├── settings/
│   │   │   └── settings_page.dart    # 设置
│   │   └── ai/
│   │       └── ai_analysis_page.dart # AI 分析
│   └── utils/                     # 工具
│       ├── number_format.dart     # 数字格式化
│       ├── date_helper.dart       # 日期工具
│       └── constants.dart         # 常量、颜色、主题
├── test/
├── pubspec.yaml
└── README.md
```

## 4. 实现顺序（MVP → 迭代）

### Phase 1：脚手架 + 美股（先跑通）

| # | 任务 | 预估 |
|---|------|------|
| 1 | 创建 Flutter 项目，配好依赖 | 10min |
| 2 | 定义美股数据模型 | 15min |
| 3 | 实现 StockApiService（调 FinMate Backend） | 20min |
| 4 | 实现 StockViewModel | 20min |
| 5 | 实现美股首页（Banner + 列表） | 30min |
| 6 | 实现添加/编辑持仓 | 30min |
| 7 | 实现美股详情页 + K 线图 | 40min |
| 8 | 设置页（数据源配置） | 20min |
| | **合计** | **约 3h** |

### Phase 2：基金模块

| # | 任务 | 预估 |
|---|------|------|
| 9 | 定义基金数据模型 | 15min |
| 10 | 实现 FundApiService（调 FinMate Backend） | 30min |
| 11 | 实现 FundViewModel | 25min |
| 12 | 实现基金首页（Banner + 列表） | 30min |
| 13 | 实现添加/编辑基金 | 25min |
| 14 | 实现基金详情页 + 走势图 | 40min |
| 15 | AI 分析页面 | 30min |
| | **合计** | **约 3h** |

### Phase 3：打磨

| # | 任务 | 预估 |
|---|------|------|
| 16 | 主题统一（暗色模式） | 20min |
| 17 | 下拉刷新 | 15min |
| 18 | 本地持久化（持仓数据） | 20min |
| 19 | 横滑 Tab 切换 | 15min |
| 20 | 安装包生成（APK） | 10min |
| | **合计** | **约 1.5h** |

**总计：约 7.5 小时**

## 5. 美股模块详细设计

### 5.1 API 客户端

```dart
class StockApiService {
  final String baseUrl = 'https://thsbridge.zeabur.app';

  Future<List<StockSearchResult>> search(String query);
  Future<StockQuote> getQuote(String symbol);
  Future<StockKLineData> getKLine(String symbol, {int count = 120});
}
```

✅ 后端由独立 FinMate Backend 项目维护。Android 只实现客户端，不新增后端。

### 5.2 数据模型

```dart
class StockPosition {
  String id;
  String symbol;
  double averageCost;
  double shares;
  String displayName;
}

class StockQuote {
  String symbol;
  String? name;
  double? regularPrice;
  double? previousClose;
  // ...
}
```

### 5.3 状态管理

```dart
@riverpod
class StockViewModel extends _$StockViewModel {
  List<StockPosition> positions = [];
  List<StockSnapshot> snapshots = [];
  // ...
  
  Future<void> refreshAll() async { /* 串行调 FinMate Backend */ }
  Future<List<StockSearchResult>> search(String query) async { /* 调 FinMate Backend */ }
  Future<StockKLineData> fetchKLine(String symbol) async { /* 调 FinMate Backend */ }
}
```

## 6. 基金模块详细设计

### 6.1 API 客户端

基金数据源与 iOS/Web 完全一致，统一调 FinMate Backend：

| 用途 | API |
|------|-----|
| 实时估值 | `GET /v1/funds/valuation/{code}` |
| 净值趋势 | `GET /v1/funds/nav-trend/{code}` |
| 最新净值 | `GET /v1/funds/nav-latest/{code}` |
| 沪深300 | `GET /v1/index/csi300` |

### 6.2 本地持久化

本地存储只作为缓存和离线兜底。登录后权威持仓来自：

```http
GET /v1/portfolio
PUT /v1/portfolio
```

Token 可用 `flutter_secure_storage` 保存；不要把持仓云端格式改成 Android 专用格式。

## 7. 视觉规范

沿用 iOS 版配色方案（暗色模式）：

```
页面背景: #1C1C1E
卡片/顶部栏: #0A0A0A
辅助文字: #A1A1A1
涨/盈利: 红色 (#FB2C36)
跌/亏损: 绿色 (#00A63E)
强调色/链接: #2B7FFF
```

卡片圆角 18，Banner 圆角 22，与 iOS 保持一致。

## 8. 安装与分发

```
flutter build apk --release
```

生成的 APK 在 `build/app/outputs/flutter-apk/app-release.apk`，直接发给任何人安装。

如需上架应用商店，需要开发者账号（一次性费用 $25）。
