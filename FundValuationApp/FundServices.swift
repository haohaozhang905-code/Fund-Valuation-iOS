import Foundation

enum FundServiceError: Error {
    case invalidResponse
    case invalidPayload
}

struct FundValuationResponse: Decodable {
    let fundcode: String?
    let name: String?
    let gsz: String?
    let gszzl: String?  // 估算增长率 %，与 gsz/dwjz 同源，优先用于当日涨跌
    let dwjz: String?
    let jzrq: String?
    let gztime: String?
}

// MARK: - THS Bridge API 响应模型（与 Web 端一致）

private struct THSNavTrendResponse: Decodable {
    let name: String?
    let netWorthTrend: [THSNavTrendPoint]?
}
private struct THSNavTrendPoint: Decodable {
    let x: Double
    let y: Double
}
private struct THSNavLatestResponse: Decodable {
    let items: [THSNavLatestItem]?
}
private struct THSNavLatestItem: Decodable {
    let date: String
    let nav: String
}
private struct THSCSI300Response: Decodable {
    let items: [THSCSI300Item]?
}
private struct THSCSI300Item: Decodable {
    let date: String?
    let close: String?
}

// MARK: - 基金数据服务（统一走 ths-bridge，与 Web 端保持一致）

struct FundDataService {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()
    private let thsBase = AppEnvironment.thsBridgeURL

    /// 验证基金代码是否有效（能否从 API 获取到数据）
    func validateFundCode(_ code: String) async -> Bool {
        let normalized = String(code.filter(\.isNumber).suffix(6))
        guard normalized.count == 6 else { return false }
        let valuation = await fetchValuation(fundCode: normalized)
        let navPair = await fetchLatestTwoNav(fundCode: normalized)
        if valuation != nil { return true }
        if navPair?.latest != nil { return true }
        return false
    }

    func fetchValuationAndNav(fundCode: String) async -> (FundValuationResponse?, NavPair?, String?) {
        async let v = fetchValuation(fundCode: fundCode)
        async let navResult = fetchNavWithName(fundCode: fundCode)
        let valuation = await v
        let (navPair, fundName) = await navResult
        return (valuation, navPair, fundName)
    }

    func fetchNavWithName(fundCode: String) async -> (NavPair?, String?) {
        async let ping = fetchNavFromTrend(fundCode: fundCode)
        async let f10 = fetchLatestNav(fundCode: fundCode)
        let (pingPair, fundName) = await ping
        let f10Pair = await f10
        let pair = mergeNavPair(ping: pingPair, f10: f10Pair)
        return (pair, fundName)
    }

    /// ths-bridge nav-trend → 同 Web 端 pingzhongdata 数据源
    private func fetchNavFromTrend(fundCode: String) async -> (NavPair?, String?) {
        let path = "/v1/funds/nav-trend/\(fundCode)"
        do {
            let obj = try await fetchJSON(path: path)
            let data = try JSONSerialization.data(withJSONObject: obj)
            let trend = try JSONDecoder().decode(THSNavTrendResponse.self, from: data)
            let pair = buildNavPair(from: trend.netWorthTrend ?? [])
            return (pair, trend.name)
        } catch {
            return (nil, nil)
        }
    }

    /// ths-bridge nav-latest → 同 Web 端 F10DataApi 数据源
    private func fetchLatestNav(fundCode: String) async -> NavPair? {
        let path = "/v1/funds/nav-latest/\(fundCode)"
        do {
            let obj = try await fetchJSON(path: path)
            let data = try JSONSerialization.data(withJSONObject: obj)
            let latest = try JSONDecoder().decode(THSNavLatestResponse.self, from: data)
            let items = latest.items ?? []
            var points: [NavPoint] = []
            for item in items {
                let date = String(item.date.prefix(10))
                guard let nav = Double(item.nav), nav > 0 else { continue }
                points.append(NavPoint(date: date, value: nav))
            }
            guard !points.isEmpty else { return nil }
            return NavPair(latest: points[0], previous: points.count > 1 ? points[1] : nil)
        } catch {
            return nil
        }
    }

