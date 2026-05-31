import Foundation

enum StockQuoteError: Error, Equatable {
    case missingAPIKey
    case invalidSymbol
    case rateLimited
    case invalidResponse
    case invalidPayload
    case network
    case unsupported
}

extension StockQuoteProviding {
    /// Default: most providers don't support kline, throw unsupported
    func fetchKLine(symbol: String, count: Int = 120) async throws -> StockKLineData {
        throw StockQuoteError.unsupported
    }
}

protocol StockQuoteProviding {
    var providerName: String { get }
    func fetchQuote(symbol: String) async throws -> StockQuote
    func searchSymbols(query: String) async throws -> [StockSearchResult]
    func validateSymbol(_ symbol: String) async -> Bool
    func fetchKLine(symbol: String, count: Int) async throws -> StockKLineData
}

struct THSBridgeStockQuoteProvider: StockQuoteProviding {
    let baseURL: String
    let accessToken: String
    let providerName = "同花顺"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config)
    }()

    func fetchQuote(symbol: String) async throws -> StockQuote {
        let normalized = StockPosition.normalizeSymbol(symbol)
        print("[THSBridge] fetchQuote start: symbol=\(normalized), baseURL=\(baseURL)")
        guard StockPosition.isValidSymbol(normalized) else {
            print("[THSBridge] fetchQuote FAIL: invalid symbol")
            throw StockQuoteError.invalidSymbol
        }
        let obj = try await fetchJSON(path: "/v1/stocks/quote", queryItems: [
            URLQueryItem(name: "symbol", value: normalized),
            URLQueryItem(name: "market", value: "US")
        ])
        print("[THSBridge] fetchQuote response keys: \(obj.keys.joined(separator: ", "))")
        print("[THSBridge] fetchQuote regularPrice=\(obj["regularPrice"] ?? "nil"), previousClose=\(obj["previousClose"] ?? "nil")")

        guard let price = parseDouble(obj["regularPrice"]), price > 0 else {
            print("[THSBridge] fetchQuote FAIL: invalid regularPrice=\(obj["regularPrice"] ?? "nil")")
            throw StockQuoteError.invalidPayload
        }

        let now = Date()
        let marketStateRaw = obj["marketState"] as? String ?? ""
        let providerLabel = (obj["providerLabel"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return StockQuote(
            symbol: normalized,
            name: (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            regularPrice: price,
            previousClose: parseDouble(obj["previousClose"]),
            regularTimestamp: parseDate(obj["regularTimestamp"]),
            extendedPrice: parseDouble(obj["extendedPrice"]),
            extendedTimestamp: parseDate(obj["extendedTimestamp"]),
            extendedChange: parseDouble(obj["extendedChange"]),
            extendedChangePercent: parseDouble(obj["extendedChangePercent"]),
            marketState: parseMarketState(marketStateRaw, fallback: USMarketHours.marketState(now: now)),
            providerName: providerLabel?.isEmpty == false ? providerLabel! : providerName,
            fetchedAt: parseDate(obj["fetchedAt"]) ?? now
        )
    }

    func validateSymbol(_ symbol: String) async -> Bool {
        StockPosition.isValidSymbol(symbol)
    }

    func searchSymbols(query: String) async throws -> [StockSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let obj = try await fetchJSON(path: "/v1/stocks/search", queryItems: [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "market", value: "US")
        ])
        guard let items = obj["items"] as? [[String: Any]] else {
            throw StockQuoteError.invalidPayload
        }

        return items.compactMap { item in
            guard let symbol = item["symbol"] as? String, StockPosition.isValidSymbol(symbol) else { return nil }
            // 只保留美股相关品种（GP=普通股, GP-ETF=ETF, 以及 isEquity=true 的）
            let isEquity = item["isEquity"] as? Bool ?? false
            let type = (item["type"] as? String ?? "").uppercased()
            guard isEquity || type == "GP" || type.hasPrefix("GP-") else { return nil }
            let name = item["name"] as? String ?? symbol
            let displaySymbol = item["displaySymbol"] as? String ?? symbol
            return StockSearchResult(
                symbol: symbol,
                description: name,
                displaySymbol: displaySymbol,
                type: type.hasPrefix("GP-") ? "ETF" : "Common Stock"
            )
        }
        .prefix(8)
        .map { $0 }
    }

    func fetchKLine(symbol: String, count: Int = 120) async throws -> StockKLineData {
        let normalized = StockPosition.normalizeSymbol(symbol)
        guard StockPosition.isValidSymbol(normalized) else { throw StockQuoteError.invalidSymbol }
        let obj = try await fetchJSON(path: "/v1/stocks/kline", queryItems: [
            URLQueryItem(name: "symbol", value: normalized),
            URLQueryItem(name: "count", value: "\(count)")
        ])
        guard let items = obj["items"] as? [[String: Any]] else {
            throw StockQuoteError.invalidPayload
        }
        let points: [StockKLinePoint] = items.compactMap { item in
            guard let date = item["date"] as? String,
                  let open = parseDouble(item["open"]),
                  let high = parseDouble(item["high"]),
                  let low = parseDouble(item["low"]),
                  let close = parseDouble(item["close"]),
                  let volume = item["volume"] as? Int,
                  let cp = parseDouble(item["changePercent"]) else { return nil }
            return StockKLinePoint(
                date: date,
                open: open,
                high: high,
                low: low,
                close: close,
                volume: volume,
                changePercent: cp
            )
        }
        guard !points.isEmpty else { throw StockQuoteError.invalidPayload }
        return StockKLineData(
            symbol: normalized,
            items: points,
            fetchedAt: Date()
        )
    }

    private func fetchJSON(path: String, queryItems: [URLQueryItem]) async throws -> [String: Any] {
        let base = normalizedBaseURL()
        print("[THSBridge] fetchJSON: base=\(base), path=\(path)")
        guard !base.isEmpty, var comp = URLComponents(string: base) else {
            print("[THSBridge] fetchJSON FAIL: invalid baseURL=\(base)")
            throw StockQuoteError.missingAPIKey
        }
        let basePath = comp.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        comp.path = basePath.isEmpty ? path : "/\(basePath)\(path)"
        comp.queryItems = queryItems
        guard let url = comp.url else {
            print("[THSBridge] fetchJSON FAIL: cannot construct URL from components")
            throw StockQuoteError.invalidPayload
        }
        print("[THSBridge] fetchJSON: constructed URL=\(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            print("[THSBridge] fetchJSON: added Bearer auth header")
        }

        // 重试：如果遇到 cancelled 或 network 错误，重试一次
        for attempt in 1...2 {
            do {
                let (data, response) = try await Self.session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    print("[THSBridge] fetchJSON FAIL: response is not HTTPURLResponse")
                    throw StockQuoteError.invalidResponse
                }
                print("[THSBridge] fetchJSON: HTTP \(http.statusCode), data=\(data.count) bytes")
                if http.statusCode == 401 || http.statusCode == 403 {
                    print("[THSBridge] fetchJSON FAIL: HTTP \(http.statusCode) - auth error")
                    throw StockQuoteError.missingAPIKey
                }
                if http.statusCode == 429 {
                    print("[THSBridge] fetchJSON FAIL: HTTP 429 - rate limited")
                    throw StockQuoteError.rateLimited
                }
                guard (200..<300).contains(http.statusCode) else {
                    print("[THSBridge] fetchJSON FAIL: HTTP \(http.statusCode) - unexpected status")
                    if let body = String(data: data, encoding: .utf8) {
                        print("[THSBridge] fetchJSON response body: \(body.prefix(500))")
                    }
                    throw StockQuoteError.invalidResponse
                }
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    print("[THSBridge] fetchJSON FAIL: cannot parse JSON response")
                    if let body = String(data: data, encoding: .utf8) {
                        print("[THSBridge] fetchJSON raw body: \(body.prefix(500))")
                    }
                    throw StockQuoteError.invalidPayload
                }
                print("[THSBridge] fetchJSON SUCCESS: parsed \(obj.count) keys")
                return obj
            } catch let error as StockQuoteError {
                print("[THSBridge] fetchJSON FAIL (attempt \(attempt)): StockQuoteError=\(error)")
                throw error  // 业务错误不重试
            } catch {
                let nsError = error as NSError
                print("[THSBridge] fetchJSON FAIL (attempt \(attempt)): system error=\(error.localizedDescription) (code=\(nsError.code), domain=\(nsError.domain))")
                if attempt == 2 || nsError.code != NSURLErrorCancelled {
                    throw StockQuoteError.network
                }
                // cancelled 错误：等待 0.5 秒后重试
                print("[THSBridge] fetchJSON: retrying after cancelled error...")
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw StockQuoteError.network
    }

    private func normalizedBaseURL() -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // 统一转小写做前缀检查，保留原始大小写用于返回值
        let lower = trimmed.lowercased()

        // 修复常见拼写错误：htttp:// → http://, htttps:// → https://
        var fixed = trimmed
        if lower.hasPrefix("htttp") && !lower.hasPrefix("http") {
            let schemeLen = lower.hasPrefix("https") ? 5 : 4
            let replacement = lower.hasPrefix("https") ? "https" : "http"
            fixed = replacement + String(trimmed.dropFirst(schemeLen + 1))
        }

        // 正确识别 http(s):// 前缀（大小写不敏感）
        let lowerFixed = fixed.lowercased()
        if lowerFixed.hasPrefix("https://") {
            return "https://" + fixed.dropFirst(8)
        }
        if lowerFixed.hasPrefix("http://") {
            return "http://" + fixed.dropFirst(7)
        }

        return "http://\(fixed)"
    }

    private func parseDouble(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String {
            return Double(string.replacingOccurrences(of: "%", with: ""))
        }
        return nil
    }

    private func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        if let date = Self.isoFormatter.date(from: string) {
            return date
        }
        return Self.fallbackFormatter.date(from: string)
    }

    private func parseMarketState(_ raw: String, fallback: StockMarketState) -> StockMarketState {
        switch raw.lowercased() {
        case "premarket", "pre_market", "pre":
            return .premarket
        case "regular", "open", "trading":
            return .regular
        case "afterhours", "after_hours", "post":
            return .afterhours
        case "closed", "close":
            return .closed
        default:
            return fallback
        }
    }

    private static let isoFormatter = ISO8601DateFormatter()

    private static let fallbackFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = USMarketHours.easternTimeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

