import Foundation
import Combine

@MainActor
final class SessionViewModel: ObservableObject {
    @Published private(set) var user: UserAccount?
    @Published private(set) var accessToken: String?
    @Published var statusMessage = ""
    @Published var isWorking = false

    private static let tokenAccount = "access_token"
    private static let emailKey = "auth_email"
    private static let userIDKey = "auth_user_id"

    /// 后端地址固定使用生产地址
    static var backendURL: String { AppEnvironment.productionBackendURL }

    var isAuthenticated: Bool {
        accessToken?.isEmpty == false
    }

    init() {
        accessToken = nil
        if let email = UserDefaults.standard.string(forKey: Self.emailKey), !email.isEmpty {
            user = UserAccount(id: UserDefaults.standard.integer(forKey: Self.userIDKey), email: email)
        }
    }

    func restoreStoredSessionIfNeeded() async {
        guard accessToken == nil else { return }
        let tokenAccount = Self.tokenAccount
        let storedToken = await Task.detached(priority: .userInitiated) {
            KeychainStore.read(tokenAccount)
        }.value
        guard let storedToken, !storedToken.isEmpty else { return }
        accessToken = storedToken
    }

    func register(email: String, password: String) async -> Bool {
        await authenticate { service in
            try await service.register(email: email, password: password)
        }
    }

    func login(email: String, password: String) async -> Bool {
        await authenticate { service in
            try await service.login(email: email, password: password)
        }
    }

    func requestPasswordReset(email: String) async -> Bool {
        isWorking = true
        statusMessage = "正在发送验证码..."
        defer { isWorking = false }
        do {
            let code = try await service.requestPasswordReset(email: email)
            if !code.isEmpty {
                statusMessage = "验证码：\(code)（10分钟内有效）"
            } else {
                statusMessage = "如果邮箱已注册，验证码会发送到该邮箱。"
            }
            return true
        } catch {
            statusMessage = message(for: error)
            return false
        }
    }

    func confirmPasswordReset(email: String, code: String, newPassword: String) async -> Bool {
        await authenticate { service in
            try await service.confirmPasswordReset(email: email, code: code, newPassword: newPassword)
        }
    }

    func bootstrapPortfolio(fundViewModel: FundViewModel, stockViewModel: StockViewModel) async {
        guard let token = accessToken else { return }
        do {
            let remote = try await withThrowingTimeout(seconds: 5) {
                try await self.service.fetchPortfolio(token: token)
            }
            let hasRemote = !remote.funds.isEmpty || !remote.stocks.isEmpty
            let localFunds = fundViewModel.exportLocalFunds()
            let localStocks = stockViewModel.exportLocalPositions()
            let hasLocal = !localFunds.isEmpty || !localStocks.isEmpty
            if !hasRemote && hasLocal {
                _ = try await service.replacePortfolio(
                    token: token,
                    payload: PortfolioPayload(
                        funds: localFunds.map(RemoteFundPosition.init),
                        stocks: localStocks.map(RemoteStockPosition.init)
                    )
                )
                statusMessage = "本地持仓已同步到账号。"
            } else if hasRemote {
                fundViewModel.applySyncedFunds(remote.funds.map(\.local))
                stockViewModel.applySyncedPositions(remote.stocks.map(\.local))
                statusMessage = "持仓已从账号同步。"
            }
        } catch AuthServiceError.unauthorized {
            clearSession()
            fundViewModel.clearLocalFunds()
            stockViewModel.clearLocalPositions()
        } catch {
            if isNetworkUnreachable(error) {
                statusMessage = ""
            } else {
                statusMessage = "账号同步失败，已保留本地缓存。"
            }
        }
    }

    func uploadPortfolio(funds: [FundPosition], stocks: [StockPosition]) async {
        guard let token = accessToken else { return }
        do {
            _ = try await service.replacePortfolio(
                token: token,
                payload: PortfolioPayload(
                    funds: funds.map(RemoteFundPosition.init),
                    stocks: stocks.map(RemoteStockPosition.init)
                )
            )
            statusMessage = "持仓已同步。"
        } catch AuthServiceError.unauthorized {
            clearSession()
        } catch {
            statusMessage = "持仓同步失败，稍后会以本地缓存为准。"
        }
    }

    func logout() async {
        if let token = accessToken {
            await service.logout(token: token)
        }
        clearSession()
    }

    func deleteAccount() async -> Bool {
        guard let token = accessToken else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await service.deleteAccount(token: token)
            clearSession()
            return true
        } catch {
            statusMessage = message(for: error)
            return false
        }
    }

    private var service: AuthService {
        AuthService(baseURL: Self.backendURL)
    }

    private func authenticate(_ operation: (AuthService) async throws -> AuthResponse) async -> Bool {
        isWorking = true
        statusMessage = ""
        defer { isWorking = false }
        do {
            let response = try await operation(service)
            persist(response)
            return true
        } catch {
            statusMessage = message(for: error)
            return false
        }
    }

    private func persist(_ response: AuthResponse) {
        accessToken = response.accessToken
        user = response.user
        KeychainStore.save(response.accessToken, account: Self.tokenAccount)
        UserDefaults.standard.set(response.user.email, forKey: Self.emailKey)
        UserDefaults.standard.set(response.user.id, forKey: Self.userIDKey)
    }

    private func clearSession() {
        accessToken = nil
        user = nil
        KeychainStore.delete(Self.tokenAccount)
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        UserDefaults.standard.removeObject(forKey: Self.userIDKey)
    }

    /// 带超时的 async 包装器，seconds 内未完成抛出超时错误
    private func withThrowingTimeout<T>(seconds: UInt64, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw AuthServiceError.network("连接超时")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// 判断错误是否为网络不可达（超时、DNS 解析失败等）
    private func isNetworkUnreachable(_ error: Error) -> Bool {
        if case AuthServiceError.network = error { return true }
        return false
    }

    private func message(for error: Error) -> String {
        switch error {
        case AuthServiceError.conflict:
            return "该邮箱已经注册。"
        case AuthServiceError.unauthorized:
            return "邮箱或密码不正确。"
        case AuthServiceError.invalidURL:
            return "服务地址无效。"
        case AuthServiceError.server(let text):
            return "服务返回错误：\(compactServerMessage(text))"
        case AuthServiceError.network(let text):
            return "无法连接账号服务：\(text)"
        case AuthServiceError.decoding(let text):
            return "服务响应格式不正确：\(text)"
        default:
            return "网络请求失败。"
        }
    }

    private func compactServerMessage(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "未知错误" }
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "..." : trimmed
    }

}
