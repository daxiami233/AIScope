import Foundation

// MARK: - Provider Protocol

// MARK: - HTTP helper (shared across providers)
extension URLSession {
    func fetchJSON<T: Decodable>(
        _ url: URL,
        headers: [String: String] = [:],
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        var req = URLRequest(url: url, timeoutInterval: 15)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkError(URLError(.badServerResponse))
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ProviderError.credentialExpired
            }
            throw ProviderError.apiError(statusCode: http.statusCode)
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
    case apiError(statusCode: Int)
    case parseError(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .notInstalled:           return "工具未安装"
        case .credentialMissing:      return "未找到登录凭证，请先在工具中登录"
        case .credentialExpired:      return "登录凭证已过期，请重新登录"
        case .actionRequired(let msg): return msg
        case .apiError(let code):     return "API 请求失败 (HTTP \(code))"
        case .parseError(let detail): return "数据解析失败: \(detail)"
        case .networkError(let err):  return "网络错误: \(err.localizedDescription)"
        }
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