enum USMarketHours {
    static let easternTimeZone = TimeZone(identifier: "America/New_York")!

    static func marketState(now: Date = Date()) -> StockMarketState {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = easternTimeZone
        let weekday = calendar.component(.weekday, from: now)
        guard weekday >= 2 && weekday <= 6 else { return .closed }
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        switch minutes {
        case 240..<570:
            return .premarket
        case 570..<960:
            return .regular
        case 960..<1200:
            return .afterhours
        default:
            return .closed
        }
    }

    static func combinedDisplayTime(_ date: Date?) -> String {
        guard let date else { return "--" }
        let et = format(date, timeZone: easternTimeZone, pattern: "HH:mm:ss")
        let cst = format(date, timeZone: TimeZone(identifier: "Asia/Shanghai") ?? .current, pattern: "HH:mm:ss")
        return "\(et) 美东 / \(cst) 北京"
    }

    static func shortDisplayTime(_ date: Date?) -> String {
        guard let date else { return "--" }
        return format(date, timeZone: easternTimeZone, pattern: "HH:mm")
    }

    static func detailDisplayTime(_ date: Date?) -> String {
        guard let date else { return "--" }
        return "\(format(date, timeZone: easternTimeZone, pattern: "HH:mm:ss")) 美东"
    }

    private static func format(_ date: Date, timeZone: TimeZone, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