    private func mergeNavPair(ping: NavPair?, f10: NavPair?) -> NavPair? {
        guard let f10, let f10Latest = f10.latest else { return ping }
        guard let ping, let pingLatest = ping.latest else { return f10 }
        if DateHelper.compareYMD(f10Latest.date, pingLatest.date) == .orderedDescending {
            return f10
        }
        return ping
    }

    /// 基金实时估值（ths-bridge → 天天基金）
    func fetchValuation(fundCode: String) async -> FundValuationResponse? {
        let path = "/v1/funds/valuation/\(fundCode)"
        do {
            let obj = try await fetchJSON(path: path)
            let data = try JSONSerialization.data(withJSONObject: obj)
            return try JSONDecoder().decode(FundValuationResponse.self, from: data)
        } catch {
            return nil
        }
    }

    func fetchLatestTwoNav(fundCode: String) async -> NavPair? {
        let (pair, _) = await fetchNavWithName(fundCode: fundCode)
        return pair
    }

    /// 基金净值走势（ths-bridge → 东方财富 pingzhongdata）
    func fetchNavTrend(fundCode: String) async -> [NavPoint] {
        let path = "/v1/funds/nav-trend/\(fundCode)"
        do {
            let obj = try await fetchJSON(path: path)
            let data = try JSONSerialization.data(withJSONObject: obj)
            let trend = try JSONDecoder().decode(THSNavTrendResponse.self, from: data)
            return (trend.netWorthTrend ?? []).compactMap { point in
                guard point.y > 0 else { return nil }
                let date = DateHelper.ymdString(fromMS: point.x)
                guard !date.isEmpty else { return nil }
                return NavPoint(date: date, value: point.y)
            }
        } catch {
            return []
        }
    }

    /// 沪深300指数近N交易日累计涨跌幅（ths-bridge → 新浪财经）
    func fetchCSI300Trend(tradingDaysLimit: Int) async -> [DailyPerformancePoint] {
        let path = "/v1/index/csi300"
        let queryItems = [URLQueryItem(name: "datalen", value: "\(min(tradingDaysLimit + 10, 800))")]
        do {
            let obj = try await fetchJSON(path: path, queryItems: queryItems)
            let data = try JSONSerialization.data(withJSONObject: obj)
            let csi300 = try JSONDecoder().decode(THSCSI300Response.self, from: data)
            let items = csi300.items ?? []
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            var navPoints: [(date: String, close: Double)] = []
            for item in items {
                guard let day = item.date, !day.isEmpty,
                      let closeStr = item.close,
                      let close = Double(closeStr), close > 0 else { continue }
                let date = String(day.prefix(10))
                if let d = formatter.date(from: date) {
                    let w = Calendar.current.component(.weekday, from: d)
                    if w == 1 || w == 7 { continue }
                }
                navPoints.append((date: date, close: close))
            }
            let slice = Array(navPoints.suffix(tradingDaysLimit))
            guard let firstClose = slice.first?.close, firstClose > 0 else { return [] }
            return slice.map { p in
                let cum = (p.close / firstClose - 1) * 100
                return DailyPerformancePoint(id: "hs300_\(p.date)", date: p.date, cumulativeReturn: cum)
            }
        } catch {
            return []
        }
    }

