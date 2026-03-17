import Foundation

struct FundPosition: Identifiable, Codable, Equatable {
    var id: String
    var fundCode: String
    var costPrice: Double
    var shares: Double
    var fundName: String

    init(
        id: String = "f_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8))",
        fundCode: String,
        costPrice: Double,
        shares: Double,
        fundName: String = ""
    ) {
        self.id = id
        self.fundCode = FundPosition.normalizeCode(fundCode)
        self.costPrice = costPrice
        self.shares = shares
        self.fundName = fundName
    }

    static func normalizeCode(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        return String(digits.suffix(6)).leftPadding(toLength: 6, withPad: "0")
    }
}

struct NavPoint: Equatable {
    let date: String
    let value: Double
}

struct IntradayPoint: Equatable, Codable {
    let timestamp: TimeInterval
    let pct: Double

    var time: Date { Date(timeIntervalSince1970: timestamp) }
}

struct NavPair: Equatable {
    let latest: NavPoint?
    let previous: NavPoint?
}

/// 业绩走势图数据点（仅含交易日，纵轴为累计涨跌幅）
struct DailyPerformancePoint: Equatable, Identifiable {
    let id: String
    let date: String
    /// 自区间起始日的累计涨跌幅 %
    let cumulativeReturn: Double
}

/// 业绩走势时间范围
enum PerformanceRange: String, CaseIterable {
    case m1 = "近1月"
    case m3 = "近3月"
    case m6 = "近6月"
    case y1 = "近1年"
    case y3 = "近3年"

    var tradingDays: Int {
        switch self {
        case .m1: return 21
        case .m3: return 63
        case .m6: return 126
        case .y1: return 252
        case .y3: return 756
        }
    }
}

struct FundSnapshot: Identifiable, Equatable {
    let id: String
    let code: String
    let name: String
    let costPrice: Double
    let shares: Double

    let currentPrice: Double?
    let currentPriceLabel: String
    let latestPublishedNav: Double?
    let previousNav: Double?
    let dataDate: String
    let valuationTime: String

    let todayProfit: Double?
    let todayRate: Double?
    let cumulativeProfit: Double?
    let cumulativeRate: Double?
    let holdValue: Double?
    let intradayTrend: [IntradayPoint]
    let intradayTrendDate: String
    /// 当日净值已更新（用于显示「已更新」标签）
    let hasTodayNav: Bool
}

struct PortfolioSummary: Equatable {
    var totalCost: Double = 0
    var totalTodayProfit: Double = 0
    var totalCumulativeProfit: Double = 0
    var totalHoldValue: Double = 0  // 总市值，账户总资产 = 各持仓市值之和
    var latestDate: String = ""
    var tradingBadge: String = "--"

    /// 账户总资产 = 各持仓当前市值之和（总市值）
    var totalAsset: Double { totalHoldValue > 0 ? totalHoldValue : (totalCost + totalCumulativeProfit) }
    var totalTodayRate: Double? { totalCost > 0 ? (totalTodayProfit / totalCost * 100) : nil }
    var totalCumulativeRate: Double? { totalCost > 0 ? (totalCumulativeProfit / totalCost * 100) : nil }
}

struct AIConfig: Codable, Equatable {
    var endpoint: String = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
    var model: String = "qwen-plus"
    var apiKey: String = ""
}

enum AISlotMode: String {
    case realtime
    case midday
    case preclose
}

enum SortField: String {
    case today
    case cumulative
}

enum SortOrder: String {
    case asc
    case desc
}


extension String {
    func leftPadding(toLength: Int, withPad: String) -> String {
        guard count < toLength else { return self }
        return String(repeating: withPad, count: toLength - count) + self
    }
}
