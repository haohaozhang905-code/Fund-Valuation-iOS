import Foundation

struct StockPosition: Identifiable, Codable, Equatable {
    var id: String
    var symbol: String
    var averageCost: Double
    var shares: Double
    var displayName: String

    init(
        id: String = "s_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8))",
        symbol: String,
        averageCost: Double,
        shares: Double,
        displayName: String = ""
    ) {
        self.id = id
        self.symbol = StockPosition.normalizeSymbol(symbol)
        self.averageCost = averageCost
        self.shares = shares
        self.displayName = displayName
    }

    static func normalizeSymbol(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func isValidSymbol(_ raw: String) -> Bool {
        let normalized = normalizeSymbol(raw)
        guard !normalized.isEmpty, normalized.count <= 15 else { return false }
        let pattern = #"^[A-Z0-9][A-Z0-9\.\-]*$"#
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }
}

enum StockMarketState: String, Codable, Equatable {
    case premarket
    case regular
    case afterhours
    case closed
    case unknown

    var displayName: String {
        switch self {
        case .premarket: return "盘前"
        case .regular: return "交易中"
        case .afterhours: return "盘后"
        case .closed: return "休市"
        case .unknown: return "--"
        }
    }
}

struct StockQuote: Codable, Equatable {
    let symbol: String
    let name: String?

    let regularPrice: Double?
    let previousClose: Double?
    let regularTimestamp: Date?

    let extendedPrice: Double?
    let extendedTimestamp: Date?
    let extendedChange: Double?
    let extendedChangePercent: Double?

    let marketState: StockMarketState
    let providerName: String
    let fetchedAt: Date
}

struct StockSearchResult: Identifiable, Equatable {
    let symbol: String
    let description: String
    let displaySymbol: String
    let type: String

    var id: String { symbol }
}

struct StockSnapshot: Identifiable, Equatable {
    let id: String
    let symbol: String
    let name: String
    let averageCost: Double
    let shares: Double

    let regularPrice: Double?
    let previousClose: Double?
    let marketState: StockMarketState
    let providerName: String
    let updatedAt: Date?
    let fetchedAt: Date

    let todayChange: Double?
    let todayChangePercent: Double?
    let todayProfit: Double?

    let marketValue: Double?
    let totalCost: Double
    let holdingProfit: Double?
    let holdingProfitPercent: Double?

    let extendedPrice: Double?
    let extendedChange: Double?
    let extendedChangePercent: Double?
    let extendedMarketValue: Double?
    let extendedHoldingProfit: Double?
    let extendedUpdatedAt: Date?

    let isStale: Bool
    let errorMessage: String?
}

struct StockPortfolioSummary: Equatable {
    var totalCost: Double = 0
    var totalMarketValue: Double = 0
    var totalTodayProfit: Double = 0
    var totalHoldingProfit: Double = 0
    var totalPreviousCloseValue: Double = 0
    var latestUpdatedAt: Date?
    var marketState: StockMarketState = .unknown
    var providerName: String = ""
    var errorMessage: String?

    var totalTodayRate: Double? {
        totalPreviousCloseValue > 0 ? totalTodayProfit / totalPreviousCloseValue * 100 : nil
    }

    var totalHoldingRate: Double? {
        totalCost > 0 ? totalHoldingProfit / totalCost * 100 : nil
    }
}

struct StockProviderConfig: Codable, Equatable {
    var provider: String = "finnhub"
    var apiKey: String = ""

    // Bridge-style providers use this as their base URL. Key-based providers keep it empty.
    var endpoint: String = ""

    enum CodingKeys: String, CodingKey {
        case provider
        case apiKey
        case endpoint
    }

    init(provider: String = "finnhub", apiKey: String = "", endpoint: String = "") {
        self.provider = provider
        self.apiKey = apiKey
        self.endpoint = endpoint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "finnhub"
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
    }
}

struct StockKLinePoint: Identifiable, Equatable, Codable {
    let date: String
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Int
    let changePercent: Double

    var id: String { date }
}

struct StockKLineData: Identifiable, Equatable, Codable {
    let symbol: String
    let items: [StockKLinePoint]
    let fetchedAt: Date

    var id: String { symbol }
}

enum StockSortField: String, Codable {
    case todayProfit
    case holdingProfit
    case marketValue
    case symbol
}

enum StockSortOrder: String, Codable {
    case asc
    case desc
}
