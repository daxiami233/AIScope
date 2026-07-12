import Foundation

// MARK: - OpenCode Go Provider

/// OpenCode Go 用量提供者。
///
/// 读取已登录 OpenCode 官网工作区返回的实时百分比与刷新时间。
final class OpenCodeGoProvider: AIToolProvider, Sendable {

    let id = "opencode-go"
    let displayName = "OpenCode Go"
    let dashboardURL = URL(string: "https://opencode.ai/go")!

    private static let baseURL = URL(string: "https://opencode.ai")!
    private static let serverURL = URL(string: "https://opencode.ai/_server")!
    private static let workspaceServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    func detect() async -> Bool {
        Self.hasOfficialSession
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard let cookie = Self.readOfficialCookie() else {
            throw ProviderError.actionRequired("请在设置中登录 OpenCode 官网")
        }
        return try await Self.fetchOfficialUsage(cookie: cookie)
    }

    // MARK: - 官网实时额度

    /// 用于登录页验证。只有已能读取工作区的官网实时额度时才保存 Cookie。
    static func validateOfficialSession(cookie: String) async -> Bool {
        do {
            _ = try await fetchOfficialUsage(cookie: cookie)
            return true
        } catch {
            return false
        }
    }

    static func readOfficialCookie(allowUserInteraction: Bool = true) -> String? {
        let cookie = AIScopeCredentialStore.read(
            allowUserInteraction: allowUserInteraction
        ).openCodeGoCookie?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cookie?.isEmpty == false) ? cookie : nil
    }

    static func saveOfficialCookie(_ cookie: String) throws {
        let cookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else { return }
        try AIScopeCredentialStore.update { $0.openCodeGoCookie = cookie }
    }

    static var hasOfficialSession: Bool {
        readOfficialCookie(allowUserInteraction: false) != nil
    }

    private static func fetchOfficialUsage(cookie: String) async throws -> UsageSnapshot {
        let workspaceID = try await fetchWorkspaceID(cookie: cookie)
        guard let url = URL(string: "https://opencode.ai/workspace/\(workspaceID)/go") else {
            throw ProviderError.parseError("OpenCode 工作区地址无效")
        }

        let page = try await fetchText(url: url, cookie: cookie, referer: baseURL)
        let usage = try parseOfficialUsage(from: page)
        let now = Date()

        return UsageSnapshot(
            providerID: "opencode-go",
            fetchedAt: now,
            windows: [],
            pools: [
                officialPool(label: "5h", usage: usage.rolling, now: now),
                officialPool(label: "7d", usage: usage.weekly, now: now),
                officialPool(label: "月度", usage: usage.monthly, now: now)
            ],
            extras: [
                UsageExtra(label: "数据来源", value: "OpenCode 官网实时"),
                UsageExtra(label: "工作区", value: workspaceID)
            ],
            planName: "Go",
            accountEmail: nil,
            billingCycleEnd: now.addingTimeInterval(TimeInterval(usage.monthly.resetInSeconds))
        )
    }

    private static func officialPool(label: String, usage: OfficialWindow, now: Date) -> UsagePool {
        UsagePool(
            label: label,
            used: usage.usedPercent,
            limit: 100,
            unit: "%",
            resetsAt: now.addingTimeInterval(TimeInterval(usage.resetInSeconds)),
            displayRemainingPercentOnly: true
        )
    }

    private static func fetchWorkspaceID(cookie: String) async throws -> String {
        let getResult = try await fetchServerText(cookie: cookie, method: "GET", args: nil)
        if let workspaceID = parseWorkspaceID(from: getResult) {
            return workspaceID
        }

        // OpenCode 的服务端函数在部分会话中只接受 POST 调用。
        let postResult = try await fetchServerText(cookie: cookie, method: "POST", args: "[]")
        if let workspaceID = parseWorkspaceID(from: postResult) {
            return workspaceID
        }
        throw ProviderError.parseError("未能从 OpenCode 账号识别工作区")
    }

    private static func fetchServerText(cookie: String, method: String, args: String?) async throws -> String {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        if method == "GET" {
            components?.queryItems = [
                URLQueryItem(name: "id", value: workspaceServerID)
            ]
        }
        guard let url = components?.url else {
            throw ProviderError.parseError("OpenCode 工作区接口地址无效")
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(workspaceServerID, forHTTPHeaderField: "X-Server-Id")
        request.setValue("server-fn:\(UUID().uuidString)", forHTTPHeaderField: "X-Server-Instance")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("text/javascript, application/json;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        if method != "GET", let args {
            request.httpBody = Data(args.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request)
    }

    private static func fetchText(url: URL, cookie: String, referer: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return try await perform(request)
    }

    private static func perform(_ request: URLRequest) async throws -> String {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ProviderError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkError(URLError(.badServerResponse))
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        if looksSignedOut(text) {
            throw ProviderError.actionRequired("OpenCode 官网登录已过期，请在设置中重新登录")
        }
        guard http.statusCode == 200 else {
            throw ProviderError.fromHTTP(
                statusCode: http.statusCode,
                data: data,
                authMessage: "OpenCode 官网登录已过期，请在设置中重新登录"
            )
        }
        guard !text.isEmpty else {
            throw ProviderError.parseError("OpenCode 官网返回了空数据")
        }
        return text
    }

    private static func looksSignedOut(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("auth/authorize") ||
            lower.contains("sign in") ||
            lower.contains("not associated with an account") ||
            lower.contains("actor of type \"public\"")
    }

    private static func parseWorkspaceID(from text: String) -> String? {
        let normalized = normalize(text)
        let pattern = #"[\"']?id[\"']?\s*:\s*[\"'](wrk_[A-Za-z0-9]+)[\"']"#
        return firstCapture(in: normalized, pattern: pattern)
    }

    private static func parseOfficialUsage(from text: String) throws -> OfficialUsage {
        let normalized = normalize(text)
        guard let rolling = parseWindow(named: "rollingUsage", in: normalized),
              let weekly = parseWindow(named: "weeklyUsage", in: normalized),
              let monthly = parseWindow(named: "monthlyUsage", in: normalized)
        else {
            throw ProviderError.parseError("OpenCode 官网页面未返回完整的 Go 用量字段")
        }
        return OfficialUsage(rolling: rolling, weekly: weekly, monthly: monthly)
    }

    private static func parseWindow(named name: String, in text: String) -> OfficialWindow? {
        guard let range = text.range(of: name, options: [.caseInsensitive]) else { return nil }
        // 官网水合数据可能是压缩 JS 或 JSON；在名称后的有限范围内读取同一窗口字段。
        let fragment = String(text[range.lowerBound...].prefix(1_600))
        let percentPatterns = [
            #"[\"']?usagePercent[\"']?\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
            #"[\"']?usedPercent[\"']?\s*:\s*([0-9]+(?:\.[0-9]+)?)"#
        ]
        let resetPatterns = [
            #"[\"']?resetInSec(?:onds)?[\"']?\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
            #"[\"']?resetSeconds[\"']?\s*:\s*([0-9]+(?:\.[0-9]+)?)"#
        ]
        guard var percent = firstDouble(in: fragment, patterns: percentPatterns),
              let reset = firstDouble(in: fragment, patterns: resetPatterns)
        else { return nil }
        if (0...1).contains(percent) { percent *= 100 }
        return OfficialWindow(
            usedPercent: min(100, max(0, percent)),
            resetInSeconds: max(0, Int(reset.rounded()))
        )
    }

    private static func normalize(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "\\u0022", with: "\"")
            .replacingOccurrences(of: "\\u0027", with: "'")
        // 流式 SSR 有时会将 JSON 再转义一层。
        for _ in 0..<2 {
            result = result.replacingOccurrences(of: "\\\"", with: "\"")
        }
        return result
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let capture = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[capture])
    }

    private static func firstDouble(in text: String, patterns: [String]) -> Double? {
        for pattern in patterns {
            if let capture = firstCapture(in: text, pattern: pattern), let value = Double(capture) {
                return value
            }
        }
        return nil
    }

    private struct OfficialUsage {
        let rolling: OfficialWindow
        let weekly: OfficialWindow
        let monthly: OfficialWindow
    }

    private struct OfficialWindow {
        let usedPercent: Double
        let resetInSeconds: Int
    }

}
