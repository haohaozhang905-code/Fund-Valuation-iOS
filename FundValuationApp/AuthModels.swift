import Foundation

struct UserAccount: Codable, Equatable {
    let id: Int
    let email: String
}

struct AuthResponse: Codable, Equatable {
    let accessToken: String
    let tokenType: String
    let user: UserAccount
}

struct PasswordResetResponse: Codable, Equatable {
    let status: String
    let userFound: String
    let emailSent: String?
    let emailError: String?
}

struct RemoteFundPosition: Codable, Equatable {
    let id: String
    let fundCode: String
    let fundName: String
    let costPrice: Double
    let shares: Double
    let clientUpdatedAt: Date?
}

struct RemoteStockPosition: Codable, Equatable {
    let id: String
    let symbol: String
    let displayName: String
    let averageCost: Double
    let shares: Double
    let clientUpdatedAt: Date?
}

struct PortfolioPayload: Codable, Equatable {
    var funds: [RemoteFundPosition]
    var stocks: [RemoteStockPosition]
}

struct PortfolioResponse: Codable, Equatable {
    let funds: [RemoteFundPosition]
    let stocks: [RemoteStockPosition]
    let updatedAt: Date
}

extension RemoteFundPosition {
    init(_ position: FundPosition) {
        self.id = position.id
        self.fundCode = position.fundCode
        self.fundName = position.fundName
        self.costPrice = position.costPrice
        self.shares = position.shares
        self.clientUpdatedAt = Date()
    }

    var local: FundPosition {
        FundPosition(id: id, fundCode: fundCode, costPrice: costPrice, shares: shares, fundName: fundName)
    }
}

extension RemoteStockPosition {
    init(_ position: StockPosition) {
        self.id = position.id
        self.symbol = position.symbol
        self.displayName = position.displayName
        self.averageCost = position.averageCost
        self.shares = position.shares
        self.clientUpdatedAt = Date()
    }

    var local: StockPosition {
        StockPosition(id: id, symbol: symbol, averageCost: averageCost, shares: shares, displayName: displayName)
    }
}
