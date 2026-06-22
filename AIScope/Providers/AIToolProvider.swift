import Foundation

// MARK: - Provider Protocol

// MARK: - HTTP helper (shared across providers)
extension URLSession {
    func dataForProvider(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.data(for: request)
        } catch {
            throw ProviderError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkError(URLError(.badServerResponse))
        }
        return (data, http)
    }

    func fetchJSON<T: Decodable>(
        _ url: URL,
        headers: [String: String] = [:],
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        var req = URLRequest(url: url, timeoutInterval: 15)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.data(for: req)
        } catch {
            throw ProviderError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkError(URLError(.badServerResponse))
        }
        guard http.statusCode == 200 else {
            throw ProviderError.fromHTTP(statusCode: http.statusCode, data: data)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ProviderError.parseError(error.localizedDescription)
        }
    }
}

// MARK: - Provider Protocol

protocol AIToolProvider: AnyObject, Sendable {
    /// Stable unique identifier (used as cache key, settings key, etc.)
    var id: String { get }
    /// Human-readable name shown in the UI
    var displayName: String { get }
    /// Fallback URL opened when data is unavailable
    var dashboardURL: URL { get }

    /// Returns true when the tool appears to be installed and has credentials.
    func detect() async -> Bool

    /// Fetches current quota usage from the remote API.
    /// Throws `ProviderError` on failure.
    func fetchUsage() async throws -> UsageSnapshot
}

// MARK: - Provider Errors

enum ProviderError: LocalizedError {
    case notInstalled
    case credentialMissing
    case credentialExpired
    case actionRequired(String)
    case quotaUnavailable(String)
    case rateLimited(String)
    case serviceUnavailable(String)
    case apiError(statusCode: Int)
    case apiErrorMessage(statusCode: Int, message: String)
    case parseError(String)
    case networkError(Error)

    var usageErrorKind: UsageErrorKind {
        switch self {
        case .credentialMissing, .credentialExpired, .actionRequired:
            return .actionRequired
        case .notInstalled, .quotaUnavailable, .rateLimited, .serviceUnavailable,
             .apiError, .apiErrorMessage, .parseError, .networkError:
            return .general
        }
    }

    var errorDescription: String? {
        switch self {
        case .notInstalled:           return "工具未安装"
        case .credentialMissing:      return "未找到登录凭证，请先在工具中登录"
        case .credentialExpired:      return "登录凭证已过期，请重新登录"
        case .actionRequired(let msg): return msg
        case .quotaUnavailable(let msg): return msg
        case .rateLimited(let msg):   return msg
        case .serviceUnavailable(let msg): return msg
        case .apiError(let code):     return Self.defaultHTTPMessage(statusCode: code)
        case .apiErrorMessage(_, let message): return message
        case .parseError(let detail): return "数据解析失败: \(detail)"
        case .networkError(let err):  return Self.networkMessage(err)
        }
    }

    static func fromHTTP(statusCode: Int, data: Data? = nil, authMessage: String? = nil) -> ProviderError {
        let serverMessage = data.flatMap(extractServerMessage)
        switch statusCode {
        case 401, 403:
            if let authMessage { return .actionRequired(authMessage) }
            return .credentialExpired
        case 402:
            return .quotaUnavailable(serverMessage ?? "当前账号没有可用额度或有效订阅，请检查套餐后刷新")
        case 404:
            return .apiErrorMessage(statusCode: statusCode, message: serverMessage ?? "额度接口暂时不可用，可能是服务端接口已变更")
        case 408:
            return .networkError(URLError(.timedOut))
        case 409, 423:
            return .apiErrorMessage(statusCode: statusCode, message: serverMessage ?? "服务暂时无法处理请求，请稍后刷新")
        case 429:
            return .rateLimited(serverMessage ?? "服务暂时限流，请稍后再刷新")
        case 500...599:
            return .serviceUnavailable(serverMessage ?? "服务端暂时不可用，请稍后再试")
        default:
            if let serverMessage {
                return .apiErrorMessage(statusCode: statusCode, message: serverMessage)
            }
            return .apiError(statusCode: statusCode)
        }
    }

