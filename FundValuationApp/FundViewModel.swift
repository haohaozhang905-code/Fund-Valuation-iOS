import Foundation
import Combine

@MainActor
final class FundViewModel: ObservableObject {
    @Published var funds: [FundPosition] = []
    @Published var snapshots: [FundSnapshot] = []
    @Published var summary = PortfolioSummary()
    @Published var expandedFundIDs: Set<String> = []

    @Published var sortField: SortField = .today
    @Published var sortOrder: SortOrder = .desc

    @Published var aiConfig = AIConfig()
    @Published var aiAutoEnabled = true
    @Published var aiStatus = "待分析：收盘前30分钟会自动分析，早盘结束后会自动总结。"
    @Published var aiOutput = "这里会显示 AI 对当前市场与持仓的分析建议。"
    @Published var isAiRunning = false
    @Published var isRefreshing = false

    private var intradaySeriesByCode: [String: [String: [IntradayPoint]]] = [:]

    private let dataService = FundDataService()
    private let aiService = AIService()

    private let fundsKey = "fund_list"
    private let aiConfigKey = "ai_config_v1"
    private let aiAutoKey = "ai_auto_enabled"
    private let aiTriggerKey = "ai_auto_trigger_cache_v1"
    private let intradayCacheKey = "intraday_pct_cache_v1"

    var sortedSnapshots: [FundSnapshot] {
        snapshots.sorted { lhs, rhs in
            let l = sortField == .today ? (lhs.todayProfit ?? -.infinity) : (lhs.cumulativeProfit ?? -.infinity)
            let r = sortField == .today ? (rhs.todayProfit ?? -.infinity) : (rhs.cumulativeProfit ?? -.infinity)
            return sortOrder == .asc ? (l < r) : (l > r)
        }
    }

    func loadInitialData() {
        loadFunds()
        loadAIConfig()
        loadIntradayCache()
        aiAutoEnabled = UserDefaults.standard.string(forKey: aiAutoKey) != "0"
        if funds.isEmpty {
            funds = [FundPosition(fundCode: "013841", costPrice: 1.6153, shares: 4975.88)]
            persistFunds()
        }
    }

    func toggleTheme(current: String) -> String {
        switch current {
        case "light": return "dark"
        case "dark": return "system"
        default: return "light"
        }
    }

    func toggleSort(_ field: SortField) {
        if sortField != field {
            sortField = field
            sortOrder = .desc
        } else {
            sortOrder = sortOrder == .desc ? .asc : .desc
        }
    }

    /// 验证基金代码是否有效
    func validateFundCode(_ code: String) async -> Bool {
        await dataService.validateFundCode(code)
    }

    /// 业绩走势：本基金 + 沪深300，按时间范围
    func fetchPerformanceTrend(fundCode: String, range: PerformanceRange) async -> (fund: [DailyPerformancePoint], index: [DailyPerformancePoint]) {
        let limit = range.tradingDays
        async let fundData = dataService.fetchDailyPerformanceTrend(fundCode: fundCode, tradingDaysLimit: limit)
        async let indexData = dataService.fetchCSI300Trend(tradingDaysLimit: limit)
        let fund = await fundData
        let index = await indexData
        return (fund, index)
    }

    func searchFunds(query: String) async -> [FundSearchResult] {
        let normalized = FundPosition.normalizeCode(query)
        guard normalized.count == 6 else { return [] }
        async let valuation = dataService.fetchValuation(fundCode: normalized)
        async let navResult = dataService.fetchNavWithName(fundCode: normalized)
        let (v, nav) = await (valuation, navResult)
        let name = (v?.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? v?.name : nil)
            ?? (nav.1?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? nav.1 : nil)
        guard v != nil || nav.0?.latest != nil else { return [] }
        return [FundSearchResult(code: normalized, name: name ?? normalized)]
    }

