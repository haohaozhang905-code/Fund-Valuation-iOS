import Foundation
import Combine

@MainActor
final class StockViewModel: ObservableObject {
    @Published var positions: [StockPosition] = []
    @Published var snapshots: [StockSnapshot] = []
    @Published var summary = StockPortfolioSummary()
    @Published var isRefreshing = false
    @Published var providerConfig = StockProviderConfig()
    @Published var sortField: StockSortField = .todayProfit
    @Published var sortOrder: StockSortOrder = .desc
    @Published var lastRefreshMessage = ""
    @Published var klineCache: [String: StockKLineData] = [:]

    private var quoteCache: [String: StockQuote] = [:]

    private let positionsKey = "stock_positions_v1"
    private let quoteCacheKey = "stock_quote_cache_v1"
    private let providerConfigKey = "stock_provider_config_v1"
    private let sortFieldKey = "stock_sort_field_v1"
    private let sortOrderKey = "stock_sort_order_v1"
    private let klineCacheKey = "stock_kline_cache_v1"

    var sortedSnapshots: [StockSnapshot] {
        snapshots.sorted { lhs, rhs in
            switch sortField {
            case .symbol:
                return sortOrder == .asc ? lhs.symbol < rhs.symbol : lhs.symbol > rhs.symbol
            case .todayProfit:
                return compare(lhs.todayProfit, rhs.todayProfit)
            case .holdingProfit:
                return compare(lhs.holdingProfit, rhs.holdingProfit)
            case .marketValue:
                return compare(lhs.marketValue, rhs.marketValue)
            }
        }
    }

    func loadInitialData() {
        loadPositions()
        loadProviderConfig()
        loadQuoteCache()
        loadSortState()
        loadKlineCache()
        rebuildSnapshotsFromCache()
    }

    func refreshAll() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if positions.isEmpty {
            snapshots = []
            summary = StockPortfolioSummary()
            lastRefreshMessage = ""
            return
        }

        let provider = makeProvider()
        var fetched: [(StockPosition, Result<StockQuote, Error>)] = []
        await withTaskGroup(of: (StockPosition, Result<StockQuote, Error>).self) { group in
            for position in positions {
                group.addTask {
                    do {
                        let quote = try await self.withRetry {
                            try await provider.fetchQuote(symbol: position.symbol)
                        }
                        return (position, .success(quote))
                    } catch {
                        return (position, .failure(error))
                    }
                }
            }
            for await result in group {
                fetched.append(result)
            }
        }

        let oldByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        var builtByID: [String: StockSnapshot] = [:]
        var failures = 0

        for (position, result) in fetched {
            switch result {
            case .success(let quote):
                quoteCache[position.symbol] = quote
                builtByID[position.id] = buildSnapshot(position: position, quote: quote, isStale: false, errorMessage: nil)
            case .failure(let error):
                failures += 1
                let message = message(for: error)
                if let cached = quoteCache[position.symbol] {
                    builtByID[position.id] = buildSnapshot(position: position, quote: cached, isStale: true, errorMessage: message)
                } else if var old = oldByID[position.id] {
                    old = StockSnapshot(
                        id: old.id,
                        symbol: old.symbol,
                        name: old.name,
                        averageCost: old.averageCost,
                        shares: old.shares,
                        regularPrice: old.regularPrice,
                        previousClose: old.previousClose,
                        marketState: old.marketState,
                        providerName: old.providerName,
                        updatedAt: old.updatedAt,
                        fetchedAt: old.fetchedAt,
                        todayChange: old.todayChange,
                        todayChangePercent: old.todayChangePercent,
                        todayProfit: old.todayProfit,
                        marketValue: old.marketValue,
                        totalCost: old.totalCost,
                        holdingProfit: old.holdingProfit,
                        holdingProfitPercent: old.holdingProfitPercent,
                        extendedPrice: old.extendedPrice,
                        extendedChange: old.extendedChange,
                        extendedChangePercent: old.extendedChangePercent,
                        extendedMarketValue: old.extendedMarketValue,
                        extendedHoldingProfit: old.extendedHoldingProfit,
                        extendedUpdatedAt: old.extendedUpdatedAt,
                        isStale: true,
                        errorMessage: message
                    )
                    builtByID[position.id] = old
                } else {
                    builtByID[position.id] = emptySnapshot(position: position, message: message)
                }
            }
        }

