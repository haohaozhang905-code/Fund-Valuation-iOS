import Foundation

enum AuthServiceError: Error, Equatable {
    case invalidURL
    case unauthorized
    case conflict
    case server(String)
    case network(String)
    case decoding(String)
}

struct AuthService {
    var baseURL: String

    private var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func register(email: String, password: String) async throws -> AuthResponse {
        try await send(path: "/v1/auth/register", method: "POST", body: ["email": email, "password": password], token: nil)
    }

    func login(email: String, password: String) async throws -> AuthResponse {
        try await send(path: "/v1/auth/login", method: "POST", body: ["email": email, "password": password], token: nil)
    }

    func requestPasswordReset(email: String) async throws -> PasswordResetResponse {
        try await send(path: "/v1/auth/password-reset/request", method: "POST", body: ["email": email], token: nil)
    }

    func confirmPasswordReset(email: String, code: String, newPassword: String) async throws -> AuthResponse {
        try await send(
            path: "/v1/auth/password-reset/confirm",
            method: "POST",
            body: ["email": email, "code": code, "newPassword": newPassword],
            token: nil
        )
    }

    func logout(token: String) async {
        let _: EmptyResponse? = try? await send(path: "/v1/auth/logout", method: "POST", body: Optional<String>.none, token: token)
    }

    func deleteAccount(token: String) async throws {
        let _: EmptyResponse = try await send(path: "/v1/account", method: "DELETE", body: Optional<String>.none, token: token)
    }

    func fetchPortfolio(token: String) async throws -> PortfolioResponse {
        try await send(path: "/v1/portfolio", method: "GET", body: Optional<String>.none, token: token)
    }

    func replacePortfolio(token: String, payload: PortfolioPayload) async throws -> PortfolioResponse {
        try await send(path: "/v1/portfolio", method: "PUT", body: payload, token: token)
    }

    private func send<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body?,
        token: String?
    ) async throws -> Response {
        guard let url = URL(string: trimmedBaseURL + path) else { throw AuthServiceError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AuthServiceError.network("无效响应") }
            if http.statusCode == 401 { throw AuthServiceError.unauthorized }
            if http.statusCode == 409 { throw AuthServiceError.conflict }
            guard (200..<300).contains(http.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? "请求失败"
                throw AuthServiceError.server(text)
            }
            do {
                return try decoder.decode(Response.self, from: data.isEmpty ? Data("{}".utf8) : data)
            } catch {
                throw AuthServiceError.decoding(error.localizedDescription)
            }
        } catch let error as AuthServiceError {
            throw error
        } catch let error as URLError {
            throw AuthServiceError.network(error.localizedDescription)
        } catch {
            throw AuthServiceError.network(error.localizedDescription)
        }
    }
}

private struct EmptyResponse: Codable {}