    func addOrUpdateFund(editingID: String?, code: String, costPrice: Double, shares: Double, fundName: String? = nil) -> Bool {
        let normalized = FundPosition.normalizeCode(code)
        guard normalized.count == 6, costPrice > 0, shares > 0 else { return false }

        if let duplicateIdx = funds.firstIndex(where: { $0.fundCode == normalized && $0.id != editingID }) {
            funds[duplicateIdx].costPrice = costPrice
            funds[duplicateIdx].shares = shares
            if let fundName {
                funds[duplicateIdx].fundName = fundName
            }
            if let editingID {
                funds.removeAll { $0.id == editingID }
            }
        } else if let editingID, let idx = funds.firstIndex(where: { $0.id == editingID }) {
            funds[idx].fundCode = normalized
            funds[idx].costPrice = costPrice
            funds[idx].shares = shares
            if let fundName {
                funds[idx].fundName = fundName
            }
        } else {
            funds.append(FundPosition(fundCode: normalized, costPrice: costPrice, shares: shares, fundName: fundName ?? ""))
        }
        persistFunds()
        return true
    }

    func deleteFund(_ id: String) {
        funds.removeAll { $0.id == id }
        persistFunds()
    }

    func refreshAll() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let marketOpen = DateHelper.marketOpenNow()
        let tradingDay = DateHelper.nowTradingDay()
        let beforeMarket = DateHelper.marketBeforeOpenToday()
        let afterMarket = DateHelper.marketAfterCloseToday()
        summary.tradingBadge = (marketOpen ? "交易中" : "休市") + " · " + timeString()

        if funds.isEmpty {
            snapshots = []
            summary.totalCost = 0
            summary.totalTodayProfit = 0
            summary.totalCumulativeProfit = 0
            summary.totalHoldValue = 0
            summary.latestDate = ""
            summary.showTodayProfitDateLabel = false
            summary.todayProfitDateLabel = ""
            await autoRunAIIfNeeded()
            return
        }

        var builtSnapshots: [FundSnapshot] = []
        var totalCost: Double = 0
        var totalTodayProfit: Double = 0
        var totalCumProfit: Double = 0
        var totalHoldValue: Double = 0
        var latestDate = ""

        let ds = dataService
        var fetched: [(FundPosition, FundValuationResponse?, NavPair?, String?)] = []
        await withTaskGroup(of: (FundPosition, FundValuationResponse?, NavPair?, String?).self) { group in
            for fund in funds {
                group.addTask {
                    let (v, n, name) = await ds.fetchValuationAndNav(fundCode: fund.fundCode)
                    return (fund, v, n, name)
                }
            }
            for await result in group {
                fetched.append(result)
            }
        }
        for (fund, valuation, navPair, pingzhongName) in fetched {
            if let snap = loadSnapshotFromData(fund: fund, valuation: valuation, navPair: navPair, pingzhongName: pingzhongName, marketOpen: marketOpen, beforeMarket: beforeMarket, afterMarket: afterMarket, tradingDay: tradingDay) {
                builtSnapshots.append(snap)
            }
        }

        let byID = Dictionary(uniqueKeysWithValues: builtSnapshots.map { ($0.id, $0) })
        let oldByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        builtSnapshots = funds.compactMap { fund in
            byID[fund.id] ?? oldByID[fund.id]
        }

        // 若全部拉取失败（如网络异常），不覆盖旧数据，避免列表变空
        guard !builtSnapshots.isEmpty || funds.isEmpty else {
            await autoRunAIIfNeeded()
            return
        }

        for snap in builtSnapshots {
            let cost = snap.costPrice * snap.shares
            totalCost += cost
            totalTodayProfit += snap.todayProfit ?? 0
            totalCumProfit += snap.cumulativeProfit ?? 0
            totalHoldValue += snap.holdValue ?? cost  // 账户总资产 = 各持仓市值之和，无市值时用成本兜底
            if DateHelper.compareYMD(snap.dataDate, latestDate) == .orderedDescending {
                latestDate = snap.dataDate
            }
        }

