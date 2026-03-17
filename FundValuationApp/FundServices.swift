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

struct FundDataService {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()
    private let valuationBase = "https://fundgz.1234567.com.cn/js/"
    private let pingBase = "https://fund.eastmoney.com/pingzhongdata/"
    private let f10Base = "https://fundf10.eastmoney.com/F10DataApi.aspx"
    private let hisBase = "https://push2his.eastmoney.com/api/qt/stock/kline/get"
    private let sinaIndexBase = "https://money.finance.sina.com.cn/quotes_service/api/json_v2.php/CN_MarketData.getKLineData"

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
        async let ping = fetchNavFromPingzhong(fundCode: fundCode)
        async let f10 = fetchLatestNavFromF10(fundCode: fundCode)
        let (pingPair, fundName) = await ping
        let f10Pair = await f10
        let pair = mergeNavPair(ping: pingPair, f10: f10Pair)
        return (pair, fundName)
    }

    /// pingzhongdata 的 Data_netWorthTrend，T+2/QDII 基金可能滞后
    private func fetchNavFromPingzhong(fundCode: String) async -> (NavPair?, String?) {
        let urlString = "\(pingBase)\(fundCode).js?v=\(Int(Date().timeIntervalSince1970))"
        guard let url = URL(string: urlString) else { return (nil, nil) }
        do {
            let (data, _) = try await Self.session.data(from: url)
            guard let text = String(data: data, encoding: .utf8) else { return (nil, nil) }
            let fundName = extractJSString(text: text, variable: "fS_name")
            guard let rawArray = extractJSVariable(text: text, variable: "Data_netWorthTrend") else { return (nil, fundName) }
            guard let arr = try parseNetWorthTrend(rawArray) else { return (nil, fundName) }
            return (buildNavPair(points: arr), fundName)
        } catch {
            return (nil, nil)
        }
    }

    /// F10DataApi 历史净值，更新更及时，T+2/QDII 基金适用
    private func fetchLatestNavFromF10(fundCode: String) async -> NavPair? {
        let urlString = "\(f10Base)?type=lsjz&code=\(fundCode)&page=1&per=5"
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await Self.session.data(from: url)
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return parseF10LsJzContent(text)
        } catch {
            return nil
        }
    }

    private func parseF10LsJzContent(_ text: String) -> NavPair? {
        guard let range = text.range(of: "content:\"", options: .literal),
              let endRange = text.range(of: "\",records:", options: .literal) else { return nil }
        let content = String(text[range.upperBound..<endRange.lowerBound])
        let separators = CharacterSet(charactersIn: "\n\r")
        let rows = content.components(separatedBy: separators).filter { row in
            row.contains("|") && !row.contains("净值日期") && !row.contains("---")
        }
        var points: [NavPoint] = []
        for row in rows {
            let cols = row.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 3 else { continue }
            let dateStr = cols[1]
            guard dateStr.count >= 10, dateStr.contains("-") else { continue }
            let date = String(dateStr.prefix(10))
            guard let nav = Double(cols[2]), nav > 0 else { continue }
            points.append(NavPoint(date: date, value: nav))
        }
        guard !points.isEmpty else { return nil }
        let latest = points[0]
        let previous = points.count > 1 ? points[1] : nil
        return NavPair(latest: latest, previous: previous)
    }

    private func mergeNavPair(ping: NavPair?, f10: NavPair?) -> NavPair? {
        guard let f10, let f10Latest = f10.latest else { return ping }
        guard let ping, let pingLatest = ping.latest else { return f10 }
        if DateHelper.compareYMD(f10Latest.date, pingLatest.date) == .orderedDescending {
            return f10
        }
        return ping
    }

    func fetchValuation(fundCode: String) async -> FundValuationResponse? {
        let urlString = "\(valuationBase)\(fundCode).js?t=\(Int(Date().timeIntervalSince1970))"
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await Self.session.data(from: url)
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            guard let json = extractJSONP(from: text, callbackName: "jsonpgz") else { return nil }
            return try JSONDecoder().decode(FundValuationResponse.self, from: Data(json.utf8))
        } catch {
            return nil
        }
    }

    func fetchLatestTwoNav(fundCode: String) async -> NavPair? {
        let (pair, _) = await fetchNavWithName(fundCode: fundCode)
        return pair
    }

    private func extractJSString(text: String, variable: String) -> String? {
        let patterns = [
            "var\\s+\(variable)\\s*=\\s*\"([^\"]*)\"",
            "var\\s+\(variable)\\s*=\\s*'([^']*)'"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges >= 2,
               let r = Range(match.range(at: 1), in: text) {
                return String(text[r]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    func fetchNavTrend(fundCode: String) async -> [NavPoint] {
        let urlString = "\(pingBase)\(fundCode).js?v=\(Int(Date().timeIntervalSince1970))"
        guard let url = URL(string: urlString) else { return [] }
        do {
            let (data, _) = try await Self.session.data(from: url)
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            guard let rawArray = extractJSVariable(text: text, variable: "Data_netWorthTrend") else { return [] }
            guard let arr = try parseNetWorthTrend(rawArray) else { return [] }
            let points: [NavPoint] = arr.compactMap { row in
                guard let y = row["y"] as? Double else { return nil }
                guard let x = row["x"] as? Double else { return nil }
                let date = DateHelper.ymdString(fromMS: x)
                guard !date.isEmpty, y > 0 else { return nil }
                return NavPoint(date: date, value: y)
            }
            return points
        } catch {
            return []
        }
    }

    /// 沪深300指数近N交易日累计涨跌幅（新浪财经 API，sh000300）
    func fetchCSI300Trend(tradingDaysLimit: Int) async -> [DailyPerformancePoint] {
        var comp = URLComponents(string: sinaIndexBase)!
        comp.queryItems = [
            URLQueryItem(name: "symbol", value: "sh000300"),
            URLQueryItem(name: "scale", value: "240"),
            URLQueryItem(name: "ma", value: "no"),
            URLQueryItem(name: "datalen", value: "\(min(tradingDaysLimit + 10, 1023))")
        ]
        guard let url = comp.url else { return [] }
        do {
            let (data, _) = try await Self.session.data(from: url)
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            var navPoints: [(date: String, close: Double)] = []
            for item in arr {
                guard let day = item["day"] as? String, !day.isEmpty,
                      let closeStr = item["close"] as? String,
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

    /// 仅交易日的累计涨跌幅，一次请求获取（过滤周末，横轴仅含交易日）
    func fetchDailyPerformanceTrend(fundCode: String, tradingDaysLimit: Int = 63) async -> [DailyPerformancePoint] {
        let urlString = "\(pingBase)\(fundCode).js?v=\(Int(Date().timeIntervalSince1970))"
        guard let url = URL(string: urlString) else { return [] }
        do {
            let (data, _) = try await Self.session.data(from: url)
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            guard let rawArray = extractJSVariable(text: text, variable: "Data_netWorthTrend") else { return [] }
            guard let arr = try parseNetWorthTrend(rawArray) else { return [] }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            var navPoints: [(date: String, nav: Double)] = []
            for row in arr {
                guard let x = row["x"] as? Double, let y = row["y"] as? Double, y > 0 else { continue }
                let date = DateHelper.ymdString(fromMS: x)
                guard !date.isEmpty else { continue }
                if let d = formatter.date(from: date) {
                    let w = Calendar.current.component(.weekday, from: d)
                    if w == 1 || w == 7 { continue }
                }
                navPoints.append((date: date, nav: y))
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

    private func extractJSONP(from text: String, callbackName: String) -> String? {
        let pattern = "\(callbackName)\\((.*)\\);?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let bodyRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractJSVariable(text: String, variable: String) -> String? {
        let pattern = "var\\s+\(variable)\\s*=\\s*(\\[.*?\\]);"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let bodyRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[bodyRange])
    }

    private func parseNetWorthTrend(_ jsonArray: String) throws -> [[String: Any]]? {
        guard let data = jsonArray.data(using: .utf8) else { return nil }
        let raw = try JSONSerialization.jsonObject(with: data)
        return raw as? [[String: Any]]
    }

    private func buildNavPair(points: [[String: Any]]) -> NavPair? {
        let mapped: [NavPoint] = points.compactMap { row in
            guard let y = row["y"] as? Double else { return nil }
            guard let x = row["x"] as? Double else { return nil }
            let date = DateHelper.ymdString(fromMS: x)
            guard !date.isEmpty, y > 0 else { return nil }
            return NavPoint(date: date, value: y)
        }
        guard !mapped.isEmpty else { return nil }
        let latest = mapped[mapped.count - 1]
        let previous = mapped.count > 1 ? mapped[mapped.count - 2] : nil
        return NavPair(latest: latest, previous: previous)
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

    /// 交易中：9:30-11:30 或 13:00-15:00
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
}