    /// 仅交易日的累计涨跌幅（ths-bridge → 东方财富 pingzhongdata）
    func fetchDailyPerformanceTrend(fundCode: String, tradingDaysLimit: Int = 63) async -> [DailyPerformancePoint] {
        let path = "/v1/funds/nav-trend/\(fundCode)"
        do {
            let obj = try await fetchJSON(path: path)
            let data = try JSONSerialization.data(withJSONObject: obj)
            let trend = try JSONDecoder().decode(THSNavTrendResponse.self, from: data)
            let netWorth = trend.netWorthTrend ?? []
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            var navPoints: [(date: String, nav: Double)] = []
            for point in netWorth {
                guard point.y > 0 else { continue }
                let date = DateHelper.ymdString(fromMS: point.x)
                guard !date.isEmpty else { continue }
                if let d = formatter.date(from: date) {
                    let w = Calendar.current.component(.weekday, from: d)
                    if w == 1 || w == 7 { continue }
                }
                navPoints.append((date: date, nav: point.y))
            }
            let slice = Array(navPoints.suffix(tradingDaysLimit))
            guard let firstNav = slice.first?.nav, firstNav > 0 else { return [] }
            return slice.map { p in
                let cum = (p.nav / firstNav - 1) * 100
                return DailyPerformancePoint(id: p.date, date: p.date, cumulativeReturn: cum)
            }
        } catch {
            return []
        }
    }

    // MARK: - HTTP 通用方法

    private func fetchJSON(path: String, queryItems: [URLQueryItem] = []) async throws -> [String: Any] {
        guard var comp = URLComponents(string: thsBase) else {
            throw FundServiceError.invalidResponse
        }
        let basePath = comp.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        comp.path = basePath.isEmpty ? path : "/\(basePath)\(path)"
        if !queryItems.isEmpty {
            comp.queryItems = queryItems
        }
        guard let url = comp.url else {
            throw FundServiceError.invalidPayload
        }

        let (data, response) = try await Self.session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FundServiceError.invalidResponse
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FundServiceError.invalidPayload
        }
        return obj
    }

    // MARK: - 内部工具方法

    private func buildNavPair(from points: [THSNavTrendPoint]) -> NavPair? {
        guard !points.isEmpty else { return nil }
        let latest = points[points.count - 1]
        let previous = points.count > 1 ? points[points.count - 2] : nil
        let latestDate = DateHelper.ymdString(fromMS: latest.x)
        guard !latestDate.isEmpty, latest.y > 0 else { return nil }
        let latestPoint = NavPoint(date: latestDate, value: latest.y)
        let previousPoint: NavPoint? = {
            guard let prev = previous else { return nil }
            let prevDate = DateHelper.ymdString(fromMS: prev.x)
            guard !prevDate.isEmpty, prev.y > 0 else { return nil }
            return NavPoint(date: prevDate, value: prev.y)
        }()
        return NavPair(latest: latestPoint, previous: previousPoint)
    }
}

struct AIService {
    private let session: URLSession = .shared

    func runAnalysisStream(prompt: String, config: AIConfig, onDelta: @escaping (String) -> Void) async throws {
        guard let url = URL(string: normalizedEndpoint(config.endpoint)) else {
            throw FundServiceError.invalidPayload
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        let payload: [String: Any] = [
            "model": config.model,
            "temperature": 0.3,
            "stream": true,
            "messages": [
                ["role": "system", "content": "请使用中文输出，保持专业、简洁、可执行。请将重点内容使用**加粗**展示。使用Markdown格式输出，合理使用标题、列表、加粗等格式。"],
                ["role": "user", "content": prompt]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FundServiceError.invalidResponse
        }

        var buffer = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String
            else { continue }
            buffer += content
            onDelta(buffer)
        }
    }

    func normalizedEndpoint(_ endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        }
        if trimmed.hasSuffix("/compatible-mode/v1") {
            return "\(trimmed)/chat/completions"
        }
        if trimmed.hasSuffix("/compatible-mode/v1/") {
            return "\(trimmed)chat/completions"
        }
        return trimmed
    }
}