        snapshots = builtSnapshots
        summary.totalCost = totalCost
        summary.totalTodayProfit = totalTodayProfit
        summary.totalCumulativeProfit = totalCumProfit
        summary.totalHoldValue = totalHoldValue
        summary.latestDate = latestDate
        let beforeNextTradingDayOpens = beforeMarket || !tradingDay
        summary.showTodayProfitDateLabel = beforeNextTradingDayOpens && !latestDate.isEmpty
        summary.todayProfitDateLabel = formatLatestDateAsMMdd(latestDate)
        await autoRunAIIfNeeded()
    }

    private func formatLatestDateAsMMdd(_ ymd: String) -> String {
        let parts = String(ymd.prefix(10)).split(separator: "-")
        guard parts.count >= 2 else { return "" }
        return "\(parts[1])-\(parts[2])"
    }

    private func loadSnapshotFromData(fund: FundPosition, valuation: FundValuationResponse?, navPair: NavPair?, pingzhongName: String?, marketOpen: Bool, beforeMarket: Bool, afterMarket: Bool, tradingDay: Bool) -> FundSnapshot? {
        let latestNav = navPair?.latest
        let previousNav = navPair?.previous

        let valNav: NavPoint? = {
            guard let jzrq = valuation?.jzrq, let dwjz = Double(valuation?.dwjz ?? "") else { return nil }
            return NavPoint(date: String(jzrq.prefix(10)), value: dwjz)
        }()

        var latestPublished = latestNav
        if latestPublished == nil { latestPublished = valNav }
        if let valNav, let existingPublished = latestPublished, DateHelper.compareYMD(valNav.date, existingPublished.date) == .orderedDescending {
            latestPublished = valNav
        }

        let dwjz = latestPublished?.value ?? Double(valuation?.dwjz ?? "")
        let gsz = Double(valuation?.gsz ?? "")
        let todayYMD = DateHelper.ymdString(from: Date())
        let latestIsToday = latestPublished != nil && DateHelper.compareYMD(latestPublished!.date, todayYMD) == .orderedSame
        let valuationDate = String((valuation?.gztime ?? "").prefix(10))
        let hasTodayValuation = !valuationDate.isEmpty && valuationDate == todayYMD && gsz != nil

        // 1. 交易日+交易中：按实时估值
        // 2. 交易日+交易后：净值已有用净值，净值暂无用当日估值
        // 3. 交易日+交易前：按上个交易日净值
        // 4. 非交易日：按上个交易日净值
        let currentPrice: Double?
        let currentPriceLabel: String
        let dataDate: String
        let todayBase: Double?
        var useGszzlForRate: Double? = nil  // 估值接口的 gszzl，与 gsz/dwjz 同源，避免多数据源混算

        if marketOpen {
            // 1. 交易中：实时估值，今日基准=昨日净值（最新已公布）
            if let gsz {
                currentPrice = gsz
                currentPriceLabel = "估值"
                dataDate = String((valuation?.gztime ?? latestPublished?.date ?? "").prefix(10))
                todayBase = latestPublished?.value
            } else {
                currentPrice = latestPublished?.value ?? dwjz
                currentPriceLabel = "净值"
                dataDate = latestPublished?.date ?? String((valuation?.jzrq ?? "").prefix(10))
                todayBase = previousNav?.value
            }
        } else if beforeMarket || !tradingDay {
            // 下个交易日未开盘：展示上个交易日数据，当日收益 = (最新净值 - 前日净值) × 份额
            currentPrice = latestPublished?.value ?? dwjz
            currentPriceLabel = "净值"
            dataDate = latestPublished?.date ?? String((valuation?.jzrq ?? "").prefix(10))
            todayBase = previousNav?.value ?? currentPrice
        } else if afterMarket {
            // 2. 交易后：净值已有用净值，净值暂无用当日估值
            if latestIsToday {
                currentPrice = latestPublished?.value ?? dwjz
                currentPriceLabel = "净值"
                dataDate = latestPublished?.date ?? String((valuation?.jzrq ?? "").prefix(10))
                todayBase = previousNav?.value
            } else if hasTodayValuation {
                // 净值未出用估值：今日基准必须用估值接口的 dwjz（与 gsz 同源），涨跌优先用 gszzl
                currentPrice = gsz ?? latestPublished?.value ?? dwjz
                currentPriceLabel = "估值"
                dataDate = valuationDate
                todayBase = Double(valuation?.dwjz ?? "") ?? previousNav?.value ?? latestPublished?.value ?? dwjz
                useGszzlForRate = Double(valuation?.gszzl ?? "")
            } else {
                currentPrice = latestPublished?.value ?? dwjz
                currentPriceLabel = "净值"
                dataDate = latestPublished?.date ?? String((valuation?.jzrq ?? "").prefix(10))
                todayBase = previousNav?.value
            }
        } else {
            // 兜底（如午休外的边界）：同交易后
            if latestIsToday {
                currentPrice = latestPublished?.value ?? dwjz
                currentPriceLabel = "净值"
                dataDate = latestPublished?.date ?? String((valuation?.jzrq ?? "").prefix(10))
                todayBase = previousNav?.value
            } else if hasTodayValuation {
                currentPrice = gsz ?? latestPublished?.value ?? dwjz
                currentPriceLabel = "估值"
                dataDate = valuationDate
                todayBase = Double(valuation?.dwjz ?? "") ?? previousNav?.value ?? latestPublished?.value ?? dwjz
                useGszzlForRate = Double(valuation?.gszzl ?? "")
            } else {
                currentPrice = latestPublished?.value ?? dwjz
                currentPriceLabel = "净值"
                dataDate = latestPublished?.date ?? String((valuation?.jzrq ?? "").prefix(10))
                todayBase = previousNav?.value
            }
        }

        guard currentPrice != nil else { return nil }
        let todayRate: Double? = {
            if let gszzl = useGszzlForRate { return gszzl }
            return (todayBase != nil && (todayBase ?? 0) > 0 && currentPrice != nil) ? ((currentPrice! - todayBase!) / todayBase! * 100) : nil
        }()
        let todayProfit = (todayBase != nil && currentPrice != nil) ? ((currentPrice! - todayBase!) * fund.shares) : nil
        let cumProfit = currentPrice != nil ? ((currentPrice! - fund.costPrice) * fund.shares) : nil
        let cumRate = currentPrice != nil && fund.costPrice > 0 ? ((currentPrice! - fund.costPrice) / fund.costPrice * 100) : nil
        let holdValue = currentPrice != nil ? (currentPrice! * fund.shares) : nil
        let displayName = (valuation?.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? valuation?.name : nil)
            ?? (pingzhongName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? pingzhongName : nil)
            ?? fund.fundName.ifEmpty(fallback: fund.fundCode)
        let hasTodayNav = currentPriceLabel == "净值" && DateHelper.compareYMD(dataDate, todayYMD) == .orderedSame
        let baseline = (latestPublished?.value ?? previousNav?.value ?? dwjz)
        let (intraday, intradayDate) = buildIntradaySeries(
            fundCode: fund.fundCode,
            valuationTime: valuation?.gztime,
            currentPrice: currentPrice,
            baseline: baseline,
            marketOpen: marketOpen,
            fallbackPct: todayRate
        )

        return FundSnapshot(
            id: fund.id,
            code: fund.fundCode,
            name: displayName,
            costPrice: fund.costPrice,
            shares: fund.shares,
            currentPrice: currentPrice,
            currentPriceLabel: currentPriceLabel,
            latestPublishedNav: latestPublished?.value,
            previousNav: previousNav?.value,
            dataDate: dataDate,
            valuationTime: valuation?.gztime ?? "--",
            todayProfit: todayProfit,
            todayRate: todayRate,
            cumulativeProfit: cumProfit,
            cumulativeRate: cumRate,
            holdValue: holdValue,
            intradayTrend: intraday,
            intradayTrendDate: intradayDate,
            hasTodayNav: hasTodayNav
        )
    }

    private func buildIntradaySeries(
        fundCode: String,
        valuationTime: String?,
        currentPrice: Double?,
        baseline: Double?,
        marketOpen: Bool,
        fallbackPct: Double?
    ) -> ([IntradayPoint], String) {
        var perDay = intradaySeriesByCode[fundCode] ?? [:]
        let time = DateHelper.parseGZTime(valuationTime) ?? Date()
        let day = DateHelper.ymdString(from: time)

        if marketOpen, let currentPrice, let baseline, baseline > 0 {
            let pct = (currentPrice - baseline) / baseline * 100
            let rounded = Date(timeIntervalSince1970: floor(time.timeIntervalSince1970 / 60) * 60)
            var current = perDay[day] ?? []
            let newPoint = IntradayPoint(timestamp: rounded.timeIntervalSince1970, pct: pct)
            if let last = current.last, abs(last.timestamp - newPoint.timestamp) < 1 {
                current[current.count - 1] = newPoint
            } else {
                current.append(newPoint)
            }
            if current.count > 240 {
                current = Array(current.suffix(240))
            }
            perDay[day] = current
            intradaySeriesByCode[fundCode] = perDay
            persistIntradayCache()
            return (current, day)
        }

        if let latestDay = perDay.keys.sorted().last, let points = perDay[latestDay], !points.isEmpty {
            return (points, latestDay)
        }

        let syntheticDay = day
        let synthetic = syntheticSessionPoints(dayYMD: syntheticDay, pct: fallbackPct ?? 0)
        perDay[syntheticDay] = synthetic
        intradaySeriesByCode[fundCode] = perDay
        persistIntradayCache()
        return (synthetic, syntheticDay)
    }

    private func syntheticSessionPoints(dayYMD: String, pct: Double) -> [IntradayPoint] {
        let marks = ["09:30", "10:30", "11:30", "13:00", "14:00", "15:00"]
        return marks.compactMap { hm in
            guard let date = DateHelper.dateBy(dayYMD: dayYMD, hm: hm) else { return nil }
            return IntradayPoint(timestamp: date.timeIntervalSince1970, pct: pct)
        }
    }

    func saveAIConfig() {
        let normalized = aiService.normalizedEndpoint(aiConfig.endpoint)
        aiConfig.endpoint = normalized
        if let data = try? JSONEncoder().encode(aiConfig) {
            UserDefaults.standard.set(data, forKey: aiConfigKey)
        }
        aiStatus = "AI 配置已保存。"
    }

    func setAIAutoEnabled(_ enabled: Bool) {
        aiAutoEnabled = enabled
        UserDefaults.standard.set(enabled ? "1" : "0", forKey: aiAutoKey)
    }

    func runAIAnalysis(mode: AISlotMode, auto: Bool) async {
        if isAiRunning { return }
        if aiConfig.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            aiStatus = "未配置 API Key"
            aiOutput = "当前暂未配置API Key，请前往阿里云百炼大模型平台申请 API Key 后重试。"
            return
        }

        isAiRunning = true
        aiStatus = (auto ? "自动" : "手动") + "分析中..."
        aiOutput = ""

        do {
            let prompt = buildAIPrompt(mode: mode)
            try await aiService.runAnalysisStream(prompt: prompt, config: aiConfig) { accumulated in
                Task { @MainActor in
                    self.aiOutput = accumulated
                }
            }
            aiStatus = (auto ? "自动" : "手动") + "分析完成：\(timeString())"
        } catch {
            aiStatus = "AI 分析失败：\(error.localizedDescription)"
        }
        isAiRunning = false
    }

    private func autoRunAIIfNeeded() async {
        guard aiAutoEnabled else { return }
        guard let mode = aiSlotMode() else { return }
        let day = currentYMD()
        let key = "\(day)_\(mode.rawValue)"
        var cache = (UserDefaults.standard.dictionary(forKey: aiTriggerKey) as? [String: Double]) ?? [:]
        if cache[key] != nil { return }
        cache[key] = Date().timeIntervalSince1970
        UserDefaults.standard.set(cache, forKey: aiTriggerKey)
        await runAIAnalysis(mode: mode, auto: true)
    }

    private func aiSlotMode() -> AISlotMode? {
        guard DateHelper.nowTradingDay() else { return nil }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let m = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if (690...705).contains(m) { return .midday }
        if (870...900).contains(m) { return .preclose }
        return nil
    }

    private func buildAIPrompt(mode: AISlotMode) -> String {
        let fundLines = sortedSnapshots.map { s in
            "\(s.name) | 当日涨跌:\(NumberFormat.signedPercent(s.todayRate)) 当日收益:\(NumberFormat.fixed(s.todayProfit)) | 累计涨跌:\(NumberFormat.signedPercent(s.cumulativeRate)) 累计收益:\(NumberFormat.fixed(s.cumulativeProfit)) | 总成本:\(NumberFormat.fixed(s.costPrice * s.shares)) 总市值:\(NumberFormat.fixed(s.holdValue))"
        }.joined(separator: "\n")

        let taskLine: String
        let timeDesc: String
        switch mode {
        case .preclose:
            timeDesc = "收盘前30分钟"
            taskLine = "请重点分析今天涨跌结构，并给出仓位调整建议（含减仓比例建议区间与触发条件）。"
        case .realtime:
            timeDesc = "用户主动触发，实时分析"
            taskLine = "请基于当前持仓实时数据，给出简要分析结论与操作建议（含仓位调整方向）。"
        case .midday:
            timeDesc = "早盘结束后"
            taskLine = "请给出早盘总结，关注风格切换、板块轮动与下午风险点。"
        }

        return [
            "你是A股场外基金组合分析师。注意：持仓均为场外基金，不涉及场内交易。请基于以下信息给出简明、可执行建议。",
            "输出格式：1) 市场结论 2) 组合风险 3) 操作建议（分点，量化到仓位百分比） 4) 需要警惕的信号。重点内容请用**加粗**标出。",
            "当前时段：\(timeDesc)",
            "组合汇总：当日收益 \(NumberFormat.fixed(summary.totalTodayProfit))，累计收益 \(NumberFormat.fixed(summary.totalCumulativeProfit))，累计收益率 \(NumberFormat.fixed(summary.totalCumulativeRate))%",
            "持仓明细：\n\(fundLines.isEmpty ? "暂无" : fundLines)",
            taskLine
        ].joined(separator: "\n")
    }

    private func loadFunds() {
        guard let data = UserDefaults.standard.data(forKey: fundsKey),
              let loaded = try? JSONDecoder().decode([FundPosition].self, from: data)
        else {
            funds = []
            return
        }
        funds = loaded
    }

    private func persistFunds() {
        guard let data = try? JSONEncoder().encode(funds) else { return }
        UserDefaults.standard.set(data, forKey: fundsKey)
    }

    private func loadAIConfig() {
        guard let data = UserDefaults.standard.data(forKey: aiConfigKey),
              let loaded = try? JSONDecoder().decode(AIConfig.self, from: data)
        else {
            aiConfig = AIConfig()
            return
        }
        aiConfig = loaded
    }

    private func loadIntradayCache() {
        guard let data = UserDefaults.standard.data(forKey: intradayCacheKey),
              let loaded = try? JSONDecoder().decode([String: [String: [IntradayPoint]]].self, from: data) else {
            intradaySeriesByCode = [:]
            return
        }
        intradaySeriesByCode = loaded
    }

    private func persistIntradayCache() {
        guard let data = try? JSONEncoder().encode(intradaySeriesByCode) else { return }
        UserDefaults.standard.set(data, forKey: intradayCacheKey)
    }

    private func currentYMD() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func timeString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

private extension String {
    func ifEmpty(fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
