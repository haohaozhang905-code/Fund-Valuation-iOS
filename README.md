# Fund Valuation iOS

将网页版 `Fund Valuation Viewing` 迁移为 SwiftUI iOS App 的版本，支持：

- 基金持仓新增 / 编辑 / 删除（本地持久化）
- 实时估值 + 历史净值回退计算
- 当日收益、累计收益、资产汇总
- 按当日收益 / 持有收益排序
- 主题切换（浅色 / 深色 / 跟随系统）
- AI 分析（手动触发 + 自动时段触发 + 本地配置）

## 打开方式

1. 使用 Xcode 打开 `FundValuationApp.xcodeproj`
2. 选择 `FundValuationApp` Scheme
3. 选择 iPhone 模拟器或真机运行

## 说明

- 数据接口沿用网页版：
  - `https://fundgz.1234567.com.cn/js/{fundCode}.js`
  - `https://fund.eastmoney.com/pingzhongdata/{fundCode}.js`
- AI 配置保存在本地 `UserDefaults`，不会上传到其他服务。