enum DateHelper {
    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        return cal
    }()

    static func nowTradingDay() -> Bool {
        let weekday = calendar.component(.weekday, from: Date())
        return weekday >= 2 && weekday <= 6
    }

    /// 交易中：9:30-11:30 或 13:00-15:00（精确到分钟，用于价格计算策略）
    static func marketOpenNow() -> Bool {
        guard nowTradingDay() else { return false }
        let comps = calendar.dateComponents([.hour, .minute], from: Date())
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return (570..<690).contains(minutes) || (780..<900).contains(minutes)
    }

    /// 交易日且开盘前（9:30 之前）
    static func marketBeforeOpenToday() -> Bool {
        guard nowTradingDay() else { return false }
        let comps = calendar.dateComponents([.hour, .minute], from: Date())
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return minutes < 570
    }

    /// 交易日且收盘后（15:00 之后，或午休 11:30-13:00 按收盘后逻辑）
    static func marketAfterCloseToday() -> Bool {
        guard nowTradingDay() else { return false }
        let comps = calendar.dateComponents([.hour, .minute], from: Date())
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return minutes >= 900 || (690..<780).contains(minutes)
    }

    /// 交易日 9:00-15:00 整小时区间，含午休（与 Web 端 isMarketOpen() 一致，仅用于 Banner 标签显示）
    static func marketSessionOpen() -> Bool {
        guard nowTradingDay() else { return false }
        let h = Calendar.current.component(.hour, from: Date())
        return h >= 9 && h < 15
    }

    static func ymdString(fromMS ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func ymdString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func formatDateDisplay(_ ymd: String) -> String {
        let parts = ymd.split(separator: "-")
        guard parts.count == 3 else { return ymd }
        return "\(parts[1])月\(Int(parts[2]) ?? 0)日"
    }

    static func compareYMD(_ a: String, _ b: String) -> ComparisonResult {
        let aa = String(a.prefix(10))
        let bb = String(b.prefix(10))
        return aa.compare(bb)
    }

    static func parseGZTime(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        if let d = formatter.date(from: text) { return d }
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let d = formatter.date(from: text) { return d }
        return nil
    }

    /// 估值时间展示：仅 HH:mm，不展示年
    static func formatValuationTimeDisplay(_ raw: String) -> String {
        guard let d = parseGZTime(raw) else { return raw }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// 估值时间展示：MM-dd HH:mm（含月日）
    static func formatValuationTimeWithDate(_ raw: String) -> String {
        guard let d = parseGZTime(raw) else { return raw }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    /// 净值日期展示：仅 MM-dd，不展示年
    static func formatDataDateDisplay(_ raw: String) -> String {
        let s = String(raw.prefix(10))
        guard s.count >= 10 else { return raw }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: s) else { return raw }
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f.string(from: date)
    }

    static func dateBy(dayYMD: String, hm: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(dayYMD) \(hm)")
    }
}

enum NumberFormat {
    /// 金额/数量：超过 1000 使用千分位（如 1,234.56）
    static func fixed(_ value: Double?, digits: Int = 2) -> String {
        guard let value else { return "--" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        formatter.usesGroupingSeparator = abs(value) >= 1000
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }

    static func signed(_ value: Double?, digits: Int = 2, prefixYuan: Bool = false) -> String {
        guard let value else { return "--" }
        let symbol = value >= 0 ? "+" : ""
        let yuan = prefixYuan ? "¥" : ""
        return "\(symbol)\(yuan)\(fixed(value, digits: digits))"
    }

    /// 百分比：统一保留 2 位小数
    static func signedPercent(_ value: Double?) -> String {
        guard let value else { return "--" }
        let symbol = value >= 0 ? "+" : ""
        return "\(symbol)\(fixed(value, digits: 2))%"
    }

    static func usd(_ value: Double?, digits: Int = 2, signed: Bool = false) -> String {
        guard let value else { return "--" }
        let symbol = signed && value >= 0 ? "+" : ""
        return "\(symbol)$\(fixed(value, digits: digits))"
    }

    static func signedUSD(_ value: Double?, digits: Int = 2) -> String {
        usd(value, digits: digits, signed: true)
    }

    static func quantity(_ value: Double?, maxDigits: Int = 4) -> String {
        guard let value else { return "--" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maxDigits
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        formatter.usesGroupingSeparator = abs(value) >= 1000
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