    static func fromServiceError(code: Int? = nil, message: String, authMessage: String? = nil) -> ProviderError {
        if messageIndicatesAuth(message) {
            return .actionRequired(authMessage ?? message)
        }
        if messageIndicatesQuota(message) {
            return .quotaUnavailable(message)
        }
        if let code {
            switch code {
            case 401, 403:
                return .actionRequired(authMessage ?? message)
            case 402:
                return .quotaUnavailable(message)
            case 429:
                return .rateLimited(message)
            case 500...599:
                return .serviceUnavailable(message)
            default:
                return .apiErrorMessage(statusCode: code, message: message)
            }
        }
        return .apiErrorMessage(statusCode: -1, message: message)
    }

    private static func defaultHTTPMessage(statusCode: Int) -> String {
        switch statusCode {
        case 400: return "请求参数异常，请稍后刷新或更新应用"
        case 404: return "额度接口暂时不可用，可能是服务端接口已变更"
        default:  return "API 请求失败 (HTTP \(statusCode))"
        }
    }

    private static func networkMessage(_ error: Error) -> String {
        let nsError = error as NSError
        let code: URLError.Code? = {
            if let urlError = error as? URLError { return urlError.code }
            guard nsError.domain == NSURLErrorDomain else { return nil }
            return URLError.Code(rawValue: nsError.code)
        }()

        switch code {
        case .notConnectedToInternet?, .dataNotAllowed?:
            return "网络连接不可用，请检查网络后刷新"
        case .timedOut?:
            return "网络请求超时，请稍后再刷新"
        case .cannotFindHost?, .dnsLookupFailed?:
            return "无法解析服务地址，请检查网络或 DNS 后刷新"
        case .cannotConnectToHost?, .networkConnectionLost?:
            return "连接服务失败，请检查网络后刷新"
        case .secureConnectionFailed?, .serverCertificateUntrusted?, .serverCertificateHasBadDate?, .serverCertificateNotYetValid?:
            return "安全连接失败，请检查系统时间或网络证书后刷新"
        case .badServerResponse?:
            return "服务返回了异常响应，请稍后再刷新"
        default:
            return "网络错误：\(error.localizedDescription)"
        }
    }

    private static func extractServerMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) {
            return extractMessage(from: json)
        }
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }
        return String(text.prefix(160))
    }

    private static func extractMessage(from value: Any) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(160))
        }
        if let dict = value as? [String: Any] {
            let keys = ["message", "msg", "error_description", "description", "error", "detail", "reason"]
            for key in keys {
                if let message = extractMessage(from: dict[key] as Any) {
                    return message
                }
            }
            if let data = dict["data"], let message = extractMessage(from: data) {
                return message
            }
        }
        return nil
    }

    private static func messageIndicatesAuth(_ message: String) -> Bool {
        let lower = message.lowercased()
        let keywords = [
            "unauthorized", "forbidden", "invalid token", "token expired",
            "login", "sign in", "auth", "credential",
            "未登录", "请登录", "重新登录", "登录态", "认证", "鉴权", "授权", "过期", "失效"
        ]
        return keywords.contains { lower.contains($0) }
    }

    private static func messageIndicatesQuota(_ message: String) -> Bool {
        let lower = message.lowercased()
        let keywords = [
            "quota", "credit", "balance", "billing", "plan", "subscription",
            "insufficient", "out of credits", "payment required",
            "额度", "余额", "套餐", "订阅", "用量不足", "没有可用", "已用完"
        ]
        return keywords.contains { lower.contains($0) }
    }
}

// MARK: - Shared date parsing

/// ISO8601 解析：先尝试带毫秒格式，失败后回退到无毫秒的互联网日期格式。
/// 支持简单日期格式（如 "2026-07-01"）。
/// 供各 Provider 共用，避免每个文件重复实现。
func parseISO8601(_ string: String) -> Date? {
    let withMs = ISO8601DateFormatter()
    withMs.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withMs.date(from: string) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let d = plain.date(from: string) { return d }
    
    // 支持简单日期格式 "yyyy-MM-dd"
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    return dateFormatter.date(from: string)
}