        snapshots = positions.compactMap { builtByID[$0.id] }
        rebuildSummary()
        persistQuoteCache()
        if failures == 0 {
            lastRefreshMessage = "行情已更新"
        } else if failures == positions.count {
            lastRefreshMessage = "行情刷新失败，显示上次数据"
        } else {
            lastRefreshMessage = "\(failures) 只股票刷新失败，已保留旧数据"
        }
    }

    func addOrUpdatePosition(editingID: String?, symbol: String, averageCost: Double, shares: Double, displayName: String? = nil) -> Bool {
        let normalized = StockPosition.normalizeSymbol(symbol)
        guard StockPosition.isValidSymbol(normalized), averageCost > 0, shares > 0 else { return false }

        if let duplicateIdx = positions.firstIndex(where: { $0.symbol == normalized && $0.id != editingID }) {
            let editingOldSymbol = editingID.flatMap { id in positions.first(where: { $0.id == id })?.symbol }
            positions[duplicateIdx].averageCost = averageCost
            positions[duplicateIdx].shares = shares
            if let displayName {
                positions[duplicateIdx].displayName = displayName
            }
            if let editingID {
                positions.removeAll { $0.id == editingID }
            }
            if let editingOldSymbol, editingOldSymbol != normalized {
                quoteCache.removeValue(forKey: editingOldSymbol)
            }
            lastRefreshMessage = "重复股票已按最新持仓覆盖"
        } else if let editingID, let idx = positions.firstIndex(where: { $0.id == editingID }) {
            let oldSymbol = positions[idx].symbol
            positions[idx].symbol = normalized
            positions[idx].averageCost = averageCost
            positions[idx].shares = shares
            if let displayName {
                positions[idx].displayName = displayName
            }
            if oldSymbol != normalized {
                quoteCache.removeValue(forKey: oldSymbol)
                positions[idx].displayName = displayName ?? ""
            }
        } else {
            positions.append(StockPosition(symbol: normalized, averageCost: averageCost, shares: shares, displayName: displayName ?? ""))
        }
        persistPositions()
        rebuildSnapshotsFromCache()
        return true
    }

    func deletePosition(_ id: String) {
        if let position = positions.first(where: { $0.id == id }) {
            quoteCache.removeValue(forKey: position.symbol)
        }
        positions.removeAll { $0.id == id }
        persistPositions()
        persistQuoteCache()
        rebuildSnapshotsFromCache()
    }

    func validateSymbol(_ symbol: String) async -> Bool {
        StockPosition.isValidSymbol(symbol)
    }

    func searchSymbols(query: String) async -> [StockSearchResult] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        do {
            return try await withRetry {
                try await makeProvider().searchSymbols(query: query)
            }
        } catch {
            lastRefreshMessage = message(for: error)
            return []
        }
    }

    /// 获取 K 线数据，结果存入 klineCache
    func fetchKLine(symbol: String, count: Int = 120) async -> StockKLineData? {
        if let cached = cachedKLine(symbol: symbol, count: count) {
            return cached
        }
        let key = klineCacheKey(for: symbol, count: count)
        do {
            let data = try await withRetry {
                try await makeProvider().fetchKLine(symbol: symbol, count: count)
            }
            klineCache[key] = data
            persistKlineCache()
            return data
        } catch {
            return cachedKLine(symbol: symbol, count: count)
        }
    }

    /// 强制刷新 K 线数据（忽略缓存）
    func refreshKLine(symbol: String, count: Int = 120) async -> StockKLineData? {
        let key = klineCacheKey(for: symbol, count: count)
        do {
            let data = try await makeProvider().fetchKLine(symbol: symbol, count: count)
            klineCache[key] = data
            persistKlineCache()
            return data
        } catch {
            return klineCache[key]
        }
    }

    private func klineCacheKey(for symbol: String, count: Int) -> String {
        "\(StockPosition.normalizeSymbol(symbol))_\(count)"
    }

    func hasCachedKLine(symbol: String, count: Int) -> Bool {
        cachedKLine(symbol: symbol, count: count) != nil
    }

    private func cachedKLine(symbol: String, count: Int) -> StockKLineData? {
        let normalized = StockPosition.normalizeSymbol(symbol)
        let key = klineCacheKey(for: normalized, count: count)
        if let exact = klineCache[key], !exact.items.isEmpty {
            return exact
        }
        let prefix = "\(normalized)_"
        let candidates = klineCache.compactMap { key, data -> (Int, StockKLineData)? in
            guard key.hasPrefix(prefix),
                  let cachedCount = Int(key.dropFirst(prefix.count)),
                  cachedCount >= count,
                  data.items.count >= count else { return nil }
            return (cachedCount, data)
        }
        guard let best = candidates.sorted(by: { $0.0 < $1.0 }).first else { return nil }
        let sortedItems = best.1.items.sorted { $0.date < $1.date }
        let derived = StockKLineData(
            symbol: normalized,
            items: Array(sortedItems.suffix(count)),
            fetchedAt: best.1.fetchedAt
        )
        klineCache[key] = derived
        persistKlineCache()
        return derived
    }

    private func withRetry<T>(_ attempts: Int = 2, operation: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 350_000_000)
                }
            }
        }
        throw lastError ?? StockQuoteError.network
    }

    func toggleSort(_ field: StockSortField) {
        if sortField != field {
            sortField = field
            sortOrder = .desc
        } else {
            sortOrder = sortOrder == .desc ? .asc : .desc
        }
        persistSortState()
    }

    func saveProviderConfig(provider: String, apiKey: String, endpoint: String = "") {
        providerConfig.provider = provider
        providerConfig.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        providerConfig.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        persistProviderConfig()
        lastRefreshMessage = "行情配置已保存"
    }

    func testProviderConfig(provider: String, apiKey: String, endpoint: String = "") async -> String {
        let testProvider: StockQuoteProviding
        switch normalizedProvider(provider) {
        case "mock":
            testProvider = MockStockQuoteProvider()
        case "alphavantage":
            testProvider = AlphaVantageStockQuoteProvider(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        case "thsbridge":
            testProvider = THSBridgeStockQuoteProvider(
                baseURL: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                accessToken: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        default:
            testProvider = FinnhubStockQuoteProvider(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        do {
            _ = try await testProvider.fetchQuote(symbol: positions.first?.symbol ?? "NVDA")
            return "测试成功"
        } catch {
            return message(for: error)
        }
    }

    private func compare(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case let (l?, r?):
            return sortOrder == .asc ? l < r : l > r
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return false
        }
    }

    private func makeProvider() -> StockQuoteProviding {
        switch normalizedProvider(providerConfig.provider) {
        case "mock":
            return MockStockQuoteProvider()
        case "alphavantage":
            return AlphaVantageStockQuoteProvider(apiKey: providerConfig.apiKey)
        case "thsbridge":
            return THSBridgeStockQuoteProvider(baseURL: providerConfig.endpoint, accessToken: providerConfig.apiKey)
        default:
            return FinnhubStockQuoteProvider(apiKey: providerConfig.apiKey)
        }
    }

    private func buildSnapshot(position: StockPosition, quote: StockQuote, isStale: Bool, errorMessage: String?) -> StockSnapshot {
        let totalCost = position.averageCost * position.shares
        let todayChange = quote.regularPrice != nil && quote.previousClose != nil ? quote.regularPrice! - quote.previousClose! : nil
        let todayChangePercent = todayChange != nil && quote.previousClose != nil && quote.previousClose! > 0 ? todayChange! / quote.previousClose! * 100 : nil
        let todayProfit = todayChange.map { $0 * position.shares }
        let marketValue = quote.regularPrice.map { $0 * position.shares }
        let holdingProfit = quote.regularPrice.map { ($0 - position.averageCost) * position.shares }
        let holdingProfitPercent = quote.regularPrice.map { ($0 - position.averageCost) / position.averageCost * 100 }
        let extendedMarketValue = quote.extendedPrice.map { $0 * position.shares }
        let extendedHoldingProfit = quote.extendedPrice.map { ($0 - position.averageCost) * position.shares }

        return StockSnapshot(
            id: position.id,
            symbol: position.symbol,
            name: quote.name?.isEmpty == false ? quote.name! : position.displayName.ifEmpty(fallback: position.symbol),
            averageCost: position.averageCost,
            shares: position.shares,
            regularPrice: quote.regularPrice,
            previousClose: quote.previousClose,
            marketState: quote.marketState,
            providerName: quote.providerName,
            updatedAt: quote.regularTimestamp ?? quote.fetchedAt,
            fetchedAt: quote.fetchedAt,
            todayChange: todayChange,
            todayChangePercent: todayChangePercent,
            todayProfit: todayProfit,
            marketValue: marketValue,
            totalCost: totalCost,
            holdingProfit: holdingProfit,
            holdingProfitPercent: holdingProfitPercent,
            extendedPrice: quote.extendedPrice,
            extendedChange: quote.extendedChange,
            extendedChangePercent: quote.extendedChangePercent,
            extendedMarketValue: extendedMarketValue,
            extendedHoldingProfit: extendedHoldingProfit,
            extendedUpdatedAt: quote.extendedTimestamp,
            isStale: isStale,
            errorMessage: errorMessage
        )
    }

    private func emptySnapshot(position: StockPosition, message: String) -> StockSnapshot {
        StockSnapshot(
            id: position.id,
            symbol: position.symbol,
            name: position.displayName.ifEmpty(fallback: position.symbol),
            averageCost: position.averageCost,
            shares: position.shares,
            regularPrice: nil,
            previousClose: nil,
            marketState: USMarketHours.marketState(),
            providerName: providerConfig.provider.capitalized,
            updatedAt: nil,
            fetchedAt: Date(),
            todayChange: nil,
            todayChangePercent: nil,
            todayProfit: nil,
            marketValue: nil,
            totalCost: position.averageCost * position.shares,
            holdingProfit: nil,
            holdingProfitPercent: nil,
            extendedPrice: nil,
            extendedChange: nil,
            extendedChangePercent: nil,
            extendedMarketValue: nil,
            extendedHoldingProfit: nil,
            extendedUpdatedAt: nil,
            isStale: true,
            errorMessage: message
        )
    }

    private func rebuildSnapshotsFromCache() {
        snapshots = positions.map { position in
            if let quote = quoteCache[position.symbol] {
                return buildSnapshot(position: position, quote: quote, isStale: true, errorMessage: nil)
            }
            let provider = normalizedProvider(providerConfig.provider)
            let isReady = provider == "mock" || providerConfig.hasRequiredCredential
            return emptySnapshot(position: position, message: isReady ? "等待刷新" : "未配置行情数据源")
        }
        rebuildSummary()
    }

    private func rebuildSummary() {
        var next = StockPortfolioSummary()
        next.marketState = USMarketHours.marketState()
        next.providerName = providerConfig.provider.capitalized
        next.errorMessage = snapshots.contains(where: { $0.errorMessage != nil }) ? lastRefreshMessage : nil
        for snap in snapshots {
            next.totalCost += snap.totalCost
            next.totalMarketValue += snap.marketValue ?? snap.totalCost
            next.totalTodayProfit += snap.todayProfit ?? 0
            next.totalHoldingProfit += snap.holdingProfit ?? 0
            if let previousClose = snap.previousClose {
                next.totalPreviousCloseValue += previousClose * snap.shares
            }
            if let updatedAt = snap.updatedAt, next.latestUpdatedAt == nil || updatedAt > next.latestUpdatedAt! {
                next.latestUpdatedAt = updatedAt
            }
        }
        summary = next
    }

    private func message(for error: Error) -> String {
        guard let quoteError = error as? StockQuoteError else { return "网络异常，显示上次数据" }
        switch quoteError {
        case .missingAPIKey: return "未配置行情 API Key"
        case .invalidSymbol: return "股票代码无效"
        case .rateLimited: return "行情请求过于频繁或当前数据源额度受限"
        case .network: return "网络异常，显示上次数据"
        case .invalidResponse, .invalidPayload: return "行情暂不可用"
        case .unsupported: return "暂不支持该行情源"
        }
    }

    private func normalizedProvider(_ provider: String) -> String {
        switch provider.lowercased() {
        case "alpha_vantage", "alpha-vantage", "alpha vantage":
            return "alphavantage"
        case "ths_bridge", "ths-bridge", "ths bridge", "ths":
            return "thsbridge"
        default:
            return provider.lowercased()
        }
    }

    private func loadPositions() {
        guard let data = UserDefaults.standard.data(forKey: positionsKey),
              let loaded = try? JSONDecoder().decode([StockPosition].self, from: data) else {
            positions = []
            return
        }
        positions = loaded
    }

    private func persistPositions() {
        guard let data = try? JSONEncoder().encode(positions) else { return }
        UserDefaults.standard.set(data, forKey: positionsKey)
    }

    private func loadProviderConfig() {
        guard let data = UserDefaults.standard.data(forKey: providerConfigKey),
              let loaded = try? JSONDecoder().decode(StockProviderConfig.self, from: data) else {
            providerConfig = StockProviderConfig()
            return
        }
        providerConfig = loaded
    }

    private func persistProviderConfig() {
        guard let data = try? JSONEncoder().encode(providerConfig) else { return }
        UserDefaults.standard.set(data, forKey: providerConfigKey)
    }

    private func loadQuoteCache() {
        guard let data = UserDefaults.standard.data(forKey: quoteCacheKey),
              let loaded = try? JSONDecoder().decode([String: StockQuote].self, from: data) else {
            quoteCache = [:]
            return
        }
        quoteCache = loaded
    }

    private func persistQuoteCache() {
        guard let data = try? JSONEncoder().encode(quoteCache) else { return }
        UserDefaults.standard.set(data, forKey: quoteCacheKey)
    }

    private func loadSortState() {
        if let raw = UserDefaults.standard.string(forKey: sortFieldKey), let loaded = StockSortField(rawValue: raw) {
            sortField = loaded
        }
        if let raw = UserDefaults.standard.string(forKey: sortOrderKey), let loaded = StockSortOrder(rawValue: raw) {
            sortOrder = loaded
        }
    }

    private func persistSortState() {
        UserDefaults.standard.set(sortField.rawValue, forKey: sortFieldKey)
        UserDefaults.standard.set(sortOrder.rawValue, forKey: sortOrderKey)
    }

    private func loadKlineCache() {
        guard let data = UserDefaults.standard.data(forKey: klineCacheKey),
              let loaded = try? JSONDecoder().decode([String: StockKLineData].self, from: data) else {
            klineCache = [:]
            return
        }
        klineCache = loaded
    }

    private func persistKlineCache() {
        guard let data = try? JSONEncoder().encode(klineCache) else { return }
        UserDefaults.standard.set(data, forKey: klineCacheKey)
    }
}

private extension String {
    func ifEmpty(fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

private extension StockProviderConfig {
    var hasRequiredCredential: Bool {
        switch provider.lowercased() {
        case "mock":
            return true
        case "thsbridge", "ths_bridge", "ths-bridge", "ths bridge", "ths":
            return !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
